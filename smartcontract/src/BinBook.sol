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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {SwapMath} from "./libraries/SwapMath.sol";

/// @title BinBook
/// @notice Multi-pool hook-owned bin book. Each bin is a mini x*y=k range; LinearDecay sizes L.
///         State is keyed by PoolId. Pass PoolKey on add/remove; tickLower/tickUpper place liquidity.
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

    mapping(PoolId poolId => Book) public books;
    mapping(PoolId poolId => mapping(int24 binIndex => uint128)) public liquidity;

    /// @dev Uniswap-style fee growth (token0 / token1) per unit L in a bin.
    mapping(PoolId poolId => mapping(int24 binIndex => uint256)) public feeGrowth0X128;
    mapping(PoolId poolId => mapping(int24 binIndex => uint256)) public feeGrowth1X128;

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

    mapping(PoolId poolId => mapping(address user => mapping(int24 binIndex => Position))) public positions;
    mapping(PoolId poolId => mapping(address user => UserRange)) public userRanges;

    mapping(PoolId poolId => uint256) private _lastSwapFee;

    event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);
    event BookExpanded(PoolId indexed poolId, int24 minBin, int24 maxBin);
    event FeesCollected(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1);

    error NotPoolCreator();
    error BinSizeAlreadySet();
    error InvalidBinSize();
    error PoolNotConfigured();
    error ExactOutputNotSupported();
    error ZeroAmounts();
    error TicksNotAlignedToBins();
    error InvalidTickRange();
    error TooManyBins();
    error BookTooWide();
    error InsufficientShares();

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
        books[id].sqrtPriceX96 = sqrtPriceX96;
        return this.afterInitialize.selector;
    }

    function setBinSize(PoolKey calldata key, int24 _binSize) external {
        PoolId id = key.toId();
        if (msg.sender != poolCreator[id]) revert NotPoolCreator();
        if (binSizeSet[id]) revert BinSizeAlreadySet();
        if (_binSize <= 0 || uint256(uint24(_binSize)) > 2_000) revert InvalidBinSize();

        Book storage b = books[id];
        b.binSize = _binSize;
        b.ramp = DEFAULT_RAMP;
        b.numBinsPerSide = DEFAULT_BINS_PER_SIDE;
        b.configured = true;
        binSizeSet[id] = true;

        emit BinSizeSet(id, msg.sender, _binSize);
    }

    function getBinSize(PoolId id) external view returns (int24) {
        return books[id].binSize;
    }

    function isConfigured(PoolId id) external view returns (bool) {
        return books[id].configured;
    }

    function getTotalShares(PoolId id) external view returns (uint256) {
        return totalShares[id];
    }

    function getShares(PoolId id, address user) external view returns (uint256) {
        return sharesOf[id][user];
    }

    function currentSqrtPriceX96(PoolId id) external view returns (uint160) {
        return books[id].sqrtPriceX96;
    }

    function currentBin(PoolId id) external view returns (int24) {
        return books[id].currentBin;
    }

    function minBin(PoolId id) external view returns (int24) {
        return books[id].minBin;
    }

    function maxBin(PoolId id) external view returns (int24) {
        return books[id].maxBin;
    }

    function _getAmountIn(PoolKey memory key, AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId id = key.toId();
        if (!books[id].configured) revert PoolNotConfigured();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        BinWindow memory w = _windowFor(id, params.tickLower, params.tickUpper);
        uint256 LBase = _previewLBase(id, w, params.amount0Desired, params.amount1Desired);
        (amount0, amount1) = _applyLBase(id, w, LBase, params.amount0Desired, params.amount1Desired, msg.sender);
        shares = amount0 + amount1;
        if (shares == 0) revert ZeroAmounts();
    }

    function _getAmountOut(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId id = key.toId();
        if (!books[id].configured) revert PoolNotConfigured();

        uint256 userShares = sharesOf[id][msg.sender];
        shares = params.liquidity;
        if (shares == 0 || shares > userShares) revert InsufficientShares();

        uint256 supply = totalShares[id];
        // currency.toId() is preferred; unwrap works for ERC20 address ids used by PoolManager claims
        uint256 claim0 = poolManager.balanceOf(address(this), key.currency0.toId());
        uint256 claim1 = poolManager.balanceOf(address(this), key.currency1.toId());
        (amount0, amount1) = SwapMath.getWithdrawAmounts(claim0, claim1, shares, supply);

        _unwindUserL(id, msg.sender, shares, userShares);
    }

    function _getUnspecifiedAmount(PoolKey calldata key, SwapParams calldata params)
        internal
        override
        returns (uint256 unspecifiedAmount)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        PoolId id = key.toId();
        if (!books[id].seeded) revert SwapMath.InsufficientLiquidity();
        unspecifiedAmount = _swapExactIn(key, uint256(-params.amountSpecified), params.zeroForOne);
    }

    /// @dev Running totals for one swap across the book.
    struct WalkCtx {
        uint256 remaining;
        uint256 amountOut;
        uint256 feeTotal;
        uint160 sqrtEnd;
        uint256 endIndex;
    }

    /// @notice Exact-in swap walking the book with Uniswap-style per-step fees.
    /// @dev Each step runs SwapMath.computeSwapStep against one bin; the step's fee is
    ///      credited to that bin immediately, so only bins that absorb volume earn.
    function _swapExactIn(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        internal
        returns (uint256 amountOut)
    {
        PoolId id = key.toId();
        Book storage b = books[id];

        (SwapMath.Bin[] memory bins, uint256 active) = _loadBins(id);
        if (bins.length == 0) revert SwapMath.InsufficientLiquidity();

        WalkCtx memory w;
        w.remaining = amountIn;
        w.sqrtEnd = b.sqrtPriceX96;
        w.endIndex = active;

        if (zeroForOne) {
            for (uint256 i = active;;) {
                SwapMath.CoreStep memory c = _coreStep(bins[i], w.sqrtEnd, w.remaining, key.fee, true);
                w.remaining -= c.amountIn + c.feeAmount;
                w.amountOut += c.amountOut;
                w.feeTotal += c.feeAmount;
                w.sqrtEnd = c.sqrtNext;
                w.endIndex = i;
                _creditFee(id, b.minBin + int24(int256(i)), c.feeAmount, true);
                if (w.remaining == 0 || i == 0) break;
                unchecked {
                    --i;
                }
            }
        } else {
            uint256 last = bins.length - 1;
            for (uint256 i = active; i <= last;) {
                SwapMath.CoreStep memory c = _coreStep(bins[i], w.sqrtEnd, w.remaining, key.fee, false);
                w.remaining -= c.amountIn + c.feeAmount;
                w.amountOut += c.amountOut;
                w.feeTotal += c.feeAmount;
                w.sqrtEnd = c.sqrtNext;
                w.endIndex = i;
                _creditFee(id, b.minBin + int24(int256(i)), c.feeAmount, false);
                if (w.remaining == 0 || i == last) break;
                unchecked {
                    ++i;
                }
            }
        }

        if (w.remaining > 0) revert SwapMath.InsufficientLiquidity();
        _lastSwapFee[id] = w.feeTotal;
        _commitSwap(id, w.sqrtEnd, w.endIndex);
        amountOut = w.amountOut;
    }

    /// @dev Box computeSwapStep's tuple into one memory slot (stack-too-deep hygiene).
    function _coreStep(SwapMath.Bin memory bin, uint160 sqrtP, uint256 remaining, uint24 feePips, bool zeroForOne)
        private
        pure
        returns (SwapMath.CoreStep memory c)
    {
        (c.sqrtNext, c.amountIn, c.amountOut, c.feeAmount) =
            SwapMath.computeSwapStep(bin, sqrtP, -int256(remaining), feePips, zeroForOne);
    }

    function _commitSwap(PoolId id, uint160 sqrtEnd, uint256 endIndex) internal {
        Book storage b = books[id];
        b.sqrtPriceX96 = sqrtEnd;
        b.currentBin = b.minBin + int24(int256(endIndex));
    }

    function _getSwapFeeAmount(PoolKey calldata key, SwapParams calldata, uint256)
        internal
        view
        override
        returns (uint256)
    {
        return _lastSwapFee[key.toId()];
    }

    function liquidityOf(PoolId id, address user, int24 binIndex) external view returns (uint128) {
        return positions[id][user][binIndex].liquidity;
    }

    function pendingFees(PoolId id, address user) public view returns (uint256 amount0, uint256 amount1) {
        UserRange memory r = userRanges[id][user];
        if (!r.set) return (0, 0);
        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            Position storage p = positions[id][user][idx];
            amount0 += p.tokensOwed0;
            amount1 += p.tokensOwed1;
            uint256 L = p.liquidity;
            if (L == 0) continue;
            amount0 += FullMath.mulDiv(feeGrowth0X128[id][idx] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
            amount1 += FullMath.mulDiv(feeGrowth1X128[id][idx] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
        }
    }

    /// @notice Realize and pay accrued swap fees for `msg.sender` across their bins in `key`.
    function collectFees(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        UserRange memory r = userRanges[id][msg.sender];
        if (!r.set) return (0, 0);

        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            Position storage p = positions[id][msg.sender][idx];
            if (p.liquidity == 0 && p.tokensOwed0 == 0 && p.tokensOwed1 == 0) continue;
            _realizeFees(id, msg.sender, idx);
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
                    key,
                    amount0 == 0 ? int128(0) : -amount0.toInt128(),
                    amount1 == 0 ? int128(0) : -amount1.toInt128()
                )
            )
        );
        emit FeesCollected(id, msg.sender, amount0, amount1);
    }

    function _mint(PoolKey memory key, AddLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        override
    {
        PoolId id = key.toId();
        totalShares[id] += shares;
        sharesOf[id][msg.sender] += shares;
    }

    function _burn(PoolKey memory key, RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256 shares)
        internal
        override
    {
        PoolId id = key.toId();
        totalShares[id] -= shares;
        sharesOf[id][msg.sender] -= shares;
    }

    /// @dev Reduce the caller's bin L proportional to shares burned / their total shares.
    function _unwindUserL(PoolId id, address user, uint256 sharesBurned, uint256 userShares) internal {
        UserRange memory r = userRanges[id][user];
        if (!r.set || userShares == 0) return;

        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            Position storage p = positions[id][user][idx];
            uint256 L = p.liquidity;
            if (L == 0) continue;
            _realizeFees(id, user, idx);
            uint256 burnL = L * sharesBurned / userShares;
            if (burnL == 0) continue;
            if (burnL > L) burnL = L;
            p.liquidity = uint128(L - burnL);
            liquidity[id][idx] -= uint128(burnL);
            p.feeGrowth0LastX128 = feeGrowth0X128[id][idx];
            p.feeGrowth1LastX128 = feeGrowth1X128[id][idx];
        }
    }

    function _previewLBase(PoolId id, BinWindow memory w, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (uint256 LBase)
    {
        Book storage b = books[id];
        uint256 need0;
        uint256 need1;
        uint256 probe = 1e18;
        uint160 sqrtP = b.sqrtPriceX96;

        for (int24 idx = w.minB; idx <= w.maxB; ++idx) {
            uint256 Li = SwapMath.computeLPerBin(probe, w.ramp, _distance(idx, w.cur));
            if (Li == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(id, idx, Li, sqrtP);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            need0 += t0;
            need1 += t1;
        }

        if (need0 == 0 && need1 == 0) revert SwapMath.InsufficientLiquidity();

        uint256 s0 = need0 == 0 ? type(uint256).max : amount0Desired * probe / need0;
        uint256 s1 = need1 == 0 ? type(uint256).max : amount1Desired * probe / need1;
        LBase = s0 < s1 ? s0 : s1;
        if (LBase == 0) revert ZeroAmounts();
    }

    function _applyLBase(
        PoolId id,
        BinWindow memory w,
        uint256 LBase,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address user
    ) internal returns (uint256 amount0, uint256 amount1) {
        _expandBook(id, w.minB, w.maxB, w.cur);

        uint160 sqrtP = books[id].sqrtPriceX96;
        for (int24 idx = w.minB; idx <= w.maxB; ++idx) {
            uint256 addL = SwapMath.computeLPerBin(LBase, w.ramp, _distance(idx, w.cur));
            if (addL == 0) continue;
            (uint256 t0, uint256 t1) = _amountsFor(id, idx, addL, sqrtP);
            if (amount0Desired == 0 && t0 > 0) continue;
            if (amount1Desired == 0 && t1 > 0) continue;
            amount0 += t0;
            amount1 += t1;
            _creditUserL(id, user, idx, addL);
        }
    }

    function _creditUserL(PoolId id, address user, int24 idx, uint256 addL) internal {
        uint128 add128 = addL.toUint128();
        _realizeFees(id, user, idx);
        Position storage p = positions[id][user][idx];
        p.liquidity += add128;
        p.feeGrowth0LastX128 = feeGrowth0X128[id][idx];
        p.feeGrowth1LastX128 = feeGrowth1X128[id][idx];
        liquidity[id][idx] += add128;

        UserRange storage r = userRanges[id][user];
        if (!r.set) {
            r.minB = idx;
            r.maxB = idx;
            r.set = true;
        } else {
            if (idx < r.minB) r.minB = idx;
            if (idx > r.maxB) r.maxB = idx;
        }
    }

    function _realizeFees(PoolId id, address user, int24 idx) internal {
        Position storage p = positions[id][user][idx];
        uint256 L = p.liquidity;
        if (L == 0) {
            p.feeGrowth0LastX128 = feeGrowth0X128[id][idx];
            p.feeGrowth1LastX128 = feeGrowth1X128[id][idx];
            return;
        }
        p.tokensOwed0 += FullMath.mulDiv(feeGrowth0X128[id][idx] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
        p.tokensOwed1 += FullMath.mulDiv(feeGrowth1X128[id][idx] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
        p.feeGrowth0LastX128 = feeGrowth0X128[id][idx];
        p.feeGrowth1LastX128 = feeGrowth1X128[id][idx];
    }

    function _creditFee(PoolId id, int24 idx, uint256 fee, bool zeroForOne) internal {
        uint256 L = liquidity[id][idx];
        if (fee == 0 || L == 0) return;
        uint256 delta = FullMath.mulDiv(fee, FixedPoint128.Q128, L);
        if (zeroForOne) feeGrowth0X128[id][idx] += delta;
        else feeGrowth1X128[id][idx] += delta;
    }

    /// @dev `tickLower >= tickUpper` (including 0,0) keeps the default near-spot window.
    function _windowFor(PoolId id, int24 tickLower, int24 tickUpper) internal view returns (BinWindow memory w) {
        Book storage b = books[id];
        (int24 defMin, int24 defMax, int24 cur) = _binRange(id);
        w.cur = cur;

        if (tickLower >= tickUpper) {
            w.minB = defMin;
            w.maxB = defMax;
            w.ramp = b.ramp;
            return w;
        }

        int24 size = b.binSize;
        if (tickLower % size != 0 || tickUpper % size != 0) revert TicksNotAlignedToBins();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert InvalidTickRange();

        int24 userMin = tickLower / size;
        int24 userMax = tickUpper / size - 1;
        if (userMax < userMin) revert InvalidTickRange();

        uint256 n = uint256(int256(userMax - userMin + 1));
        if (n > MAX_BINS_PER_ADD) revert TooManyBins();

        w.minB = userMin;
        w.maxB = userMax;
        w.ramp = _rampFor(userMin, userMax, cur, b.ramp);
    }

    function _rampFor(int24 minB, int24 maxB, int24 cur, uint16 baseRamp) internal pure returns (uint256 ramp) {
        uint256 dLo = _distance(minB, cur);
        uint256 dHi = _distance(maxB, cur);
        uint256 farthest = dLo > dHi ? dLo : dHi;
        ramp = farthest + 1;
        if (ramp < baseRamp) ramp = baseRamp;
    }

    function _expandBook(PoolId id, int24 fillMin, int24 fillMax, int24 cur) internal {
        Book storage b = books[id];
        int24 minB = fillMin;
        int24 maxB = fillMax;
        if (cur < minB) minB = cur;
        if (cur > maxB) maxB = cur;

        if (!b.seeded) {
            int24 n = int24(uint24(b.numBinsPerSide));
            int24 defMin = cur - n;
            int24 defMax = cur + n - 1;
            if (defMin < minB) minB = defMin;
            if (defMax > maxB) maxB = defMax;
            b.currentBin = cur;
            b.seeded = true;
            b.minBin = minB;
            b.maxBin = maxB;
            emit BookExpanded(id, minB, maxB);
        } else {
            bool grew;
            if (minB < b.minBin) {
                b.minBin = minB;
                grew = true;
            }
            if (maxB > b.maxBin) {
                b.maxBin = maxB;
                grew = true;
            }
            if (grew) emit BookExpanded(id, b.minBin, b.maxBin);
        }

        uint256 span = uint256(int256(b.maxBin - b.minBin + 1));
        if (span > MAX_BOOK_BINS) revert BookTooWide();
    }

    function _binRange(PoolId id) internal view returns (int24 minB, int24 maxB, int24 cur) {
        Book storage b = books[id];
        if (b.seeded) {
            return (b.minBin, b.maxBin, b.currentBin);
        }
        int24 tick = TickMath.getTickAtSqrtPrice(b.sqrtPriceX96);
        cur = _floorDiv(tick, b.binSize);
        int24 n = int24(uint24(b.numBinsPerSide));
        minB = cur - n;
        maxB = cur + n - 1;
    }

    function _distance(int24 binIndex, int24 cur) internal pure returns (uint256) {
        if (binIndex < cur) return uint256(int256(cur - binIndex));
        return uint256(int256(binIndex - cur + 1));
    }

    function _amountsFor(PoolId id, int24 binIndex, uint256 L, uint160 sqrtP)
        internal
        view
        returns (uint256 token0, uint256 token1)
    {
        Book storage b = books[id];
        int24 tickLo = _tickAtBin(id, binIndex);
        uint160 sqrtLo = TickMath.getSqrtPriceAtTick(tickLo);
        uint160 sqrtHi = TickMath.getSqrtPriceAtTick(tickLo + b.binSize);
        return SwapMath.getTokenAmountsForBin(
            L, uint256(sqrtP), SwapMath.BinBounds(uint256(sqrtLo), uint256(sqrtHi))
        );
    }

    function _loadBins(PoolId id) internal view returns (SwapMath.Bin[] memory bins, uint256 active) {
        Book storage b = books[id];
        uint256 n = uint256(int256(b.maxBin - b.minBin + 1));
        bins = new SwapMath.Bin[](n);
        for (uint256 i = 0; i < n; ++i) {
            int24 idx = b.minBin + int24(int256(i));
            int24 tickLo = _tickAtBin(id, idx);
            bins[i] = SwapMath.Bin({
                L: liquidity[id][idx],
                sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
                sqrtHi: TickMath.getSqrtPriceAtTick(tickLo + b.binSize)
            });
            if (idx == b.currentBin) active = i;
        }
    }

    function _tickAtBin(PoolId id, int24 idx) internal view returns (int24) {
        int256 tick = int256(idx) * int256(books[id].binSize);
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTickRange();
        return int24(tick);
    }

    function _floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if (a % b != 0 && a < 0) q -= 1;
        return q;
    }
}
