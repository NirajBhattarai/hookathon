// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseCustomCurve} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomCurve.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {BinMath} from "./libraries/BinMath.sol";
import {LinearDecay} from "./libraries/LinearDecay.sol";
import {LiquidityLibrary} from "./libraries/LiquidityLibrary.sol";

/// @title BinRatchet
/// @notice Hook-owned bin book. Each bin is a mini x*y=k range. LinearDecay sizes L. Ratchet locks reverse.
contract BinRatchet is BaseCustomCurve {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint16 public constant DEFAULT_RAMP = 10;
    uint16 public constant DEFAULT_BINS_PER_SIDE = 10;
    /// @dev Temporary: allow same-block reverse so price can walk back. Re-enable for MEV lock.
    bool public constant RATCHET_ENABLED = false;

    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    struct Book {
        int24 binSize;
        uint16 ramp;
        uint16 numBinsPerSide;
        int24 currentBin;
        int24 minBin;
        int24 maxBin;
        uint160 sqrtPriceX96;
        int24 ratchetLo;
        int24 ratchetHi;
        uint32 ratchetBlock;
        bool configured;
        bool seeded;
    }

    mapping(PoolId poolId => address) public poolCreator;
    mapping(PoolId poolId => bool) public binSizeSet;
    mapping(PoolId poolId => uint256) public totalShares;
    mapping(PoolId poolId => mapping(address user => uint256)) public sharesOf;
    mapping(int24 binIndex => uint128) public liquidity;

    Book public book;

    event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);

    error NotPoolCreator();
    error BinSizeAlreadySet();
    error InvalidBinSize();
    error PoolNotConfigured();
    error RemovalNotSupported();
    error ExactOutputNotSupported();
    error ZeroAmounts();

    constructor(IPoolManager _poolManager) BaseCustomCurve(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        poolCreator[id] = sender;
        book.sqrtPriceX96 = sqrtPriceX96;
        return this.afterInitialize.selector;
    }

    function setBinSize(PoolKey calldata key, int24 _binSize) external {
        PoolId id = key.toId();
        if (msg.sender != poolCreator[id]) revert NotPoolCreator();
        if (binSizeSet[id]) revert BinSizeAlreadySet();
        if (_binSize <= 0 || uint256(uint24(_binSize)) > 2_000) revert InvalidBinSize();

        book.binSize = _binSize;
        book.ramp = DEFAULT_RAMP;
        book.numBinsPerSide = DEFAULT_BINS_PER_SIDE;
        book.configured = true;
        binSizeSet[id] = true;

        emit BinSizeSet(id, msg.sender, _binSize);
    }

    function getBinSize(PoolId) external view returns (int24) {
        return book.binSize;
    }

    function isConfigured(PoolId) external view returns (bool) {
        return book.configured;
    }

    function getTotalShares(PoolId) external view returns (uint256) {
        return totalShares[poolKey.toId()];
    }

    function getShares(PoolId, address user) external view returns (uint256) {
        return sharesOf[poolKey.toId()][user];
    }

    function currentSqrtPriceX96() external view returns (uint160) {
        return book.sqrtPriceX96;
    }

    function currentBin() external view returns (int24) {
        return book.currentBin;
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (!book.configured) revert PoolNotConfigured();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        uint256 LBase = _previewLBase(params.amount0Desired, params.amount1Desired);
        (amount0, amount1) = _applyLBase(LBase);
        shares = amount0 + amount1;
        if (shares == 0) revert ZeroAmounts();
    }

    function _getAmountOut(RemoveLiquidityParams memory) internal pure override returns (uint256, uint256, uint256) {
        revert RemovalNotSupported();
    }

    function _getUnspecifiedAmount(SwapParams calldata params) internal override returns (uint256 unspecifiedAmount) {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        if (!book.seeded) revert BinMath.InsufficientLiquidity();
        unspecifiedAmount = _swapExactIn(uint256(-params.amountSpecified), params.zeroForOne);
    }

    function _swapExactIn(uint256 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        uint256 amountInNet = BinMath.applyFee(amountIn, poolKey.fee);
        if (RATCHET_ENABLED) _resetRatchetIfNewBlock();

        (BinMath.Bin[] memory bins, uint256 active) = _loadBins();
        uint256 lo = 0;
        uint256 hi = bins.length == 0 ? 0 : bins.length - 1;
        if (RATCHET_ENABLED) (lo, hi) = _ratchetClamp(bins.length);
        uint160 sqrtStart = book.sqrtPriceX96;

        uint256 used;
        uint160 sqrtEnd;
        uint256 endIndex;
        (amountOut, used, sqrtEnd, endIndex) =
            BinMath.swapExactIn(bins, sqrtStart, active, amountInNet, zeroForOne, lo, hi);

        if (used < amountInNet) revert BinMath.InsufficientLiquidity();
        _commitSwap(sqrtEnd, endIndex, zeroForOne);
    }

    function _commitSwap(uint160 sqrtEnd, uint256 endIndex, bool zeroForOne) internal {
        int24 endBin = book.minBin + int24(int256(endIndex));
        book.sqrtPriceX96 = sqrtEnd;
        book.currentBin = endBin;
        if (RATCHET_ENABLED) {
            book.ratchetBlock = uint32(block.number);
            if (zeroForOne) {
                book.ratchetHi = endBin;
            } else {
                book.ratchetLo = endBin;
            }
        }
    }

    function _getSwapFeeAmount(SwapParams calldata, uint256) internal pure override returns (uint256) {
        return 0;
    }

    function _mint(AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares) internal override {
        PoolId id = poolKey.toId();
        totalShares[id] += shares;
        sharesOf[id][msg.sender] += shares;
    }

    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256) internal pure override {
        revert RemovalNotSupported();
    }

    function _previewLBase(uint256 amount0Desired, uint256 amount1Desired) internal view returns (uint256 LBase) {
        (int24 minB, int24 maxB, int24 cur) = _binRange();
        uint256 need0;
        uint256 need1;
        uint256 probe = 1e18;
        uint160 sqrtP = book.sqrtPriceX96;

        for (int24 idx = minB; idx <= maxB; ++idx) {
            uint256 Li = LinearDecay.computeLPerBin(probe, book.ramp, _distance(idx, cur));
            if (Li == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(idx, Li, sqrtP);
            need0 += t0;
            need1 += t1;
        }

        if (need0 == 0 && need1 == 0) revert BinMath.InsufficientLiquidity();

        uint256 s0 = need0 == 0 ? type(uint256).max : amount0Desired * probe / need0;
        uint256 s1 = need1 == 0 ? type(uint256).max : amount1Desired * probe / need1;
        LBase = s0 < s1 ? s0 : s1;
        if (LBase == 0) revert ZeroAmounts();
    }

    function _applyLBase(uint256 LBase) internal returns (uint256 amount0, uint256 amount1) {
        (int24 minB, int24 maxB, int24 cur) = _binRange();
        if (!book.seeded) {
            book.minBin = minB;
            book.maxBin = maxB;
            book.currentBin = cur;
            book.ratchetLo = minB;
            book.ratchetHi = maxB;
            book.seeded = true;
        }

        uint160 sqrtP = book.sqrtPriceX96;
        for (int24 idx = minB; idx <= maxB; ++idx) {
            uint256 addL = LinearDecay.computeLPerBin(LBase, book.ramp, _distance(idx, cur));
            if (addL == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(idx, addL, sqrtP);
            amount0 += t0;
            amount1 += t1;
            uint256 next = uint256(liquidity[idx]) + addL;
            liquidity[idx] = uint128(next);
        }
    }

    function _binRange() internal view returns (int24 minB, int24 maxB, int24 cur) {
        if (book.seeded) {
            return (book.minBin, book.maxBin, book.currentBin);
        }
        int24 tick = TickMath.getTickAtSqrtPrice(book.sqrtPriceX96);
        cur = _floorDiv(tick, book.binSize);
        int24 n = int24(uint24(book.numBinsPerSide));
        minB = cur - n;
        maxB = cur + n - 1;
    }

    function _distance(int24 binIndex, int24 cur) internal pure returns (uint256) {
        if (binIndex < cur) return uint256(int256(cur - binIndex));
        return uint256(int256(binIndex - cur + 1));
    }

    function _amountsFor(int24 binIndex, uint256 L, uint160 sqrtP)
        internal
        view
        returns (uint256 token0, uint256 token1)
    {
        int24 tickLo = binIndex * book.binSize;
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(tickLo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(tickLo + book.binSize);
        return LiquidityLibrary.getTokenAmountsForBin(
            L, uint256(sqrtP), LiquidityLibrary.BinBounds(uint256(sqrtLo), uint256(sqrtHi))
        );
    }

    function _loadBins() internal view returns (BinMath.Bin[] memory bins, uint256 active) {
        uint256 n = uint256(int256(book.maxBin - book.minBin + 1));
        bins = new BinMath.Bin[](n);
        int24 size = book.binSize;
        for (uint256 i = 0; i < n; ++i) {
            int24 idx = book.minBin + int24(int256(i));
            int24 tickLo = idx * size;
            bins[i] = BinMath.Bin({
                L: liquidity[idx],
                sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
                sqrtHi: TickMath.getSqrtPriceAtTick(tickLo + size)
            });
            if (idx == book.currentBin) active = i;
        }
    }

    function _ratchetClamp(uint256 n) internal view returns (uint256 lo, uint256 hi) {
        int24 rLo = book.ratchetLo;
        int24 rHi = book.ratchetHi;
        lo = uint256(int256(rLo - book.minBin));
        hi = uint256(int256(rHi - book.minBin));
        if (hi >= n) hi = n - 1;
        if (lo > hi) lo = hi;
    }

    function _resetRatchetIfNewBlock() internal {
        if (book.ratchetBlock != uint32(block.number)) {
            book.ratchetLo = book.minBin;
            book.ratchetHi = book.maxBin;
        }
    }

    function _floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if (a % b != 0 && a < 0) q -= 1;
        return q;
    }
}
