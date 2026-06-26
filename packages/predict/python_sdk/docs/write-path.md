# Write Path

The write path turns user intent into Sui programmable transactions for Predict
account custody and range trading. It is intentionally dry-run-first and hides the
protocol plumbing from callers.

## Entry Points

- CLI: `predict-sdk account`, `deposit`, `withdraw`, `trade`, `redeem`, `bot`.
- Python: `PredictActions.from_env()` or `PredictActions(load_signer(), ...)`.
- Submission flag: all CLI write commands dry-run unless `--execute` is passed.

## Key Files

- `signer.py`: loads `SUI_PRIVATE_KEY`, derives address, signs Sui intent digest.
- `actions.py`: high-level account, custody, mint, and redeem methods.
- `bcs.py`: narrow BCS encoder and PTB command/input builder.
- `tx.py`: object ref resolution, dry run, gas estimate, signing, execution.
- `gas.py`: distinct gas coin pool for concurrent writes.

## Account And Custody

Predict uses a shared account wrapper for custody:

1. `ensure_account()` checks `.predict_state.json` for the signer's wrapper ID.
2. If missing, it calls `account_registry::new`, then `account::share`.
3. After successful execution, it records the created `AccountWrapper` ID locally.

`custody_balance()` reads the wrapper's `balances` bag and returns the raw DUSDC
balance held in account custody. This is separate from wallet-held DUSDC returned by
`suix_getAllBalances`.

Deposits and withdrawals use the account package's `Auth` hot potato:

- `deposit(amount)` picks the largest wallet DUSDC coin, splits the requested amount,
  generates `Auth`, and calls `account::deposit_funds`.
- `withdraw(amount)` generates `Auth`, calls `account::withdraw_funds`, and transfers
  the returned coin back to the signer.

All money amounts passed to `PredictActions` are raw 6-decimal DUSDC integers. The CLI
converts human DUSDC floats into raw integers.

## Mint Flow

`PredictActions.mint()` builds one PTB that prices and mints in the same transaction:

1. Borrow the mutable `ExpiryMarket`.
2. Call `expiry_market::load_live_pricer` with protocol config, Propbook registry,
   Pyth feed, Block-Scholes spot feed, forward feed, SVI feed, and clock.
3. Generate account `Auth`.
4. Call `expiry_market::mint_exact_quantity`.
5. Include `AccumulatorRoot` and `Clock` in the call.

The SDK does not calculate the price off-chain. A dry-run mint returns the authoritative
`OrderMinted` event containing entry probability and premium.

## Redeem Flow

- `redeem_live()` mirrors mint by loading the live pricer and calling
  `expiry_market::redeem_live`.
- `redeem_settled()` calls `expiry_market::redeem_settled` and includes the account
  registry, oracle registry, Pyth feed, accumulator root, and clock.

## Transaction Execution

`TransactionClient.run()` is the only normal execution path:

1. Resolve the reference gas price.
2. Pick or accept a SUI gas coin.
3. Build BCS `TransactionData` with a probe gas budget.
4. Call `sui_dryRunTransactionBlock`.
5. Return a dry-run `TxResult` if `execute=False`.
6. If `execute=True`, rebuild with estimated gas plus buffer, sign, and call
   `sui_executeTransactionBlock` with `WaitForLocalExecution`.

Dry-run failures return `TxResult(success=False)` instead of submitting.

## Gas And Concurrency

Sui transactions must not concurrently share the same owned gas coin. Shared Predict
objects can be touched concurrently because consensus orders them, but the gas coin is
an owned object.

Use `GasPool` for parallel writes:

```python
from predict_sdk.gas import GasPool

pool = GasPool(actions.client)
pool.split(4, 120_000_000)
pool.parallel([
    lambda coin: actions.mint(..., gas_coin=coin),
    lambda coin: actions.mint(..., gas_coin=coin),
])
```

After a transaction, update the coin version/digest from object changes before reuse.
`GasPool.parallel()` releases coins automatically, but the task must use the provided
coin.

## Testing Rules

- Unit tests should stub RPC/action clients rather than requiring funded testnet
  accounts.
- Validate BCS primitives and signer behavior with deterministic local keys.
- Keep dry-run default behavior covered in CLI/action tests.
- Do not make tests depend on real `SUI_PRIVATE_KEY`.
