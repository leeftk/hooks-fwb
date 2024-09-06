// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {console} from "forge-std/console.sol";

/// @title TWAMMHook - Time-Weighted Average Market Maker Hook for Uniswap v4
/// @notice This contract implements a TWAMM mechanism for automated token buybacks
/// @dev Inherits from BaseHook and Ownable, and implements Uniswap v4 hook interface
contract TWAMMHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    event BuybackInitiated(
        PoolId poolId,
        uint256 totalAmount,
        uint256 duration
    );
    event BuybackOrderUpdated(
        PoolId poolId,
        uint256 newTotalAmount,
        uint256 newDuration,
        uint256 executionInterval
    );
    event BuybackCancelled(PoolId poolId);

    struct BuybackOrder {
        address initiator;
        uint256 totalAmount;
        uint256 amountBought;
        uint256 startTime;
        uint256 endTime;
        uint256 lastExecutionTime;
        uint256 executionInterval;
    }

    mapping(PoolId => BuybackOrder) public buybackOrders;
    mapping(PoolId => uint256) public buybackAmounts;
    mapping(PoolId => uint256) public claimTokensSupply; //@audit-info -> mapping declared but never used
    address public immutable daoToken;
    address public daoTreasury;
    uint256 public maxBuybackDuration;

    error DurationExceedsMaximum();
    error ExistingBuybackInProgress();
    error OnlyInitiatorCanClaim();
    error NoTokensToClaim();
    error UnauthorizedCaller();
    error IntervalDoesNotDivideDuration();
    error BuyBackOrderDoesNotExist();

    /// @notice Constructs the TWAMMHook contract
    /// @param _poolManager The address of the Uniswap v4 pool manager
    /// @param _daoToken The address of the DAO's token
    /// @param _daoTreasury The address of the DAO's treasury
    /// @param _maxBuybackDuration The maximum duration allowed for buyback orders
    constructor(
        IPoolManager _poolManager,
        address _daoToken,
        address _daoTreasury,
        uint256 _maxBuybackDuration
    ) BaseHook(_poolManager) Ownable(msg.sender) {
        daoToken = _daoToken;
        daoTreasury = _daoTreasury;
        maxBuybackDuration = _maxBuybackDuration;
    }

    /// @notice Returns the hook's permissions for Uniswap v4 operations
    /// @return Hooks.Permissions struct indicating which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Initiates a new buyback order
    /// @param key The PoolKey for the pool where the buyback will occur
    /// @param totalAmount The total amount of tokens to buy back
    /// @param duration The duration over which the buyback should occur
    /// @return The PoolKey of the initiated buyback
    function initiateBuyback(
        PoolKey calldata key,
        uint256 totalAmount,
        uint256 duration,
        uint256 executionInterval
    ) external returns (PoolKey memory) {
        //@audit-info -> Currently, for the MVP demo, this should be okay but in PROD this should be a permissioned function or a malicious user can frontrun that can result in DoS attack vectors
        if (duration % executionInterval != 0)
            revert IntervalDoesNotDivideDuration();
        if (duration > maxBuybackDuration) revert DurationExceedsMaximum();
        PoolId poolId = key.toId();
        if (buybackOrders[poolId].totalAmount != 0)
            revert ExistingBuybackInProgress();

        buybackOrders[poolId] = BuybackOrder({
            initiator: msg.sender,
            totalAmount: totalAmount,
            amountBought: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            lastExecutionTime: block.timestamp,
            executionInterval: executionInterval
        });
        buybackAmounts[poolId] = totalAmount; //@audit-info -> currently unsure of what the mapping is being used for ??

        ERC20(Currency.unwrap(key.currency0)).transferFrom(
            msg.sender,
            address(this),
            totalAmount
        );

        emit BuybackInitiated(poolId, totalAmount, duration);

        return key;
    }

    /// @notice Updates an existing buyback order
    /// @param key The PoolKey for the pool where the buyback is occurring
    /// @param newTotalAmount The new total amount for the buyback
    /// @param newDuration The new duration for the buyback
    function updateBuybackOrder(
        PoolKey calldata key,
        uint256 newTotalAmount,
        uint256 newDuration,
        uint256 executionInterval
    ) external {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (newDuration % executionInterval != 0)
            revert IntervalDoesNotDivideDuration();
        if (msg.sender != order.initiator) revert UnauthorizedCaller();
        if (newDuration > maxBuybackDuration) revert DurationExceedsMaximum();

        uint256 remainingAmount = order.totalAmount - order.amountBought; //@audit-info -> "remainingAmount" is never used
        if (newTotalAmount < order.amountBought)
            revert(
                "New total amount must be greater than amount already bought"
            );

        // Transfer additional funds if new total amount is greater
        if (newTotalAmount > order.totalAmount) {
            uint256 additionalAmount = newTotalAmount - order.totalAmount;
            ERC20(Currency.unwrap(key.currency0)).transferFrom(
                msg.sender,
                address(this),
                additionalAmount
            );
        } //@audit-info -> missing else logic in case where newTotalAmount < order.totalAmount, in that case, some of the key.currency0 needs to be refunded, need to code it -- zzzuhaibmohd

        // Update the order
        order.totalAmount = newTotalAmount;
        order.endTime = block.timestamp + newDuration;
        buybackAmounts[poolId] = newTotalAmount - order.amountBought;

        emit BuybackOrderUpdated(
            poolId,
            newTotalAmount,
            newDuration,
            executionInterval
        );
    }

    function cancelBuyback(
        PoolKey calldata key
    ) external returns (PoolKey memory) {
        PoolId poolId = key.toId();
        if (
            buybackOrders[poolId].totalAmount == 0 &&
            buybackOrders[poolId].initiator == address(0)
        ) revert BuyBackOrderDoesNotExist();

        if (msg.sender != buybackOrders[poolId].initiator) revert UnauthorizedCaller();
        
        uint256 refundAmount = buybackOrders[poolId].totalAmount -
            buybackOrders[poolId].amountBought;
        if (refundAmount > 0) {
            ERC20(Currency.unwrap(key.currency0)).transfer(
                msg.sender,
                refundAmount
            );
        }
        
        //Set the poolId struct to default values
        buybackOrders[poolId] = BuybackOrder({ 
            initiator: address(0),
            totalAmount: 0,
            amountBought: 0,
            startTime: 0,
            endTime: 0,
            lastExecutionTime: 0,
            executionInterval: 0
        });

        emit BuybackCancelled(poolId);

        return key;
    }

    /// @notice Executes partial buybacks during swap operations
    /// @dev This function is called by the Uniswap v4 pool before each swap
    /// @param key The PoolKey for the pool where the swap is occurring
    /// @param params The swap parameters
    /// @return The selector of this function, the swap delta, and the fee
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (order.totalAmount > 0) {
            //if I set an order for 1000 for 100 hours
            // then i set an interval for 10 hours
            // what does amountToBuy equal?
            /// amount* interval/duration
            uint256 amountToBuy = (order.totalAmount *
                order.executionInterval) / (order.endTime - order.startTime);
            uint256 nextExpirationTimestamp = order.lastExecutionTime +
                (order.executionInterval -
                    (order.lastExecutionTime % order.executionInterval));

            if (amountToBuy > 0) {
                // Execute partial buyback
                // Note: This is a simplified version. Need to implement the actual swap logic here.
                order.amountBought += amountToBuy;
                order.lastExecutionTime = nextExpirationTimestamp;

                // Return the amount to buy as a delta
                return (
                    BaseHook.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    0
                );
            }
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    /// @notice Allows the initiator to claim bought tokens
    /// @param key The PoolKey for the pool where the buyback occurred
    function claimBoughtTokens(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (msg.sender != order.initiator) revert OnlyInitiatorCanClaim();
        if (order.amountBought == order.totalAmount)
            revert ExistingBuybackInProgress();
        if (order.amountBought == 0) revert NoTokensToClaim();

        uint256 amountToClaim = order.amountBought;
        order.amountBought = 0;

        buybackOrders[poolId] = BuybackOrder({ // Since the order has been filled, enable the claiming of tokens and reset the struct
            initiator: address(0),
            totalAmount: 0,
            amountBought: 0,
            startTime: 0,
            endTime: 0,
            lastExecutionTime: 0,
            executionInterval: 0
        });

        ERC20(daoToken).transfer(order.initiator, amountToClaim);
    }

    /// @notice Sets a new DAO treasury address
    /// @param _newTreasury The address of the new treasury
    function setDaoTreasury(address _newTreasury) external onlyOwner {
        daoTreasury = _newTreasury;
    }

    /// @notice Sets a new maximum buyback duration
    /// @param _newMaxDuration The new maximum duration for buybacks
    function setMaxBuybackDuration(uint256 _newMaxDuration) external onlyOwner {
        maxBuybackDuration = _newMaxDuration;
    }

    /// @notice Retrieves details of a buyback order
    /// @param key The PoolKey for the pool to query
    /// @return initiator The address that initiated the buyback
    /// @return totalAmount The total amount of tokens to buy back
    /// @return amountBought The amount of tokens already bought
    /// @return startTime The timestamp when the buyback started
    /// @return endTime The timestamp when the buyback will end
    /// @return lastExecutionTime The timestamp of the last partial execution
    /// @return remainingTime The time remaining until the buyback ends
    /// @return totalDuration The total duration of the buyback
    /// @return remainingAmount The amount of tokens left to buy
    function getBuybackOrderDetails(
        PoolKey calldata key
    )
        external
        view
        returns (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime,
            uint256 remainingTime,
            uint256 totalDuration,
            uint256 remainingAmount
        )
    {
        PoolId poolId = key.toId();
        BuybackOrder memory order = buybackOrders[poolId];

        initiator = order.initiator;
        totalAmount = order.totalAmount;
        amountBought = order.amountBought;
        startTime = order.startTime;
        endTime = order.endTime;
        lastExecutionTime = order.lastExecutionTime;
        remainingTime = order.endTime > block.timestamp
            ? order.endTime - block.timestamp
            : 0;
        totalDuration = order.endTime - order.startTime;
        remainingAmount = order.totalAmount - order.amountBought;
    }

    /// @notice Calculates the time until the next buyback execution
    /// @param key The PoolKey for the pool to query
    /// @return The time in seconds until the next execution
    function getTimeUntilNextExecution(
        PoolKey calldata key
    ) external view returns (uint256) {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (order.totalAmount == 0 || block.timestamp >= order.endTime) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - order.lastExecutionTime;
        uint256 totalDuration = order.endTime - order.startTime; // Execute 100 times over the total duration
        uint256 executionInterval = (totalDuration * 1e18) / order.totalAmount;

        console.log("executionInterval", executionInterval);
        console.log("elapsedTime", elapsedTime);

        if (executionInterval > elapsedTime) {
            return executionInterval - elapsedTime;
        }
        //// this should be the time remaing until the next execution which equals the
        return elapsedTime % executionInterval;
    }

    /// @notice Calculates the progress of a buyback order as a percentage
    /// @dev Computes the percentage of completed intervals in a buyback order
    /// @param key The PoolKey for the pool where the buyback is occurring
    /// @return percentComplete The percentage of the buyback that has been completed (0-100)
    function getBuybackProgress(
        PoolKey calldata key
    ) external view returns (uint256 percentComplete) {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (order.totalAmount == 0) {
            return 0;
        }
        // Calculate progress percentage
        // Example: totalAmount = 10000, executionInterval = 10
        // totalAmountOfIntervals = 10000 / 10 = 1000
        // If 250 intervals have passed:
        // percentComplete = (250 * 100) / 1000 = 25%

        uint256 totalAmountOfIntervals = (order.endTime - order.startTime) /
            order.executionInterval;
        uint256 timeElapsed = block.timestamp - order.startTime;
        uint256 remainder = timeElapsed % order.executionInterval;
        uint256 timeElapsedIntervals = timeElapsed -
            remainder /
            order.executionInterval;

        percentComplete = (timeElapsedIntervals * 100) / totalAmountOfIntervals;

        return percentComplete;
    }
}
