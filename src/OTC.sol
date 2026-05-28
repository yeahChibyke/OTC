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

contract OTC is BaseHook, ERC1155 {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    // Errors
    error OTC__InvalidOrder();
    error OTC__NothingToClaim();
    error OTC__NotEnoughToClaim();

    // State Variables
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;
    mapping(uint256 orderId => uint256 claimsSupply) public claimTokensSupply;
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;

    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // ========== EXTERNAL FUNCTIONS ==========

    function placeOrder(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _inputAmount)
        external
        returns (int24)
    {
        // Get lower actually usable tick given `tickToSellAt`
        int24 _tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        // Create a pending order
        pendingOrders[_key.toId()][_tick][_zeroForOne] += _inputAmount;

        // Mint claim tokens to user equal to their `_inputAmount`
        uint256 _orderId = getOrderId(_key, _tick, _zeroForOne);
        claimTokensSupply[_orderId] += _inputAmount;
        _mint(msg.sender, _orderId, _inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = _zeroForOne ? Currency.unwrap(_key.currency0) : Currency.unwrap(_key.currency1);
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), _inputAmount);

        // Return the tick at which the order was actually placed
        return _tick;
    }

    function cancelOrder(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _amountToCancel)
        external
    {
        // Get lower actually usable tick for their order
        int24 _tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        uint256 _orderId = getOrderId(_key, _tick, _zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 _positionTokens = balanceOf(msg.sender, _orderId);
        if (_positionTokens < _amountToCancel) revert OTC__NotEnoughToClaim();

        // Remove their `_amountToCancel` worth of position from pending orders
        pendingOrders[_key.toId()][_tick][_zeroForOne] -= _amountToCancel;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[_orderId] -= _amountToCancel;
        _burn(msg.sender, _orderId, _amountToCancel);

        // Send them their input token
        Currency token = _zeroForOne ? _key.currency0 : _key.currency1;
        token.transfer(msg.sender, _amountToCancel);
    }

    function redeem(PoolKey calldata _key, int24 _tickToSellAt, bool _zeroForOne, uint256 _inputAmountToClaimFor)
        external
    {
        // Get lower actually usable tick for their order
        int24 _tick = _getLowerUsableTick(_tickToSellAt, _key.tickSpacing);
        uint256 _orderId = getOrderId(_key, _tick, _zeroForOne);

        // if no output tokens can be claimed yet it means order has not been filled yet
        if (claimableOutputTokens[_orderId] == 0) revert OTC__NothingToClaim();

        // must have claim tokens => _inputAmountToClaimFor
        uint256 _claimTokens = balanceOf(msg.sender, _orderId);
        if (_claimTokens < _inputAmountToClaimFor) revert OTC__NotEnoughToClaim();

        uint256 _totalClaimableForPosition = claimableOutputTokens[_orderId];
        uint256 _totalInputAmountForPosition = claimTokensSupply[_orderId];

        // _outputAmount = (_inputAmountToClaimFor * _totalClaimableForPosition) / (_totalInputAmountForPosition)
        uint256 _outputAmount =
            _inputAmountToClaimFor.mulDivDown(_totalClaimableForPosition, _totalInputAmountForPosition);

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[_orderId] -= _outputAmount;
        claimTokensSupply[_orderId] -= _inputAmountToClaimFor;
        _burn(msg.sender, _orderId, _inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = _zeroForOne ? _key.currency1 : _key.currency0;
        token.transfer(msg.sender, _outputAmount);
    }

    // ========== PUBLIC FUNCTIONS ==========

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

    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    // ========== INTERNAL FUNCTIONS ==========

    function executeOrder(PoolKey calldata _key, int24 _tick, bool _zeroForOne, uint256 _inputAmount) internal {
        // Do the actual swap and settle all balances
        BalanceDelta _delta = _swapAndSettleBalances(
            _key,
            SwapParams({
                zeroForOne: _zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(_inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // `inputAmount` has been deducted from this position
        pendingOrders[_key.toId()][_tick][_zeroForOne] -= _inputAmount;
        uint256 _orderId = getOrderId(_key, _tick, _zeroForOne);
        uint256 _outputAmount = _zeroForOne ? uint256(int256(_delta.amount1())) : uint256(int256(_delta.amount0()));

        // `_outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[_orderId] += _outputAmount;
    }

    function _swapAndSettleBalances(PoolKey calldata _key, SwapParams memory _params) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta _delta = poolManager.swap(_key, _params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (_params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (_delta.amount0() < 0) {
                _settle(_key.currency0, uint128(-_delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (_delta.amount1() > 0) {
                _take(_key.currency1, uint128(_delta.amount1()));
            }
        } else {
            if (_delta.amount1() < 0) {
                _settle(_key.currency1, uint128(-_delta.amount1()));
            }

            if (_delta.amount0() > 0) {
                _take(_key.currency0, uint128(_delta.amount0()));
            }
        }

        return _delta;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // TODO
        return this.afterInitialize.selector;
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // TODO
        return (this.afterSwap.selector, 0);
    }

    function _settle(Currency currency, uint128 _amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), _amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 _amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), _amount);
    }

    // ========== PRIVATE FUNCTIONS ==========

    function _getLowerUsableTick(int24 _tick, int24 _tickSpacing) private pure returns (int24) {
        // _intervals = -100/60 = -1 (integer division)
        int24 _intervals = _tick / _tickSpacing;

        // since tick < 0, we round `_intervals` down to -2
        // if tick > 0, `_intervals` is fine as it is
        if (_tick < 0 && _tick % _tickSpacing != 0) _intervals--; // round towards negative infinity

        // actual usable tick, then, is _intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return _intervals * _tickSpacing;
    }
}
