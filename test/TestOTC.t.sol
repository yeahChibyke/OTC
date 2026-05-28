// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {OTC} from "../src/OTC.sol";

/// @notice Integration tests for the OTC hook against a real v4 PoolManager.
contract OTCTest is Test, Deployers, ERC1155Holder {
    using StateLibrary for IPoolManager;

    Currency token0;
    Currency token1;

    OTC hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();

        // Hook addresses encode their permission flags in the low bits.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("OTC.sol", abi.encode(manager, ""), hookAddress);
        hook = OTC(hookAddress);

        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Layered liquidity keeps the pool active around tick 0 and gives larger swaps
        // enough depth to cross multiple initialized tick ranges.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @notice Placing an order escrows input and mints claim tokens at the normalized tick.
    function test_placeOrder() public {
        int24 requestedTick = 100;
        int24 expectedUsableTick = 60;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();

        int24 tickLower = hook.placeOrder(key, requestedTick, zeroForOne, amount);

        assertEq(tickLower, expectedUsableTick);
        assertEq(originalBalance - token0.balanceOfSelf(), amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        assertTrue(orderId != 0);
        assertEq(hook.balanceOf(address(this), orderId), amount);
        assertEq(hook.pendingOrders(key.toId(), tickLower, zeroForOne), amount);
    }

    /// @notice Cancelling burns claim tokens and returns the still-unfilled input token.
    function test_cancelOrder() public {
        int24 requestedTick = 100;
        int24 expectedUsableTick = 60;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, requestedTick, zeroForOne, amount);

        assertEq(tickLower, expectedUsableTick);
        assertEq(originalBalance - token0.balanceOfSelf(), amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        assertEq(hook.balanceOf(address(this), orderId), amount);

        hook.cancelOrder(key, tickLower, zeroForOne, amount);

        assertEq(token0.balanceOfSelf(), originalBalance);
        assertEq(hook.balanceOf(address(this), orderId), 0);
        assertEq(hook.pendingOrders(key.toId(), tickLower, zeroForOne), 0);
    }

    /// @notice A token0-to-token1 order executes after the pool tick rises through its trigger.
    function test_orderExecute_zeroForOne() public {
        int24 requestedTick = 100;
        uint256 amount = 1 ether;
        bool zeroForOne = true;

        int24 tickLower = hook.placeOrder(key, requestedTick, zeroForOne, amount);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        swapRouter.swap(key, params, _testSettings(), ZERO_BYTES);

        assertEq(hook.pendingOrders(key.toId(), tickLower, zeroForOne), 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(orderId);
        assertEq(claimableOutputTokens, token1.balanceOf(address(hook)));

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, requestedTick, zeroForOne, amount);

        assertEq(token1.balanceOf(address(this)) - originalToken1Balance, claimableOutputTokens);
    }

    /// @notice A token1-to-token0 order executes after the pool tick falls through its trigger.
    function test_orderExecute_oneForZero() public {
        int24 requestedTick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        int24 tickLower = hook.placeOrder(key, requestedTick, zeroForOne, amount);

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        swapRouter.swap(key, params, _testSettings(), ZERO_BYTES);

        assertEq(hook.pendingOrders(key.toId(), tickLower, zeroForOne), 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(orderId);
        assertEq(claimableOutputTokens, token0.balanceOf(address(hook)));

        uint256 originalToken0Balance = token0.balanceOfSelf();
        hook.redeem(key, requestedTick, zeroForOne, amount);

        assertEq(token0.balanceOfSelf() - originalToken0Balance, claimableOutputTokens);
    }

    /// @notice If the hook's first fill moves price back enough, later crossed ticks remain pending.
    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, _testSettings(), ZERO_BYTES);

        assertEq(hook.pendingOrders(key.toId(), 0, true), 0);
        assertEq(hook.pendingOrders(key.toId(), 60, true), amount);
    }

    /// @notice A larger tick-moving swap can execute both pending zeroForOne orders.
    function test_multiple_orderExecute_zeroForOne_both() public {
        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, _testSettings(), ZERO_BYTES);

        assertEq(hook.pendingOrders(key.toId(), 0, true), 0);
        assertEq(hook.pendingOrders(key.toId(), 60, true), 0);
    }

    function _testSettings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}
