// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TWAMMHook} from "../src/TWAMMHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {MockUSDC} from "../script/mocks/mUSDC.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";



contract DeployTWAMM is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    PoolKey key;
    TWAMMHook twammHook;
    function setUp() public {}

    function run() public {

        vm.startBroadcast();

        // Deploy PoolManager
        PoolManager manager = new PoolManager(500000);

        // Deploy MockUSDC as daoToken
        MockUSDC daoToken = new MockUSDC();

        // Use the deployer's address as daoTreasury
        address daoTreasury = msg.sender;

        // Set maxBuybackDuration to 100 hours in seconds
        uint256 maxBuybackDuration = 100 * 3600; // 100 hours in seconds

        // Define hook permissions
        uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG);


        // Mine hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(TWAMMHook).creationCode,
            abi.encode(address(manager), address(daoToken), daoTreasury, maxBuybackDuration, msg.sender)
        );

        // Deploy the hook
        TWAMMHook twammHook = new TWAMMHook{salt: salt}(
            IPoolManager(address(manager)),
            address(daoToken),
            daoTreasury,
            maxBuybackDuration
        );
        twammHook = twammHook;
        console.log("twammHook", address(twammHook));
        require(address(twammHook) == hookAddress, "DeployTWAMM: hook address mismatch");

   
        (PoolModifyLiquidityTest lpRouter, PoolSwapTest swapRouter,) = deployRouters(manager);
  

        // test the lifecycle (create pool, add liquidity, swap)
     
        testLifecycle(manager, address(twammHook), lpRouter, swapRouter);


        MockERC20(Currency.unwrap(key.currency0)).approve(address(twammHook), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(twammHook), type(uint256).max);
        


        //twammHook.initiateBuyback(key, 1000 ether, 1000, 10, false);

        (address initiator,,,,,,,,uint256 remainingAmount,) = twammHook.getBuybackOrderDetails(key);
        vm.stopBroadcast();
    }



    /// HELPER FUNCTION 

    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(500000)));
    }

    function deployRouters(IPoolManager manager)
        internal
        returns (PoolModifyLiquidityTest lpRouter, PoolSwapTest swapRouter, PoolDonateTest donateRouter)
    {
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);
    }

    function deployTokens() internal returns (MockERC20 token0, MockERC20 token1) {
        MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        console.log("tokenA", address(tokenA));
        console.log("tokenB", address(tokenB));
 

        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

     function testLifecycle(
        IPoolManager manager,
        address hook,
        PoolModifyLiquidityTest lpRouter,
        PoolSwapTest swapRouter
    ) internal {
        (MockERC20 token0, MockERC20 token1) = deployTokens();
        token0.mint(address(0x1B382A7b4496F14e0AAA2DA1E1626Da400426A03), 100_0000000 ether);
        token1.mint(address(0x1B382A7b4496F14e0AAA2DA1E1626Da400426A03), 100_00000000 ether);
        token0.mint(address(twammHook), 100_000 ether);
        token1.mint(address(twammHook), 100_000 ether);

        bytes memory ZERO_BYTES = new bytes(0);

        // initialize the pool
        int24 tickSpacing = 60;
        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, tickSpacing, IHooks(hook));
        //set pool key to global variable
        key = poolKey;
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1, ZERO_BYTES);

        // approve the tokens to the routers
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        // add full range liquidity to the pool
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing), 1000 ether, 0
            ),
            ZERO_BYTES
        );

        // swap some tokens
        bool zeroForOne = true;
        int256 amountSpecified = 1 ether;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
    }
}
