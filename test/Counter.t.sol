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

contract TWAMMHookTest is Test, GasSnapshot, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TWAMMHook twammHook;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

          // Deploy hook to an address that has the proper flags set
     // Deploy hook to an address that has the proper flags set
    uint160 flags = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
        Hooks.AFTER_ADD_LIQUIDITY_FLAG | 
        Hooks.BEFORE_SWAP_FLAG | 
        Hooks.AFTER_SWAP_FLAG
    );
    deployCodeTo(
        "TWAMMHook.sol",
        abi.encode(IPoolManager(address(manager)), address(token0), address(this), 7000 days),
        address(flags)
    );

    // Set the twammHook to the deployed address
    twammHook = TWAMMHook(address(flags));
    (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(twammHook);

    poolKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(twammHook)));
    manager.initialize(initKey, SQRT_PRICE_1_1 + 1, ZERO_BYTES);

        token0.approve(address(twammHook), type(uint256).max);
        token1.approve(address(twammHook), type(uint256).max);
    }

    function test_TWAMMHook_InitiateBuyback() public {
        PoolId poolId = poolKey.toId();
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;
         

        token0.mint(address(this), buybackAmount);
      
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

    function test_TWAMMHook_ClaimBoughtTokens() public {
        uint256 buybackAmount = 1000e18;
        uint256 duration = 1 days;

        token0.mint(address(this), buybackAmount);
        twammHook.initiateBuyback(poolKey, buybackAmount, duration);

        // Simulate some tokens being bought
        uint256 boughtAmount = 500e18;
        token1.mint(address(twammHook), boughtAmount);
    

        uint256 balanceBefore = token1.balanceOf(address(this));
        twammHook.claimBoughtTokens(poolKey);
        uint256 balanceAfter = token1.balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, boughtAmount);
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
