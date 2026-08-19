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

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {BinMath} from "./libraries/BinMath.sol";
import {LinearDecay} from "./libraries/LinearDecay.sol";
import {LiquidityLibrary} from "./libraries/LiquidityLibrary.sol";

/// @title BinBook
/// @notice Hook-owned bin book. Each bin is a mini x*y=k range. LinearDecay sizes L.
///         Pass tickLower/tickUpper on addLiquidity to place anywhere; the book grows to cover it.
contract BinBook is BaseCustomCurve {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint16 public constant DEFAULT_RAMP = 10;
    uint16 public constant DEFAULT_BINS_PER_SIDE = 10;
    /// @dev Cap on bins filled in a single add. Far ranges should use a larger `binSize`.
    uint16 public constant MAX_BINS_PER_ADD = 256;
    /// @dev Cap on the contiguous book. Swaps load every bin in `[minBin, maxBin]`.
    uint16 public constant MAX_BOOK_BINS = 1024;

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
        bool configured;
        bool seeded;
    }

    mapping(PoolId poolId => address) public poolCreator;
    mapping(PoolId poolId => bool) public binSizeSet;
    mapping(PoolId poolId => uint256) public totalShares;
    mapping(PoolId poolId => mapping(address user => uint256)) public sharesOf;
    mapping(int24 binIndex => uint128) public liquidity;

    /// @dev Uniswap-style fee growth (token0 / token1) per unit L in a bin.
    mapping(int24 binIndex => uint256) public feeGrowth0X128;
    mapping(int24 binIndex => uint256) public feeGrowth1X128;

    struct Position {
        uint128 liquidity;
        uint256 feeGrowth0LastX128;
        uint256 feeGrowth1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    struct UserRange {
        int24 minB;
        int24 maxB;
        bool set;
    }

    mapping(address user => mapping(int24 binIndex => Position)) public positions;
    mapping(address user => UserRange) public userRange;

    uint256 private _lastSwapFee;

    Book public book;

    event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);
    event BookExpanded(int24 minBin, int24 maxBin);
    event FeesCollected(address indexed user, uint256 amount0, uint256 amount1);

    error NotPoolCreator();
    error BinSizeAlreadySet();
    error InvalidBinSize();
    error PoolNotConfigured();
    error RemovalNotSupported();
    error ExactOutputNotSupported();
    error ZeroAmounts();
    error TicksNotAlignedToBins();
    error InvalidTickRange();
    error TooManyBins();
    error BookTooWide();

    struct BinWindow {
        int24 minB;
        int24 maxB;
        int24 cur;
        uint256 ramp;
    }

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

    function minBin() external view returns (int24) {
        return book.minBin;
    }

    function maxBin() external view returns (int24) {
        return book.maxBin;
    }

    function _getAmountIn(AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (!book.configured) revert PoolNotConfigured();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        BinWindow memory w = _windowFor(params.tickLower, params.tickUpper);
        uint256 LBase = _previewLBase(w, params.amount0Desired, params.amount1Desired);
        (amount0, amount1) = _applyLBase(w, LBase, params.amount0Desired, params.amount1Desired, msg.sender);
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

    struct SwapWalk {
        uint256 remaining;
        uint256 amountOut;
        uint160 sqrtEnd;
        uint256 endIndex;
        uint256 feeTotal;
        uint256 amountInNet;
        uint256 credited;
        int24 lastFeeBin;
        bool wroteFee;
        bool zeroForOne;
    }

    function _swapExactIn(uint256 amountIn, bool zeroForOne) internal returns (uint256 amountOut) {
        uint256 amountInNet = BinMath.applyFee(amountIn, poolKey.fee);

        (BinMath.Bin[] memory bins, uint256 active) = _loadBins();
        if (bins.length == 0) revert BinMath.InsufficientLiquidity();
        uint256 last = bins.length - 1;

        SwapWalk memory w = SwapWalk({
            remaining: amountInNet,
            amountOut: 0,
            sqrtEnd: book.sqrtPriceX96,
            endIndex: active,
            feeTotal: amountIn - amountInNet,
            amountInNet: amountInNet,
            credited: 0,
            lastFeeBin: book.currentBin,
            wroteFee: false,
            zeroForOne: zeroForOne
        });

        if (zeroForOne) {
            for (uint256 i = active;;) {
                _swapStep(w, bins[i], i);
                if (w.remaining == 0) break;
                if (i == 0) break;
                unchecked {
                    --i;
                }
            }
        } else {
            for (uint256 i = active; i <= last; ++i) {
                _swapStep(w, bins[i], i);
                if (w.remaining == 0) break;
            }
        }

        if (w.remaining > 0) revert BinMath.InsufficientLiquidity();
        if (w.wroteFee && w.feeTotal > w.credited) {
            _creditFee(w.lastFeeBin, w.feeTotal - w.credited, zeroForOne);
        }
        _lastSwapFee = w.feeTotal;
        _commitSwap(w.sqrtEnd, w.endIndex);
        amountOut = w.amountOut;
    }

    function _swapStep(SwapWalk memory w, BinMath.Bin memory bin, uint256 i) internal {
        BinMath.Step memory step = BinMath.swapExactInSingle(bin, w.sqrtEnd, w.remaining, w.zeroForOne);
        w.amountOut += step.amountOut;
        w.remaining -= step.amountInUsed;
        w.sqrtEnd = step.sqrtEnd;
        w.endIndex = i;
        if (step.amountInUsed == 0 || w.amountInNet == 0) return;
        int24 idx = book.minBin + int24(int256(i));
        uint256 feeI = w.feeTotal * step.amountInUsed / w.amountInNet;
        _creditFee(idx, feeI, w.zeroForOne);
        w.credited += feeI;
        w.lastFeeBin = idx;
        w.wroteFee = true;
    }

    function _commitSwap(uint160 sqrtEnd, uint256 endIndex) internal {
        book.sqrtPriceX96 = sqrtEnd;
        book.currentBin = book.minBin + int24(int256(endIndex));
    }

    function _getSwapFeeAmount(SwapParams calldata, uint256) internal view override returns (uint256) {
        return _lastSwapFee;
    }

    function liquidityOf(address user, int24 binIndex) external view returns (uint128) {
        return positions[user][binIndex].liquidity;
    }

    function pendingFees(address user) public view returns (uint256 amount0, uint256 amount1) {
        UserRange memory r = userRange[user];
        if (!r.set) return (0, 0);
        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            Position storage p = positions[user][idx];
            amount0 += p.tokensOwed0;
            amount1 += p.tokensOwed1;
            uint256 L = p.liquidity;
            if (L == 0) continue;
            amount0 += FullMath.mulDiv(feeGrowth0X128[idx] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
            amount1 += FullMath.mulDiv(feeGrowth1X128[idx] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
        }
    }

    /// @notice Realize and pay accrued swap fees for `msg.sender` across their bins.
    function collectFees() external returns (uint256 amount0, uint256 amount1) {
        UserRange memory r = userRange[msg.sender];
        if (!r.set) return (0, 0);

        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            Position storage p = positions[msg.sender][idx];
            if (p.liquidity == 0 && p.tokensOwed0 == 0 && p.tokensOwed1 == 0) continue;
            _realizeFees(msg.sender, idx);
            amount0 += p.tokensOwed0;
            amount1 += p.tokensOwed1;
            p.tokensOwed0 = 0;
            p.tokensOwed1 = 0;
        }

        if (amount0 == 0 && amount1 == 0) return (0, 0);

        poolManager.unlock(
            abi.encode(
                CallbackDataCustom(
                    msg.sender,
                    amount0 == 0 ? int128(0) : -amount0.toInt128(),
                    amount1 == 0 ? int128(0) : -amount1.toInt128()
                )
            )
        );
        emit FeesCollected(msg.sender, amount0, amount1);
    }

    function _mint(AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares) internal override {
        PoolId id = poolKey.toId();
        totalShares[id] += shares;
        sharesOf[id][msg.sender] += shares;
    }

    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256) internal pure override {
        revert RemovalNotSupported();
    }

    function _previewLBase(BinWindow memory w, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (uint256 LBase)
    {
        uint256 need0;
        uint256 need1;
        uint256 probe = 1e18;
        uint160 sqrtP = book.sqrtPriceX96;

        for (int24 idx = w.minB; idx <= w.maxB; ++idx) {
            uint256 Li = LinearDecay.computeLPerBin(probe, w.ramp, _distance(idx, w.cur));
            if (Li == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(idx, Li, sqrtP);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            need0 += t0;
            need1 += t1;
        }

        if (need0 == 0 && need1 == 0) revert BinMath.InsufficientLiquidity();

        uint256 s0 = need0 == 0 ? type(uint256).max : amount0Desired * probe / need0;
        uint256 s1 = need1 == 0 ? type(uint256).max : amount1Desired * probe / need1;
        LBase = s0 < s1 ? s0 : s1;
        if (LBase == 0) revert ZeroAmounts();
    }

    function _applyLBase(
        BinWindow memory w,
        uint256 LBase,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address user
    ) internal returns (uint256 amount0, uint256 amount1) {
        _expandBook(w.minB, w.maxB, w.cur);

        uint160 sqrtP = book.sqrtPriceX96;
        for (int24 idx = w.minB; idx <= w.maxB; ++idx) {
            uint256 addL = LinearDecay.computeLPerBin(LBase, w.ramp, _distance(idx, w.cur));
            if (addL == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(idx, addL, sqrtP);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            amount0 += t0;
            amount1 += t1;
            _creditUserL(user, idx, addL);
        }
    }

    function _creditUserL(address user, int24 idx, uint256 addL) internal {
        uint128 add128 = addL.toUint128();
        _realizeFees(user, idx);
        Position storage p = positions[user][idx];
        p.liquidity += add128;
        p.feeGrowth0LastX128 = feeGrowth0X128[idx];
        p.feeGrowth1LastX128 = feeGrowth1X128[idx];
        liquidity[idx] += add128;

        UserRange storage r = userRange[user];
        if (!r.set) {
            r.minB = idx;
            r.maxB = idx;
            r.set = true;
        } else {
            if (idx < r.minB) r.minB = idx;
            if (idx > r.maxB) r.maxB = idx;
        }
    }

    function _realizeFees(address user, int24 idx) internal {
        Position storage p = positions[user][idx];
        uint256 L = p.liquidity;
        if (L == 0) {
            p.feeGrowth0LastX128 = feeGrowth0X128[idx];
            p.feeGrowth1LastX128 = feeGrowth1X128[idx];
            return;
        }
        p.tokensOwed0 += FullMath.mulDiv(feeGrowth0X128[idx] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
        p.tokensOwed1 += FullMath.mulDiv(feeGrowth1X128[idx] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
        p.feeGrowth0LastX128 = feeGrowth0X128[idx];
        p.feeGrowth1LastX128 = feeGrowth1X128[idx];
    }

    function _creditFee(int24 idx, uint256 fee, bool zeroForOne) internal {
        uint256 L = liquidity[idx];
        if (fee == 0 || L == 0) return;
        uint256 delta = FullMath.mulDiv(fee, FixedPoint128.Q128, L);
        if (zeroForOne) feeGrowth0X128[idx] += delta;
        else feeGrowth1X128[idx] += delta;
    }

    /// @dev `tickLower >= tickUpper` (including 0,0) keeps the default near-spot window.
    ///      A real range grows the book and stretches the ramp so every requested bin gets L > 0.
    function _windowFor(int24 tickLower, int24 tickUpper) internal view returns (BinWindow memory w) {
        (int24 defMin, int24 defMax, int24 cur) = _binRange();
        w.cur = cur;

        if (tickLower >= tickUpper) {
            w.minB = defMin;
            w.maxB = defMax;
            w.ramp = book.ramp;
            return w;
        }

        int24 size = book.binSize;
        if (tickLower % size != 0 || tickUpper % size != 0) revert TicksNotAlignedToBins();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert InvalidTickRange();

        int24 userMin = tickLower / size;
        int24 userMax = tickUpper / size - 1;
        if (userMax < userMin) revert InvalidTickRange();

        uint256 n = uint256(int256(userMax - userMin + 1));
        if (n > MAX_BINS_PER_ADD) revert TooManyBins();

        w.minB = userMin;
        w.maxB = userMax;
        w.ramp = _rampFor(userMin, userMax, cur, book.ramp);
    }

    function _rampFor(int24 minB, int24 maxB, int24 cur, uint16 baseRamp) internal pure returns (uint256 ramp) {
        uint256 dLo = _distance(minB, cur);
        uint256 dHi = _distance(maxB, cur);
        uint256 farthest = dLo > dHi ? dLo : dHi;
        ramp = farthest + 1;
        if (ramp < baseRamp) ramp = baseRamp;
    }

    /// @dev Grow `[minBin, maxBin]` so it always contains the fill window, current bin, and
    ///      (on first seed) the default neighborhood. Book stays contiguous for swap walks.
    function _expandBook(int24 fillMin, int24 fillMax, int24 cur) internal {
        int24 minB = fillMin;
        int24 maxB = fillMax;
        if (cur < minB) minB = cur;
        if (cur > maxB) maxB = cur;

        if (!book.seeded) {
            int24 n = int24(uint24(book.numBinsPerSide));
            int24 defMin = cur - n;
            int24 defMax = cur + n - 1;
            if (defMin < minB) minB = defMin;
            if (defMax > maxB) maxB = defMax;
            book.currentBin = cur;
            book.seeded = true;
            book.minBin = minB;
            book.maxBin = maxB;
            emit BookExpanded(minB, maxB);
        } else {
            bool grew;
            if (minB < book.minBin) {
                book.minBin = minB;
                grew = true;
            }
            if (maxB > book.maxBin) {
                book.maxBin = maxB;
                grew = true;
            }
            if (grew) emit BookExpanded(book.minBin, book.maxBin);
        }

        uint256 span = uint256(int256(book.maxBin - book.minBin + 1));
        if (span > MAX_BOOK_BINS) revert BookTooWide();
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
        int24 tickLo = _tickAtBin(binIndex);
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(tickLo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(tickLo + book.binSize);
        return LiquidityLibrary.getTokenAmountsForBin(
            L, uint256(sqrtP), LiquidityLibrary.BinBounds(uint256(sqrtLo), uint256(sqrtHi))
        );
    }

    function _loadBins() internal view returns (BinMath.Bin[] memory bins, uint256 active) {
        uint256 n = uint256(int256(book.maxBin - book.minBin + 1));
        bins = new BinMath.Bin[](n);
        for (uint256 i = 0; i < n; ++i) {
            int24 idx = book.minBin + int24(int256(i));
            int24 tickLo = _tickAtBin(idx);
            bins[i] = BinMath.Bin({
                L: liquidity[idx],
                sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
                sqrtHi: TickMath.getSqrtPriceAtTick(tickLo + book.binSize)
            });
            if (idx == book.currentBin) active = i;
        }
    }

    function _tickAtBin(int24 idx) internal view returns (int24) {
        int256 tick = int256(idx) * int256(book.binSize);
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTickRange();
        return int24(tick);
    }

    function _floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if (a % b != 0 && a < 0) q -= 1;
        return q;
    }
}
