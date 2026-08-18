// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseCustomAccounting} from "@openzeppelin/uniswap-hooks/src/base/BaseCustomAccounting.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/*//////////////////////////////////////////////////////////////
                            BIN CONCEPT
//////////////////////////////////////////////////////////////*/
// Uniswap v4 prices live on a tick scale where each tick = 0.01% price change.
// Instead of tracking every tick, we group ticks into larger buckets called BINS.
//
//   binSize = number of ticks per bin
//
//   binSize = 60   ->  each bin spans ~0.6% price   ->  tight bins for stable pairs
//   binSize = 200  ->  each bin spans ~2.0% price   ->  wide bins for volatile pairs
//   binSize = 10   ->  each bin spans ~0.1% price   ->  very fine for pegged assets
//
// Bins tile the tick number line symmetrically around 0:
//
//         ... | bin -2        | bin -1        | bin 0         | bin 1         | bin 2        | ...
//   ticks: ... [-120, -60)    [-60, 0)        [0, 60)         [60, 120)       [120, 180)     ...
//   price: ...  low  <---------------------------- center (1:1) --------------------------->  high
//
// The hook tracks which bin the pool price currently sits in (currentBin).
// When a swap pushes price across a bin boundary, currentBin ratchets forward.
// The ratchet is one-directional per swap direction - preventing sandwich attacks
// from pulling price back to a previous bin.
//
// halfWidthBins controls how many bins away from center the price is allowed to move.
// If price tries to go beyond +/-halfWidthBins, the swap reverts.

/*//////////////////////////////////////////////////////////////
                        TYPE DECLARATIONS
//////////////////////////////////////////////////////////////*/

/// @notice Per-pool bin configuration
struct BinConfig {
    /// @notice Number of ticks per bin
    ///   60  = ~0.6% per bin  -> stable pairs
    ///   200 = ~2.0% per bin  -> volatile pairs
    int24 binSize; // ----------- 3 bytes
    // TODO: fee formula parameters
}

/// @notice Per-pool runtime state
struct BinState {
    int24 currentBin; // --------- 3 bytes
    BinConfig config; // --------- 3 bytes  (packed into 1 slot)
}

