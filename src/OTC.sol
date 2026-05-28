// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @title OTC
/// @notice A Uniswap v4 hook that lets users leave tick-triggered token sale orders.
/// @dev Orders are represented by ERC-1155 claim tokens. When a swap moves the pool
///      across an order tick, the hook swaps the escrowed input through the same pool
///      and records the received output for proportional redemption by claim holders.
contract OTC is BaseHook, ERC1155 {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Reserved for invalid order validation.
    error OTC__InvalidOrder();

    /// @notice Thrown when a user tries to redeem before an order has produced output.
    error OTC__NothingToClaim();

    /// @notice Thrown when a user tries to cancel or redeem more claim tokens than they own.
    error OTC__NotEnoughToClaim();

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Input tokens still waiting to be sold for each pool, tick, and direction.
    /// @dev `zeroForOne == true` means token0 is escrowed and will be sold for token1.
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;

    /// @notice Total ERC-1155 claim-token supply for each order id.
    /// @dev Used as the denominator when distributing filled output pro rata.
    mapping(uint256 orderId => uint256 claimsSupply) public claimTokensSupply;

    /// @notice Output tokens received from executed orders and not yet redeemed.
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;

    /// @notice Last observed pool tick after hook-managed order execution.
    /// @dev The hook compares this value with the current tick after each external swap
    ///      to know which tick range was crossed.
    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // -------------------------------------------------------------------------
    // User actions
    // -------------------------------------------------------------------------

    /// @notice Places a limit-style order that executes when the pool crosses a usable tick.
    /// @dev The requested tick is rounded down to the nearest usable tick for the pool's
    ///      spacing. The caller receives ERC-1155 claim tokens equal to the escrowed input.
    /// @param _key Pool on which the order should execute.
    /// @param _tickToSellAt Requested trigger tick. It is normalized to a usable tick.
    /// @param _zeroForOne True to sell token0 for token1, false to sell token1 for token0.
    /// @param _inputAmount Amount of input token to escrow for the order.
    /// @return tick The usable tick at which the order was recorded.
    function placeOrder(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _inputAmount)
        external
        returns (int24 tick)
    {
        tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        pendingOrders[_key.toId()][tick][_zeroForOne] += _inputAmount;

        uint256 orderId = getOrderId(_key, tick, _zeroForOne);
        claimTokensSupply[orderId] += _inputAmount;
        _mint(msg.sender, orderId, _inputAmount, "");

        address sellToken = _zeroForOne ? Currency.unwrap(_key.currency0) : Currency.unwrap(_key.currency1);
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), _inputAmount);
    }

    /// @notice Cancels an unfilled order position and returns the original input token.
    /// @dev Only pending input can be cancelled. Once an order has executed, the user must
    ///      redeem output tokens instead.
    /// @param _key Pool used to derive the order id.
    /// @param _tickToSellAt Requested or normalized tick for the order.
    /// @param _zeroForOne Original order direction.
    /// @param _amountToCancel Amount of claim tokens/input to cancel.
    function cancelOrder(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _amountToCancel)
        external
    {
        int24 tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        uint256 orderId = getOrderId(_key, tick, _zeroForOne);

        uint256 positionTokens = balanceOf(msg.sender, orderId);
        if (positionTokens < _amountToCancel) revert OTC__NotEnoughToClaim();

        pendingOrders[_key.toId()][tick][_zeroForOne] -= _amountToCancel;
        claimTokensSupply[orderId] -= _amountToCancel;
        _burn(msg.sender, orderId, _amountToCancel);

        Currency token = _zeroForOne ? _key.currency0 : _key.currency1;
        token.transfer(msg.sender, _amountToCancel);
    }

    /// @notice Burns claim tokens and transfers the caller's pro-rata filled output.
    /// @dev A single order id can contain liquidity from many users. Output is distributed
    ///      by the caller's claim amount divided by the current total claim-token supply.
    /// @param _key Pool used to derive the order id.
    /// @param _tickToSellAt Requested or normalized tick for the order.
    /// @param _zeroForOne Original order direction.
    /// @param _inputAmountToClaimFor Claim-token amount to redeem.
    function redeem(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _inputAmountToClaimFor)
        external
    {
        int24 tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        uint256 orderId = getOrderId(_key, tick, _zeroForOne);

        if (claimableOutputTokens[orderId] == 0) revert OTC__NothingToClaim();

        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < _inputAmountToClaimFor) revert OTC__NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];
        uint256 outputAmount = _inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= _inputAmountToClaimFor;
        _burn(msg.sender, orderId, _inputAmountToClaimFor);

        Currency token = _zeroForOne ? _key.currency1 : _key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    // -------------------------------------------------------------------------
    // Hook configuration and callbacks
    // -------------------------------------------------------------------------

    /// @notice Declares that this hook tracks pool initialization and reacts after swaps.
    /// @dev `afterInitialize` seeds `lastTicks`; `afterSwap` checks crossed ticks and fills
    ///      any matching orders.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Records the pool's initial tick so later swaps can detect crossed ranges.
    function _afterInitialize(address, PoolKey calldata _key, uint160, int24 _tick) internal override returns (bytes4) {
        lastTicks[_key.toId()] = _tick;
        return this.afterInitialize.selector;
    }

    /// @dev Executes any orders whose trigger ticks were crossed by the user's swap.
    ///      Hook-initiated swaps return early to avoid recursive order execution.
    function _afterSwap(
        address _sender,
        PoolKey calldata _key,
        SwapParams calldata _params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (_sender == address(this)) return (this.afterSwap.selector, 0);

        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            (tryMore, currentTick) = _tryExecutingOrders(_key, !_params.zeroForOne);
        }

        lastTicks[_key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Computes the ERC-1155 token id for a pool, usable tick, and direction.
    /// @dev Callers should pass the normalized usable tick returned by `placeOrder`.
    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    // -------------------------------------------------------------------------
    // Order execution
    // -------------------------------------------------------------------------

    /// @dev Swaps all pending input for one order and makes the output redeemable.
    function executeOrder(PoolKey calldata _key, int24 _tick, bool _zeroForOne, uint256 _inputAmount) internal {
        BalanceDelta delta = _swapAndSettleBalances(
            _key,
            SwapParams({
                zeroForOne: _zeroForOne,
                amountSpecified: -int256(_inputAmount),
                sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        pendingOrders[_key.toId()][_tick][_zeroForOne] -= _inputAmount;

        uint256 orderId = getOrderId(_key, _tick, _zeroForOne);
        uint256 outputAmount = _zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        claimableOutputTokens[orderId] += outputAmount;
    }

    /// @dev Searches the crossed tick range for a matching order and executes at most one.
    ///      Returning after one fill lets the caller re-read the pool tick, because the
    ///      hook's own swap may move price back across earlier ticks.
    function _tryExecutingOrders(PoolKey calldata _key, bool _executeZeroForOne)
        internal
        returns (bool tryMore, int24 newTick)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(_key.toId());
        int24 lastTick = lastTicks[_key.toId()];

        if (currentTick > lastTick) {
            for (
                int24 tick = _getLowerUsableTick(lastTick, _key.tickSpacing);
                tick < currentTick;
                tick += _key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[_key.toId()][tick][_executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(_key, tick, _executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        } else {
            for (
                int24 tick = _getLowerUsableTick(lastTick, _key.tickSpacing);
                tick > currentTick;
                tick -= _key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[_key.toId()][tick][_executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(_key, tick, _executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        return (false, currentTick);
    }

    // -------------------------------------------------------------------------
    // PoolManager accounting
    // -------------------------------------------------------------------------

    /// @dev Performs a PoolManager swap as this hook, then settles owed input and takes output.
    function _swapAndSettleBalances(PoolKey calldata _key, SwapParams memory _params) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(_key, _params, "");

        if (_params.zeroForOne) {
            if (delta.amount0() < 0) _settle(_key.currency0, uint128(-delta.amount0()));
            if (delta.amount1() > 0) _take(_key.currency1, uint128(delta.amount1()));
        } else {
            if (delta.amount1() < 0) _settle(_key.currency1, uint128(-delta.amount1()));
            if (delta.amount0() > 0) _take(_key.currency0, uint128(delta.amount0()));
        }

        return delta;
    }

    /// @dev Pays tokens owed by this hook into the PoolManager.
    function _settle(Currency currency, uint128 _amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), _amount);
        poolManager.settle();
    }

    /// @dev Withdraws tokens owed to this hook from the PoolManager.
    function _take(Currency currency, uint128 _amount) internal {
        poolManager.take(currency, address(this), _amount);
    }

    // -------------------------------------------------------------------------
    // Tick helpers
    // -------------------------------------------------------------------------

    /// @dev Rounds toward negative infinity to the nearest usable tick.
    ///      Solidity integer division truncates toward zero, so negative ticks need
    ///      an extra decrement when they are not exact multiples of the tick spacing.
    function _getLowerUsableTick(int24 _tick, int24 _tickSpacing) private pure returns (int24) {
        int24 intervals = _tick / _tickSpacing;
        if (_tick < 0 && _tick % _tickSpacing != 0) intervals--;
        return intervals * _tickSpacing;
    }
}
