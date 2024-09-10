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
import "forge-std/console.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

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
        uint256 lastExecutionTime; // last time we bought
        uint256 executionInterval; // why we need that
        bool zeroForOne;
        uint256 totalIntervals;
        uint256 intervalsBought;
    }

    mapping(PoolId poolId => BuybackOrder buyBackOrder) public buybackOrders;
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
    error EndTimeIsInPast();
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

    // @note - if the buyback is predictable than anyone can sandwich the transaction, but does that matter?

    // @note - pass in the zeroForOne bool too, of true transfer in currency 0 and buy back currency 1, and if it is currency 1 transfer in currency 1 and buy back currency 0

    // @note - anyone can call this, if it's a fwb deployed pool and someone calls them before them, fucked. 
    function initiateBuyback(PoolKey calldata key, uint256 totalAmount, uint256 duration, uint256 executionInterval, bool zeroForOne)
        external
        onlyOwner
        returns (PoolKey memory)
    {
        // 1000 % 10 = 0, total duration of 1000 hours and we will buys after every 10 hours, need to take care of the edge where like there is no buying for 20 hours let's say

        if (duration % executionInterval != 0) revert IntervalDoesNotDivideDuration();
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
            executionInterval: executionInterval,
            zeroForOne: zeroForOne,
            totalIntervals: (duration / executionInterval),
            intervalsBought: 0
        });
        buybackAmounts[poolId] = totalAmount; //@audit-info -> currently unsure of what the mapping is being used for ??

        if(zeroForOne)
        {
                    ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), totalAmount);
        }
        else
        {
                    ERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), totalAmount);

        }

        emit BuybackInitiated(poolId, totalAmount, duration);

        return key;
    }

    /// @notice Updates an existing buyback order
    /// @param key The PoolKey for the pool where the buyback is occurring
    /// @param newTotalAmount The new total amount for the buyback
    /// @param newEndTime The new end time for the buyback
    function updateBuybackOrder(PoolKey calldata key, uint256 newTotalAmount, uint256 newEndTime) external {
        if(newEndTime < block.timestamp) revert EndTimeIsInPast();

        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];
        if (msg.sender != order.initiator) revert UnauthorizedCaller();
        if (block.timestamp + newEndTime  > maxBuybackDuration) revert DurationExceedsMaximum();

        uint256 remainingAmount = order.totalAmount - order.amountBought;

        // if we are changing the end time, this seems like unnessary, what if he pushes time ahead and now within that time he wants to do certain buyback
        if (newTotalAmount < order.amountBought) revert("New total amount must be greater than amount already bought");

        // Transfer additional funds if new total amount is greater
        if (newTotalAmount > order.totalAmount) {
            uint256 additionalAmount = newTotalAmount - order.totalAmount;
            if(order.zeroForOne)
            {
                            ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), additionalAmount);

            }
            else
            {
                            ERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), additionalAmount);

            }
        }

        // Update the order
        order.totalAmount = newTotalAmount;
        order.endTime = newEndTime;
        buybackAmounts[poolId] = newTotalAmount - order.amountBought;

        emit BuybackOrderUpdated(poolId, newTotalAmount, newEndTime, order.executionInterval);
    }

    /// @notice Executes partial buybacks during swap operations
    /// @dev This function is called by the Uniswap v4 pool before each swap
    /// @param key The PoolKey for the pool where the swap is occurring
    /// @param params The swap parameters
    /// @return The selector of this function, the swap delta, and the fee
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // hook should not be triggered in the swap is called by hook iteself causing recursion
        if(sender == address(this))
        {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (order.totalAmount > 0 && order.amountBought < order.totalAmount) {

            if(order.endTime > block.timestamp)
            {
                // need to do something because time has gone over and we have still some buying left to do since amountBought is less than totalAmount
            }
            //if I set an order for 1000 for 100 hours
            // then i set an interval for 10 hours
            // what does amountToBuy equal?
            /// amount* interval/duration
            // depending upon how many intervals have passed since last execution, we need to buy more or less
            
            // Example:
            // Let's say order.lastExecutionTime = 1000 (seconds since epoch)
            // Current block.timestamp = 1250
            // order.executionInterval = 100 seconds

            uint256 intervalsPassed = (block.timestamp - order.lastExecutionTime) / order.executionInterval;


            // now based on intervals passed we need to calculate the amount to buy
            // let's say the  total amount is 1000, and total time is 1000 hours and interval is 100 hours
            // so there will be 10 intervals in total
            // so if I want to buy 1000 amount in 10 intervals, then at each interval I need to buy 100 amount
            // so if 2 intervals have passed, then I need to buy 200 amount
            // so if 3 intervals have passed, then I need to buy 300 amount
            // so if 4 intervals have passed, then I need to buy 400 amount
            // so if 5 intervals have passed, then I need to buy 500 amount
            // so if 6 intervals have passed, then I need to buy 600 amount
            // so if 7 intervals have passed, then I need to buy 700 amount
            // so if 8 intervals have passed, then I need to buy 800 amount
            // 2000 * 100 / 1000 = 200
            uint256 amountToBuyInSingleInterval = (order.totalAmount * order.executionInterval) / (order.endTime - order.startTime);
            uint256 amountToBuy = amountToBuyInSingleInterval * intervalsPassed;
      


            if (amountToBuy > 0) {
                // Execute partial buyback
                // Note: This is a simplified version. Weed to implement the actual swap logic here.
                // now take the current block.timestamp and set the lastExecutionTime not to this but a rounded down value where the interval started
                // Update lastExecutionTime to the start of the current interval
                // Example: If current time is 1250 and interval is 100:
                // 1250 - (1250 % 100) = 1250 - 50 = 1200
                // This ensures we're always at the beginning of an interval
                order.lastExecutionTime = block.timestamp - (block.timestamp % order.executionInterval);
                order.intervalsBought += intervalsPassed;
           
                    IPoolManager.SwapParams memory newParams = IPoolManager.SwapParams({
                        zeroForOne: order.zeroForOne,
                        amountSpecified: int256(amountToBuy),
                        sqrtPriceLimitX96: order.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    });

                    BalanceDelta delta = poolManager.swap(key, newParams, "");


                    if (order.zeroForOne) {
                        // Negative Value => Money leaving TWAMM's wallet
                        // Settle with PoolManager
                        if (delta.amount0() < 0) {
                            _settle(key.currency0, uint128(-delta.amount0()));
                        }

                        // Positive Value => Money coming into TWAMM's wallet
                        // Take from PoolManager
                        if (delta.amount1() > 0) {
                            order.amountBought += _take(key.currency1, uint128(delta.amount1()));
                        }
                    } else {
                        if (delta.amount1() < 0) {
                            _settle(key.currency1, uint128(-delta.amount1()));
                        }

                        if (delta.amount0() > 0) {
                            order.amountBought += _take(key.currency0, uint128(delta.amount0()));
                        }
                    }
               
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
            executionInterval: 0,
            zeroForOne: false,
            totalIntervals: 0,
            intervalsBought: 0
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


    function _settle(Currency currency, uint128 amount) internal {
    // Transfer tokens to PM and let it know
    console.log("amount hehe", amount);
    poolManager.sync(currency);
    currency.transfer(address(poolManager), amount);
    poolManager.settle();
}

function _take(Currency currency, uint128 amount) internal returns(uint256) {
    // Record balance before taking tokens
    uint256 balanceBefore = ERC20(Currency.unwrap(currency)).balanceOf(address(this));
    
    // Take tokens out of PM to our hook contract
    poolManager.take(currency, address(this), amount);
    
    // Record balance after taking tokens
    uint256 balanceAfter = ERC20(Currency.unwrap(currency)).balanceOf(address(this));
    
    // Calculate the actual amount bought
    uint256 amountBought = balanceAfter - balanceBefore;

    return amountBought;
    
    
}
}
