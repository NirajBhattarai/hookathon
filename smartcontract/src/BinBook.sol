// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseCustomCurve} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomCurve.sol";
import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {SwapMath} from "./libraries/SwapMath.sol";
import {BinLayout} from "./libraries/BinLayout.sol";

/*//////////////////////////////////////////////////////////////
                                  TYPES
//////////////////////////////////////////////////////////////*/

/// @dev Running totals for one swap across the book.
struct WalkCtx {
    uint256 remaining;
    uint256 amountOut;
    uint256 feeTotal;
    uint160 sqrtEnd;
    uint256 endIndex;
}

/// @title BinBook
/// @notice Multi-pool hook-owned bin book. Each bin is a mini x*y=k range; LinearDecay sizes L.
///         State is keyed by PoolId. Pass PoolKey on add/remove; tickLower/tickUpper place liquidity.
contract BinBook is BaseCustomCurve {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;
    using BinLayout for BinLayout.Book;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 public constant DEFAULT_RAMP = 10;
    uint16 public constant DEFAULT_BINS_PER_SIDE = 10;
    /// @dev Cap on the contiguous book. Swaps load every bin in `[minBin, maxBin]`.
    ///      Re-exported from `BinLayout` (single source of truth) to keep the public getter.
    uint16 public constant MAX_BOOK_BINS = BinLayout.MAX_BOOK_BINS;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => address) public poolCreator;
    mapping(PoolId poolId => uint256) public totalShares;
    mapping(PoolId poolId => mapping(address user => uint256)) public sharesOf;

    /// @dev This pool's own token holdings, tracked by the hook itself rather than read from
    ///      `poolManager.balanceOf(address(this), currency.toId())`. That claim balance is keyed
    ///      globally by currency, not by PoolId, so it's shared across every pool this hook backs
    ///      that uses the same currency — and it's mintable to this hook by *any* address via
    ///      `poolManager.mint(address(this), id, amount)` after settling real tokens, with no
    ///      relation to this pool's own addLiquidity/removeLiquidity/swap history. Both make the
    ///      raw claim balance untrustworthy as the mint/burn value formula's reserve — a donation
    ///      or a sibling pool sharing a currency would silently reprice everyone's shares. These
    ///      mappings instead move only in response to this pool's own operations (see
    ///      `_getAmountIn`, `_getAmountOut`, `_swapExactIn`, `collectFees`), so they can't be
    ///      inflated or contaminated from outside this pool.
    mapping(PoolId poolId => uint256) public poolReserve0;
    mapping(PoolId poolId => uint256) public poolReserve1;

    mapping(PoolId poolId => BinLayout.Book) public books;
    mapping(PoolId poolId => mapping(int24 binIndex => uint128)) public liquidity;

    /// @dev Uniswap-style fee growth (token0 / token1) per unit L in a bin.
    mapping(PoolId poolId => mapping(int24 binIndex => uint256)) public feeGrowth0X128;
    mapping(PoolId poolId => mapping(int24 binIndex => uint256)) public feeGrowth1X128;

    mapping(PoolId poolId => mapping(address user => mapping(int24 binIndex => BinLayout.Position))) public positions;
    mapping(PoolId poolId => mapping(address user => BinLayout.UserRange)) public userRanges;

    mapping(PoolId poolId => uint256) private _lastSwapFee;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);
    event BookExpanded(PoolId indexed poolId, int24 minBin, int24 maxBin);
    event FeesCollected(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a pool is created through the gateway with its locked bin size.
    event PoolCreated(PoolId indexed poolId, address indexed creator, PoolKey key, int24 binSize);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidBinSize();
    error ExactOutputNotSupported();
    error ZeroAmounts();
    error InsufficientShares();
    error InitializeViaCreatePool();
    error InvalidHook();
    error InsufficientRangeLiquidity();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager) BaseCustomCurve(_poolManager) {}

    /*//////////////////////////////////////////////////////////////
                             HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

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

    /*//////////////////////////////////////////////////////////////
                              HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enforces the creation gateway: pools can only be born via createPool.
    /// @dev v4 skips hook callbacks when the hook itself calls initialize, so self-calls from
    ///      createPool pass; any external initialize reverts here, rolling back the whole creation.
    function _afterInitialize(address sender, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        if (sender != address(this)) revert InitializeViaCreatePool();
        return this.afterInitialize.selector;
    }

    function _getAmountIn(PoolKey memory key, AddLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId id = key.toId();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        BinLayout.Window memory window = books[id].resolveWindow(params.tickLower, params.tickUpper);

        (uint256 lBase, BinLayout.ReferenceBin[] memory refBins) =
            books[id].solveLBase(window, params.amount0Desired, params.amount1Desired);
        if (lBase == 0) revert ZeroAmounts();

        (amount0, amount1) =
            _depositLBase(id, window, lBase, refBins, params.amount0Desired, params.amount1Desired, msg.sender);

        // poolReserve0/1 still reflect the pool's state from *before* this deposit (they're only
        // bumped below, after pricing), so this is the same instant priced below.
        shares = SwapMath.getMintShares(
            amount0, amount1, poolReserve0[id], poolReserve1[id], books[id].sqrtPriceX96, totalShares[id]
        );
        if (shares == 0) revert ZeroAmounts();

        poolReserve0[id] += amount0;
        poolReserve1[id] += amount1;
    }

    function _getAmountOut(PoolKey memory key, RemoveLiquidityParams memory params)
        internal
        override
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        PoolId id = key.toId();

        uint256 userShares = sharesOf[id][msg.sender];
        shares = params.liquidity;
        if (shares == 0 || shares > userShares) revert InsufficientShares();

        // Scope the redemption to the caller's chosen [tickLower, tickUpper] instead of walking
        // this user's entire historical bin range (userRanges only ever widens — see
        // BinLayout.increaseUserL — so that range can grow far beyond what's actually being
        // withdrawn here, making removeLiquidity's cost scale with a stale span rather than the
        // request). Validate/convert the same way addLiquidity does.
        BinLayout.Book storage book = books[id];
        (int24 minB, int24 maxB) = book.resolveBinRange(params.tickLower, params.tickUpper);

        // Value target, computed as the exact inverse of getMintShares: shares * totalValueBefore /
        // totalSupply — the pool-wide total shares outstanding, NOT this caller's own share
        // balance (using userShares here would let anyone burning 100% of their own shares walk
        // away with the value of the ENTIRE pool whenever they aren't the sole LP). reserve0/
        // reserve1 (this pool's own tracked reserves, not the PoolManager's global claim balance —
        // see poolReserve0/1) and the live price give the *same* token0-equivalent value formula
        // addLiquidity's share minting uses (SwapMath.valueOf), so `shares` worth of value is
        // pinned down before any bin is touched. The range walk below then drains only the
        // caller's chosen bins until that value is redeemed, and reverts rather than
        // over/under-paying if the range can't cover it — this is what keeps a caller from
        // cherry-picking favorably-priced bins to redeem shares at more than their fair value, at
        // other LPs' expense.
        uint256 reserve0 = poolReserve0[id];
        uint256 reserve1 = poolReserve1[id];
        uint256 targetValue =
            FullMath.mulDiv(SwapMath.valueOf(reserve0, reserve1, book.sqrtPriceX96), shares, totalShares[id]);

        (amount0, amount1) = _decreaseUserLInRange(id, msg.sender, minB, maxB, targetValue);

        // tokenAmountsForBin recomputes token0/token1 fresh from L, while depositLBase derived
        // the amounts originally taken in by proportionally scaling a shared per-bin reference
        // (so a multi-bin deposit's total never drifts over its budget under floor rounding) —
        // the two paths can disagree by a few wei per bin. Clamp to this pool's own tracked
        // reserve (read before the walk above; nothing external can move it in between) so that
        // drift can never make a withdrawal try to pull out more than the pool is tracked to hold.
        if (amount0 > reserve0) amount0 = reserve0;
        if (amount1 > reserve1) amount1 = reserve1;

        poolReserve0[id] = reserve0 - amount0;
        poolReserve1[id] = reserve1 - amount1;
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

    function _getSwapFeeAmount(PoolKey calldata key, SwapParams calldata, uint256)
        internal
        view
        override
        returns (uint256)
    {
        return _lastSwapFee[key.toId()];
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

    /*//////////////////////////////////////////////////////////////
                              POOL CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a pool against this hook with bin size chosen and locked atomically.
    /// @dev The only way to create a BinBook pool. Self-initializes: v4 skips all hook callbacks
    ///      when the hook is the caller, so registration normally done by hooks is performed here.
    ///      binSize is immutable for the pool's lifetime; different granularity requires a new pool,
    ///      mirroring Uniswap v4 tickSpacing and Trader Joe binStep semantics.
    /// @param key The pool key; currency0 must sort below currency1 and key.hooks must be this contract
    /// @param sqrtPriceX96 The starting sqrt price
    /// @param _binSize Number of ticks per bin (1..2_000), immutable once set
    function createPool(PoolKey calldata key, uint160 sqrtPriceX96, int24 _binSize) external {
        if (!(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1))) {
            revert IPoolManager.CurrenciesOutOfOrderOrEqual(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        if (key.hooks != IHooks(address(this))) revert InvalidHook();
        _validateBinSize(_binSize);

        PoolId id = key.toId();
        poolManager.initialize(key, sqrtPriceX96);

        initializedPools[id] = true;
        poolCreator[id] = msg.sender;

        books[id] = BinLayout.Book({
            binSize: _binSize,
            baseRamp: DEFAULT_RAMP,
            numBinsPerSide: DEFAULT_BINS_PER_SIDE,
            currentBin: 0,
            minBin: 0,
            maxBin: 0,
            sqrtPriceX96: sqrtPriceX96,
            seeded: false
        });

        emit BinSizeSet(id, msg.sender, _binSize);
        emit PoolCreated(id, msg.sender, key, _binSize);
    }

    /*//////////////////////////////////////////////////////////////
                               USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Realize and pay accrued swap fees for `msg.sender` across their bins in `key`.
    function collectFees(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        BinLayout.UserRange memory r = userRanges[id][msg.sender];
        if (!r.set) return (0, 0);

        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            BinLayout.Position storage p = positions[id][msg.sender][idx];
            if (p.liquidity == 0 && p.tokensOwed0 == 0 && p.tokensOwed1 == 0) continue;
            BinLayout.settleFees(p, feeGrowth0X128[id], feeGrowth1X128[id], idx);
            amount0 += p.tokensOwed0;
            amount1 += p.tokensOwed1;
            p.tokensOwed0 = 0;
            p.tokensOwed1 = 0;
        }

        if (amount0 == 0 && amount1 == 0) return (0, 0);

        poolReserve0[id] -= amount0;
        poolReserve1[id] -= amount1;

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

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getBinSize(PoolId id) external view returns (int24) {
        return books[id].binSize;
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

    function liquidityOf(PoolId id, address user, int24 binIndex) external view returns (uint128) {
        return positions[id][user][binIndex].liquidity;
    }

    function pendingFees(PoolId id, address user) public view returns (uint256 amount0, uint256 amount1) {
        BinLayout.UserRange memory r = userRanges[id][user];
        if (!r.set) return (0, 0);
        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            BinLayout.Position storage p = positions[id][user][idx];
            amount0 += p.tokensOwed0;
            amount1 += p.tokensOwed1;
            uint256 L = p.liquidity;
            if (L == 0) continue;
            amount0 += FullMath.mulDiv(feeGrowth0X128[id][idx] - p.feeGrowth0LastX128, L, FixedPoint128.Q128);
            amount1 += FullMath.mulDiv(feeGrowth1X128[id][idx] - p.feeGrowth1LastX128, L, FixedPoint128.Q128);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-in swap walking the book with Uniswap-style per-step fees.
    /// @dev Each step runs SwapMath.computeSwapStep against one bin; the step's fee is
    ///      credited to that bin immediately, so only bins that absorb volume earn.
    function _swapExactIn(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        internal
        returns (uint256 amountOut)
    {
        PoolId id = key.toId();
        BinLayout.Book storage b = books[id];

        (SwapMath.Bin[] memory bins, uint256 active) = _loadBins(id);
        if (bins.length == 0) revert SwapMath.InsufficientLiquidity();

        WalkCtx memory w;
        w.remaining = amountIn;
        w.sqrtEnd = b.sqrtPriceX96;
        w.endIndex = active;

        if (zeroForOne) {
            for (uint256 i = active;;) {
                SwapMath.CoreStep memory c = _computeCoreStep(bins[i], w.sqrtEnd, w.remaining, key.fee, true);
                w.remaining -= c.amountIn + c.feeAmount;
                w.amountOut += c.amountOut;
                w.feeTotal += c.feeAmount;
                w.sqrtEnd = c.sqrtNext;
                w.endIndex = i;
                _accrueFee(id, b.minBin + int24(int256(i)), c.feeAmount, true);
                if (w.remaining == 0 || i == 0) break;
                unchecked {
                    --i;
                }
            }
        } else {
            uint256 last = bins.length - 1;
            for (uint256 i = active; i <= last;) {
                SwapMath.CoreStep memory c = _computeCoreStep(bins[i], w.sqrtEnd, w.remaining, key.fee, false);
                w.remaining -= c.amountIn + c.feeAmount;
                w.amountOut += c.amountOut;
                w.feeTotal += c.feeAmount;
                w.sqrtEnd = c.sqrtNext;
                w.endIndex = i;
                _accrueFee(id, b.minBin + int24(int256(i)), c.feeAmount, false);
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

        // Mirror the swap's net token flow into this pool's own tracked reserves: the trader's
        // full `amountIn` (principal + fee — w.remaining hit 0, so all of it landed in the pool)
        // came in on one side, `amountOut` left on the other.
        if (zeroForOne) {
            poolReserve0[id] += amountIn;
            poolReserve1[id] -= amountOut;
        } else {
            poolReserve1[id] += amountIn;
            poolReserve0[id] -= amountOut;
        }
    }

    /// @dev Box computeSwapStep's tuple into one memory slot (stack-too-deep hygiene).
    function _computeCoreStep(
        SwapMath.Bin memory bin,
        uint160 sqrtP,
        uint256 remaining,
        uint24 feePips,
        bool zeroForOne
    ) private pure returns (SwapMath.CoreStep memory c) {
        (c.sqrtNext, c.amountIn, c.amountOut, c.feeAmount) =
            SwapMath.computeSwapStep(bin, sqrtP, -int256(remaining), feePips, zeroForOne);
    }

    function _commitSwap(PoolId id, uint160 sqrtEnd, uint256 endIndex) internal {
        BinLayout.Book storage b = books[id];
        b.sqrtPriceX96 = sqrtEnd;
        b.currentBin = b.minBin + int24(int256(endIndex));
    }

    /// @dev Burns a single, uniform fraction (`targetValue / rangeValue`) of the caller's L from
    ///      every bin in `[minB, maxB]`, returning the token0/token1 that L actually backs — this
    ///      user's own position within the requested range, not a slice of the pool's aggregate
    ///      reserves. Two passes rather than an order-dependent running-total walk: measuring the
    ///      range's total value first (pass 1) before burning anything means the fraction applied
    ///      is the same for every bin, so it can never exceed `targetValue` in aggregate (capping
    ///      what a caller can extract regardless of which bins they point at — see
    ///      `_getAmountOut`'s value-target comment) and any cross-path rounding drift (see
    ///      `tokenAmountsForBin` vs `depositLBase`) lands as a tiny uniform residue instead of
    ///      concentrated in whichever bin a running-total walk happened to stop at. Reverts if the
    ///      range doesn't hold enough value to cover the target at all.
    function _decreaseUserLInRange(PoolId id, address user, int24 minB, int24 maxB, uint256 targetValue)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (targetValue == 0) return (0, 0);

        BinLayout.Book storage book = books[id];

        // Pass 1: settle fees and measure this range's total redeemable value at the current
        // price. No liquidity is touched yet.
        uint256 rangeValue;
        for (int24 idx = minB; idx <= maxB; ++idx) {
            BinLayout.Position storage p = positions[id][user][idx];
            uint256 L = p.liquidity;
            if (L == 0) continue;
            BinLayout.settleFees(p, feeGrowth0X128[id], feeGrowth1X128[id], idx);

            (uint256 t0, uint256 t1) = book.tokenAmountsForBin(idx, L);
            rangeValue += SwapMath.valueOf(t0, t1, book.sqrtPriceX96);
        }

        if (rangeValue < targetValue) revert InsufficientRangeLiquidity();

        // Pass 2: burn targetValue/rangeValue (<= 1, guaranteed by the check above) of L from
        // every bin. Floors, so aggregate redeemed value can only ever land at or under the
        // target — the same rounding-direction convention as depositLBase's clamp.
        uint256 fractionQ128 = FullMath.mulDiv(targetValue, FixedPoint128.Q128, rangeValue);
        for (int24 idx = minB; idx <= maxB; ++idx) {
            BinLayout.Position storage p = positions[id][user][idx];
            uint256 L = p.liquidity;
            if (L == 0) continue;

            uint256 burnL = FullMath.mulDiv(L, fractionQ128, FixedPoint128.Q128);
            if (burnL == 0) continue;
            if (burnL > L) burnL = L;

            (uint256 t0, uint256 t1) = book.tokenAmountsForBin(idx, burnL);
            amount0 += t0;
            amount1 += t1;

            p.liquidity = uint128(L - burnL);
            liquidity[id][idx] -= uint128(burnL);
        }
    }

    /// @dev Expands the book to cover the window (emitting `BookExpanded`), then delegates the
    ///      funded-bin walk to `BinLayout.depositLBase`.
    function _depositLBase(
        PoolId id,
        BinLayout.Window memory window,
        uint256 lBase,
        BinLayout.ReferenceBin[] memory refBins,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address user
    ) internal returns (uint256 amount0, uint256 amount1) {
        _expandBook(id, window.minB, window.maxB, window.cur);
        (amount0, amount1) = BinLayout.depositLBase(
            window.minB,
            lBase,
            refBins,
            amount0Desired,
            amount1Desired,
            user,
            liquidity[id],
            feeGrowth0X128[id],
            feeGrowth1X128[id],
            positions[id],
            userRanges[id]
        );
    }

    function _accrueFee(PoolId id, int24 idx, uint256 fee, bool zeroForOne) internal {
        uint256 L = liquidity[id][idx];
        if (fee == 0 || L == 0) return;
        uint256 delta = FullMath.mulDiv(fee, FixedPoint128.Q128, L);
        if (zeroForOne) feeGrowth0X128[id][idx] += delta;
        else feeGrowth1X128[id][idx] += delta;
    }

    function _expandBook(PoolId id, int24 fillMin, int24 fillMax, int24 cur) internal {
        (int24 minBin, int24 maxBin, bool expanded) = books[id].expandBook(fillMin, fillMax, cur);
        if (expanded) emit BookExpanded(id, minBin, maxBin);
    }

    /// @dev Materializes the contiguous book as an ascending-price bin array for the swap walk.
    function _loadBins(PoolId id) internal view returns (SwapMath.Bin[] memory bins, uint256 active) {
        BinLayout.Book storage b = books[id];
        uint256 n = uint256(int256(b.maxBin - b.minBin + 1));
        bins = new SwapMath.Bin[](n);
        for (uint256 i = 0; i < n; ++i) {
            int24 idx = b.minBin + int24(int256(i));
            int24 tickLo = b.tickLowerAtBin(idx);
            bins[i] = SwapMath.Bin({
                L: liquidity[id][idx],
                sqrtLo: TickMath.getSqrtPriceAtTick(tickLo),
                sqrtHi: TickMath.getSqrtPriceAtTick(tickLo + b.binSize)
            });
            if (idx == b.currentBin) active = i;
        }
    }

    /// @dev Shared bin size validation for createPool.
    function _validateBinSize(int24 _binSize) private pure {
        if (_binSize <= 0 || uint256(uint24(_binSize)) > 2_000) revert InvalidBinSize();
    }
}
