// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TWAMMHook} from "../src/TWAMMHook.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract TWAMMHookTest is Test, GasSnapshot, Deployers {
    PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TWAMMHook twammHook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        //Send 100000 tokens to twammhook
        MockERC20(Currency.unwrap(currency0)).mint(address(twammHook), 100000000000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(twammHook), 1000000000000e18);

        // Deploy hook to an address that has the proper flags set
        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "TWAMMHook.sol",
            abi.encode(IPoolManager(address(manager)), Currency.unwrap(currency0), address(this), 7000 days),
            hookAddress
        );
        twammHook = TWAMMHook(address(flags));
        MockERC20(Currency.unwrap(currency0)).approve(address(twammHook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(twammHook), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(
            currency0,
            currency1,
            twammHook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );
        poolKey = key;

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_TWAMMHook_InitiateBuyback() public {
        PoolId poolId = poolKey.toId();
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        //token0.mint(address(this), buybackAmount);
        MockERC20(Currency.unwrap(currency0)).approve(address(twammHook), buybackAmount);

        PoolKey memory returnedKey = twammHook.initiateBuyback(poolKey, buybackAmount, duration);
        //totalAmount should be buybackAmount
        uint256 totalAmounts = twammHook.buybackAmounts(poolId);
        console.log("totalAmount", totalAmounts);

        (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime
        ) = twammHook.buybackOrders(poolId);

        assertEq(initiator, address(this));
        assertEq(totalAmount, buybackAmount);
        assertEq(amountBought, 0);
        assertEq(endTime - startTime, duration);
        assertEq(lastExecutionTime, startTime);
    }

    function test_TWAMMHook_InitiateBuybckRevertDurationExceedsMaximum() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 80000 days;

        vm.expectRevert(TWAMMHook.DurationExceedsMaximum.selector);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);
    }

    function test_TWAMMHook_InitiateBuybckRevert_ExistingBuybackInProgress() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        vm.expectRevert(TWAMMHook.ExistingBuybackInProgress.selector);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);
    }

    function test_TWAMMHook_VerifyBuybackOrderExecutes() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        //token0.mint(address(this), buybackAmount);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);
        //Conduct swap
        bool zeroForOne = true;
        vm.warp(block.timestamp + 100 days);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 100 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, params, testSettings, "");
        //send tokens back to twammhook
        MockERC20(Currency.unwrap(currency0)).transfer(address(twammHook), 100000000000e18);
        // Simulate some tokens being bought
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        console.log("claimtokens balance hook", IERC20(Currency.unwrap(currency0)).balanceOf(address(twammHook)));
        twammHook.claimBoughtTokens(poolKey);
        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        assertGt(balanceAfter, balanceBefore);
    }

    function test_TWAMMHook_UpdateBuybackOrder() public {
        PoolId poolId = poolKey.toId();
        uint256 initialAmount = 1000e18;
        uint256 initialDuration = 1 days;
        
        // Approve tokens
        MockERC20(Currency.unwrap(currency0)).approve(address(twammHook), type(uint256).max);
        
        // Initiate buyback
        twammHook.initiateBuyback(poolKey, initialAmount, initialDuration);
        
        // Prepare update parameters
        uint256 newAmount = 1500e18;
        uint256 newDuration = 2 days;
        
        // Update buyback order
        twammHook.updateBuybackOrder(poolKey, newAmount, newDuration);
        
        // Check updated values
          (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime
        ) = twammHook.buybackOrders(poolId);

        assertEq(totalAmount, newAmount, "Total amount not updated correctly");
        assertEq(endTime, block.timestamp + newDuration, "End time not updated correctly");
        assertEq(twammHook.buybackAmounts(poolKey.toId()), newAmount, "Buyback amount not updated correctly");
        
        // Check token transfer
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(twammHook)), newAmount, "Hook balance not updated correctly");
    }

    function test_TWAMMHook_ClaimBoughtTokens_Revert_OnlyInitiatorCanClaim() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        vm.prank(address(0xdead));
        vm.expectRevert(TWAMMHook.OnlyInitiatorCanClaim.selector);
        twammHook.claimBoughtTokens(poolKey);
    }

    function test_TWAMMHook_ClaimBoughtTokens_Revert_NoTokensToClaim() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        vm.expectRevert(TWAMMHook.NoTokensToClaim.selector);
        twammHook.claimBoughtTokens(poolKey);
    }

    function test_TWAMMHook_SetDaoTreasury() public {
        address newTreasury = address(0xdead);
        twammHook.setDaoTreasury(newTreasury);
        assertEq(twammHook.daoTreasury(), newTreasury);
    }

    function test_TWAMMHook_SetMaxBuybackDuration() public {
        uint256 newMaxDuration = 14 days;
        twammHook.setMaxBuybackDuration(newMaxDuration);
        assertEq(twammHook.maxBuybackDuration(), newMaxDuration);
    }

    function test_TWAMMHook_GetBuybackOrderDetails() public {
        PoolId poolId = poolKey.toId();
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        // Warp time to simulate some progress
        vm.warp(block.timestamp + 12 hours);

        (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime,
            uint256 remainingTime,
            uint256 totalDuration,
            uint256 remainingAmount
        ) = twammHook.getBuybackOrderDetails(poolKey);

        assertEq(initiator, address(this), "Incorrect initiator");
        assertEq(totalAmount, buybackAmount, "Incorrect total amount");
        assertEq(amountBought, 0, "Incorrect amount bought"); // Assuming no swaps have occurred
        assertEq(endTime - startTime, duration, "Incorrect duration");
        assertEq(remainingTime, 12 hours, "Incorrect remaining time");
        assertEq(totalDuration, duration, "Incorrect total duration");
        assertEq(remainingAmount, buybackAmount, "Incorrect remaining amount");
    }

    function test_TWAMMHook_GetTimeUntilNextExecution() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(twammHook))
        });

        twammHook.initiateBuyback(key, 1e21, 86400); // 1 day duration

        // Check time remaining at the start
        uint256 timeRemaining = twammHook.getTimeUntilNextExecution(key);
        assertGt(timeRemaining, 0, "Time until next execution should be greater than 0 at start");
        assertLe(timeRemaining, 86400, "Time until next execution should be less than or equal to total duration");

        // Warp to middle of the buyback period
        vm.warp(block.timestamp + 43200); // Half day

        timeRemaining = twammHook.getTimeUntilNextExecution(key);
        assertGt(timeRemaining, 0, "Time until next execution should be greater than 0 at midpoint");
        assertLe(timeRemaining, 43200, "Time until next execution should be less than or equal to remaining duration");

        // Warp to just before the end of the buyback period
        vm.warp(block.timestamp + 43199); // 1 second before end

        timeRemaining = twammHook.getTimeUntilNextExecution(key);
        assertGt(timeRemaining, 0, "Time until next execution should be greater than 0 near end");
        assertLe(timeRemaining, 1, "Time until next execution should be 1 second or less");

        // Warp to after the buyback period
        vm.warp(block.timestamp + 2);

        timeRemaining = twammHook.getTimeUntilNextExecution(key);
        assertEq(timeRemaining, 0, "Time until next execution should be 0 after buyback ends");
    }

    function test_TWAMMHook_GetBuybackProgress() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 10 days;
        bool zeroForOne = true;

        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

    
        // Simulate a partial buyback (this is a simplified simulation)
        vm.warp(block.timestamp + 5 days);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 100 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(poolKey, params, testSettings, "");
        (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime,
            uint256 remainingTime,
            uint256 totalDuration,
            uint256 remainingAmount
        ) = twammHook.getBuybackOrderDetails(poolKey);

        //@audit - is this right? I'm not even sure anymore I've been testing this for too long

        uint256 partialAmount = buybackAmount / 2;   
        amountBought = partialAmount;

        uint256 progress = twammHook.getBuybackProgress(poolKey);
        assertEq(progress, partialAmount, "Progress should be 50% after half buyback");

        // Simulate completion
        amountBought = buybackAmount;

        progress = twammHook.getBuybackProgress(poolKey);
        assertEq(progress, 100, "Progress should be 100% after full buyback");
    }

    function test_TWAMMHook_GettersWithNoBuybackOrder() public {
        (
            address initiator,
            uint256 totalAmount,
            uint256 amountBought,
            uint256 startTime,
            uint256 endTime,
            uint256 lastExecutionTime,
            uint256 remainingTime,
            uint256 totalDuration,
            uint256 remainingAmount
        ) = twammHook.getBuybackOrderDetails(poolKey);

        assertEq(initiator, address(0), "Initiator should be zero address");
        assertEq(totalAmount, 0, "Total amount should be 0");
        assertEq(amountBought, 0, "Amount bought should be 0");
        assertEq(startTime, 0, "Start time should be 0");
        assertEq(endTime, 0, "End time should be 0");
        assertEq(lastExecutionTime, 0, "Last execution time should be 0");
        assertEq(remainingTime, 0, "Remaining time should be 0");
        assertEq(totalDuration, 0, "Total duration should be 0");
        assertEq(remainingAmount, 0, "Remaining amount should be 0");

        uint256 timeUntilNextExecution = twammHook.getTimeUntilNextExecution(poolKey);
        assertEq(timeUntilNextExecution, 0, "Time until next execution should be 0");

        uint256 progress = twammHook.getBuybackProgress(poolKey);
        assertEq(progress, 0, "Progress should be 0");
    }

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory key = PoolKey(_token0, _token1, 0, 60, hooks);
        return (key, key.toId());
    }
}