contract BinRatchet is BaseCustomAccounting {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-pool bin state (current bin + config)
    mapping(PoolId poolId => BinState) public binStates;

    /// @notice Per-pool creator address (captured automatically at pool creation)
    mapping(PoolId poolId => address creator) public poolCreator;

    /// @notice Whether bin size has been set for a pool (immutable once set)
    mapping(PoolId poolId => bool) public binSizeSet;

    /// @notice Total shares per pool
    mapping(PoolId poolId => uint256) public totalShares;

    /// @notice Shares per user per pool
    mapping(PoolId poolId => mapping(address user => uint256)) public sharesOf;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when pool creator configures bin size
    event BinSizeSet(PoolId indexed poolId, address indexed creator, int24 binSize);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the pool creator
    error NotPoolCreator();

    /// @notice Bin size has already been set for this pool
    error BinSizeAlreadySet();

    /// @notice Invalid bin size (must be > 0)
    error InvalidBinSize();

    /// @notice Pool has not been initialized with bin size yet
    error PoolNotConfigured();

    /// @notice Swap would exceed allowed bin range
    error RangeNotAlignedToBins();

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager) BaseCustomAccounting(_poolManager) {}

    /*//////////////////////////////////////////////////////////////
                           HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                           HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates tick alignment before liquidity is added
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId id = key.toId();
        if (!binSizeSet[id]) revert PoolNotConfigured();

        // Capture pool creator on first liquidity add (beforeInitialize is non-virtual)
        if (poolCreator[id] == address(0)) {
            poolCreator[id] = sender;
        }

        int24 binSize = binStates[id].config.binSize;
        if (params.tickLower % binSize != 0 || params.tickUpper % binSize != 0) {
            revert RangeNotAlignedToBins();
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Captures the pool creator address during pool initialization
    function _afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        poolCreator[id] = sender;
        return IHooks.afterInitialize.selector;
    }

    /// @notice Per-bin liquidity distribution loop
    /// @dev Overrides BaseCustomAccounting to distribute liquidity across individual bins
    function unlockCallback(bytes calldata rawData)
        external
        override
        onlyPoolManager
        returns (bytes memory returnData)
    {
        // TODO: implement per-bin loop
        // 1. Decode CallbackData
        // 2. Get binSize from binStates
        // 3. Calculate numBins = (tickUpper - tickLower) / binSize
        // 4. Loop over bins:
        //    a. TickMath.getSqrtPriceAtTick for bin boundaries
        //    b. StateLibrary.getTickLiquidity for existing liquidity
        //    c. Calculate proportional token share
        //    d. LiquidityAmounts.getLiquidityForAmounts
        //    e. Cap if existing + new > max
        //    f. poolManager.modifyLiquidity per bin
        //    g. Settle tokens
        // 5. Return unused tokens

        revert("not implemented");
    }

    /*//////////////////////////////////////////////////////////////
                           ADD LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @notice Adds liquidity to the pool with bin-aligned tick ranges
    function addLiquidity(AddLiquidityParams calldata params) external payable override returns (BalanceDelta delta) {
        PoolId id = poolKey.toId();
        if (!binSizeSet[id]) revert PoolNotConfigured();
        delta = BaseCustomAccounting(address(this)).addLiquidity(params);
    }

    /// @dev Snaps ticks to bin boundaries and returns modify params + shares
    function _getAddLiquidity(uint160, AddLiquidityParams memory params)
        internal
        override
        returns (bytes memory modify, uint256 shares)
    {
        PoolId id = poolKey.toId();
        int24 binSize = binStates[id].config.binSize;

        int24 tickLower = _snapToLowerBin(params.tickLower, binSize);
        int24 tickUpper = _snapToUpperBin(params.tickUpper, binSize);

        if (tickLower >= tickUpper) revert RangeNotAlignedToBins();

        shares = uint256(uint128(params.amount0Desired)) + uint256(uint128(params.amount1Desired));

        modify = abi.encode(
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: params.userInputSalt
            })
        );
    }

    /// @dev Required by BaseCustomAccounting but removal is not supported
    function _getRemoveLiquidity(RemoveLiquidityParams memory) internal pure override returns (bytes memory, uint256) {
        revert("removal not supported");
    }

    /*//////////////////////////////////////////////////////////////
                          SHARE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints shares to the sender
    function _mint(AddLiquidityParams memory params, BalanceDelta, BalanceDelta, uint256 shares) internal override {
        PoolId id = poolKey.toId();
        totalShares[id] += shares;
        sharesOf[id][msg.sender] += shares;
    }

    /// @dev Burns shares from the sender (not used, removal blocked)
    function _burn(RemoveLiquidityParams memory, BalanceDelta, BalanceDelta, uint256) internal pure override {
        revert("removal not supported");
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set bin size for a pool (called once by pool creator after creation)
    /// @param key The pool key
    /// @param _binSize Number of ticks per bin (must be > 0)
    function setBinSize(PoolKey calldata key, int24 _binSize) external {
        PoolId id = key.toId();

        if (msg.sender != poolCreator[id]) revert NotPoolCreator();
        if (binSizeSet[id]) revert BinSizeAlreadySet();
        if (_binSize <= 0) revert InvalidBinSize();

        binStates[id].config.binSize = _binSize;
        binSizeSet[id] = true;

        emit BinSizeSet(id, msg.sender, _binSize);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get bin size for a pool
    /// @param poolId The pool ID
    /// @return The bin size in ticks
    function getBinSize(PoolId poolId) external view returns (int24) {
        return binStates[poolId].config.binSize;
    }

    /// @notice Check if pool has been configured with bin size
    /// @param poolId The pool ID
    /// @return True if bin size has been set
    function isConfigured(PoolId poolId) external view returns (bool) {
        return binSizeSet[poolId];
    }

    /// @notice Get total shares for a pool
    /// @param poolId The pool ID
    /// @return Total shares outstanding
    function getTotalShares(PoolId poolId) external view returns (uint256) {
        return totalShares[poolId];
    }

    /// @notice Get shares for a specific user in a pool
    /// @param poolId The pool ID
    /// @param user The user address
    /// @return Shares held by user
    function getShares(PoolId poolId, address user) external view returns (uint256) {
        return sharesOf[poolId][user];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert tick to bin index
    /// @param tick The current tick
    /// @param binSize Number of ticks per bin
    /// @return The bin index
    function _tickToBin(int24 tick, int24 binSize) internal pure returns (int24) {
        return tick / binSize;
    }

    /// @notice Snap a tick down to the lower boundary of its bin
    function _snapToLowerBin(int24 tick, int24 binSize) internal pure returns (int24) {
        if (tick >= 0) {
            return (tick / binSize) * binSize;
        } else {
            return -(((-tick - 1) / binSize) * binSize + binSize);
        }
    }

    /// @notice Snap a tick up to the upper boundary of its bin
    function _snapToUpperBin(int24 tick, int24 binSize) internal pure returns (int24) {
        if (tick >= 0) {
            return ((tick + binSize - 1) / binSize) * binSize;
        } else {
            return -(((-tick - 1) / binSize) * binSize);
        }
    }
}
