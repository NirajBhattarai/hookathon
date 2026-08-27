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
    uint16 public constant MAX_BOOK_BINS = 1024;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => address) public poolCreator;
    mapping(PoolId poolId => uint256) public totalShares;
    mapping(PoolId poolId => mapping(address user => uint256)) public sharesOf;

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
    error BookTooWide();
    error InitializeViaCreatePool();
    error InvalidHook();

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

        uint256 LBase = books[id].solveLBase(window, params.amount0Desired, params.amount1Desired);
        if (LBase == 0) revert ZeroAmounts();
        (amount0, amount1) = _depositLBase(id, window, LBase, params.amount0Desired, params.amount1Desired, msg.sender);
        shares = amount0 + amount1;
        if (shares == 0) revert ZeroAmounts();
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
            ramp: DEFAULT_RAMP,
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
            BinLayout.realizeFees(p, feeGrowth0X128[id], feeGrowth1X128[id], idx);
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
        BinLayout.Book storage b = books[id];
        b.sqrtPriceX96 = sqrtEnd;
        b.currentBin = b.minBin + int24(int256(endIndex));
    }

    /// @dev Reduce the caller's bin L proportional to shares burned / their total shares.
    function _unwindUserL(PoolId id, address user, uint256 sharesBurned, uint256 userShares) internal {
        BinLayout.UserRange memory r = userRanges[id][user];
        if (!r.set || userShares == 0) return;

        for (int24 idx = r.minB; idx <= r.maxB; ++idx) {
            BinLayout.Position storage p = positions[id][user][idx];
            uint256 L = p.liquidity;
            if (L == 0) continue;
            BinLayout.realizeFees(p, feeGrowth0X128[id], feeGrowth1X128[id], idx);
            uint256 burnL = L * sharesBurned / userShares;
            if (burnL == 0) continue;
            if (burnL > L) burnL = L;
            p.liquidity = uint128(L - burnL);
            liquidity[id][idx] -= uint128(burnL);
            p.feeGrowth0LastX128 = feeGrowth0X128[id][idx];
            p.feeGrowth1LastX128 = feeGrowth1X128[id][idx];
        }
    }

    /// @dev Expands the book to cover the window (emitting `BookExpanded`), then delegates the
    ///      funded-bin walk to `BinLayout.depositLBase`.
    function _depositLBase(
        PoolId id,
        BinLayout.Window memory window,
        uint256 LBase,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address user
    ) internal returns (uint256 amount0, uint256 amount1) {
        _expandBook(id, window.minB, window.maxB, window.cur);
        (amount0, amount1) = books[id].depositLBase(
            window,
            LBase,
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

    function _creditFee(PoolId id, int24 idx, uint256 fee, bool zeroForOne) internal {
        uint256 L = liquidity[id][idx];
        if (fee == 0 || L == 0) return;
        uint256 delta = FullMath.mulDiv(fee, FixedPoint128.Q128, L);
        if (zeroForOne) feeGrowth0X128[id][idx] += delta;
        else feeGrowth1X128[id][idx] += delta;
    }

    function _expandBook(PoolId id, int24 fillMin, int24 fillMax, int24 cur) internal {
        BinLayout.Book storage b = books[id];
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

    /// @dev Materializes the contiguous book as an ascending-price bin array for the swap walk.
    function _loadBins(PoolId id) internal view returns (SwapMath.Bin[] memory bins, uint256 active) {
        BinLayout.Book storage b = books[id];
        uint256 n = uint256(int256(b.maxBin - b.minBin + 1));
        bins = new SwapMath.Bin[](n);
        for (uint256 i = 0; i < n; ++i) {
            int24 idx = b.minBin + int24(int256(i));
            int24 tickLo = b.tickAtBin(idx);
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
