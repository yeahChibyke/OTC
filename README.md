# OTC Hook

`OTC` is a Uniswap v4 hook for tick-triggered token sale orders. Users escrow
one side of a pool, receive ERC-1155 claim tokens for their position, and can
redeem the output token after the hook executes the order.

The hook is written as an educational/prototype implementation. It demonstrates
how to combine v4 swap callbacks, PoolManager accounting, and ERC-1155 position
tokens, but it does not include production controls such as slippage limits,
keepers, fees, or input validation.

## How It Works

An order is identified by:

- the pool id
- the normalized usable tick
- the swap direction

`zeroForOne == true` means the user escrows token0 and the hook later sells it
for token1. `zeroForOne == false` means the user escrows token1 and later sells
it for token0.

When a user places an order, the requested tick is rounded down to the nearest
usable tick for the pool's tick spacing. The hook stores the pending input amount
and mints ERC-1155 claim tokens equal to the user's input amount.

After each external swap, the hook compares the pool's current tick with the last
tick it recorded. If the swap crossed a tick that has pending orders in the
opposite direction, the hook executes the pending input as an exact-input swap
through the same pool. The received output is stored as claimable balance for
the order id.

Users redeem by burning their ERC-1155 claim tokens. Output is distributed pro
rata against the current claim-token supply for that order id.

## Contract Layout

- `placeOrder`: escrow input tokens and mint ERC-1155 claim tokens.
- `cancelOrder`: burn claim tokens and return unfilled input.
- `redeem`: burn claim tokens and transfer filled output.
- `getHookPermissions`: enables `afterInitialize` and `afterSwap`.
- `_afterInitialize`: records the starting tick for a pool.
- `_afterSwap`: checks crossed ticks and triggers order execution.
- `_tryExecutingOrders`: searches crossed usable ticks and executes one order at
  a time so price can be re-read after each hook swap.
- `_swapAndSettleBalances`: performs hook-owned swaps and settles/takes tokens
  with the v4 PoolManager.

## Development

Install dependencies and run the Foundry tests:

```bash
forge install
forge test
```

The current test suite covers:

- order placement and ERC-1155 claim minting
- cancellation of unfilled orders
- execution when price moves up through a zeroForOne order
- execution when price moves down through a oneForZero order
- multi-order execution where one order remains pending
- multi-order execution where both orders fill

## Known Limitations

- Hook-triggered swaps use the broadest sqrt price limits and have no user
  slippage protection.
- Orders execute only in `afterSwap`; there is no separate keeper function.
- The implementation assumes ERC-20 pool currencies in the tested path.

