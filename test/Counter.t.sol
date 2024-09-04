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
        uint256 duration = 8 days; // Exceeds the 7 days max duration

        token0.mint(address(this), buybackAmount);
        vm.expectRevert(TWAMMHook.DurationExceedsMaximum.selector);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);
    }

    function test_TWAMMHook_InitiateBuybckRevert_ExistingBuybackInProgress() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        token0.mint(address(this), buybackAmount * 2);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        vm.expectRevert(TWAMMHook.ExistingBuybackInProgress.selector);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);
    }

    function test_TWAMMHook_ClaimBoughtTokensOnly() public {
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

    function test_TWAMMHook_ClaimBoughtTokens_Revert_OnlyInitiatorCanClaim() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        token0.mint(address(this), buybackAmount);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        vm.prank(address(0xdead));
        vm.expectRevert(TWAMMHook.OnlyInitiatorCanClaim.selector);
        twammHook.claimBoughtTokens(poolKey);
    }

    function test_TWAMMHook_ClaimBoughtTokens_Revert_NoTokensToClaim() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        token0.mint(address(this), buybackAmount);
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

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory key = PoolKey(_token0, _token1, 0, 60, hooks);
        return (key, key.toId());
    }
}
