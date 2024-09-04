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

contract TWAMMHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct BuybackOrder {
        address initiator;
        uint256 totalAmount;
        uint256 amountBought;
        uint256 startTime;
        uint256 endTime;
        uint256 lastExecutionTime;
    }

    mapping(PoolId => BuybackOrder) public buybackOrders;
    mapping(PoolId => uint256) public buybackAmounts;
    mapping(PoolId => uint256) public claimTokensSupply;
    address public immutable daoToken;
    address public daoTreasury;
    uint256 public maxBuybackDuration;

    error DurationExceedsMaximum();
    error ExistingBuybackInProgress();
    error OnlyInitiatorCanClaim();
    error NoTokensToClaim();
    error UnauthorizedCaller();

    constructor(IPoolManager _poolManager, address _daoToken, address _daoTreasury, uint256 _maxBuybackDuration)
        BaseHook(_poolManager)
        Ownable(msg.sender)
    {
        daoToken = _daoToken;
        daoTreasury = _daoTreasury;
        maxBuybackDuration = _maxBuybackDuration;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    function initiateBuyback(PoolKey calldata key, uint256 totalAmount, uint256 duration)
        external
        returns (PoolKey memory)
    {
        if (duration > maxBuybackDuration) revert DurationExceedsMaximum();
        PoolId poolId = key.toId();
        if (buybackOrders[poolId].totalAmount != 0) revert ExistingBuybackInProgress();

        buybackOrders[poolId] = BuybackOrder({
            initiator: msg.sender,
            totalAmount: totalAmount,
            amountBought: 0,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            lastExecutionTime: block.timestamp
        });
        buybackAmounts[poolId] = totalAmount;

        ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), totalAmount);

        return key;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (order.totalAmount > 0) {
            uint256 elapsedTime = block.timestamp - order.lastExecutionTime;
            uint256 totalDuration = order.endTime - order.startTime;
            uint256 amountToBuy = (order.totalAmount * elapsedTime) / totalDuration;

            if (amountToBuy > 0) {
                // Execute partial buyback
                // Note: This is a simplified version. You'll need to implement the actual swap logic here.
                order.amountBought += amountToBuy;
                order.lastExecutionTime = block.timestamp;

                // Return the amount to buy as a delta
                return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
    //     external
    //     override
    //     returns (bytes4, int128)
    // {
    //     return (BaseHook.afterSwap.selector, 0);
    // }

    function claimBoughtTokens(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        BuybackOrder storage order = buybackOrders[poolId];

        if (msg.sender != order.initiator) revert OnlyInitiatorCanClaim();
        if (order.amountBought == 0) revert NoTokensToClaim();

        uint256 amountToClaim = order.amountBought;
        order.amountBought = 0;

        ERC20(daoToken).transfer(order.initiator, amountToClaim);
    }

    function executeBuyback(PoolKey calldata key) external {
        //exeSwap
    }

    function setDaoTreasury(address _newTreasury) external onlyOwner {
        daoTreasury = _newTreasury;
    }

    function setMaxBuybackDuration(uint256 _newMaxDuration) external onlyOwner {
        maxBuybackDuration = _newMaxDuration;
    }
}
