# Account Accumulator Testing Status

This note captures the current state of Account/Predict unit coverage around Sui
address-balance accumulators.

## Current State

`account` is wired to the Sui address-balance accumulator:

- `Account.receive_address()` returns the canonical wrapper receive address.
- `Account.balance<T>(root, clock)` returns stored balance plus unsettled funds
  visible in `AccumulatorRoot`.
- `Account.settle<T>(wrapper, root, clock)` reads
  `balance::settled_funds_value<T>(root, wrapper.id.to_address())`, withdraws
  from the wrapper object's address balance, redeems the withdrawal, and deposits
  into the account's stored balance.
- `Account.deposit<T>(coin)` and `Account.withdraw<T>(amount, ctx)` operate only
  on stored balance; callers settle accumulator funds at the flow boundary first.
- The last settlement timestamp is tracked per coin type with `CoinKey<T>` in a
  `Bag`. If a second transaction reaches settlement for the same coin at the
  same `Clock.timestamp_ms()`, Account skips the accumulator withdrawal attempt.

Predict relies on the same receive-address pattern for PLP, DUSDC, DEEP, and
builder-code fees.

## Current Dependency Choice

The repo's current Sui framework lock exposes
`sui::accumulator::create_for_testing`, so package-local tests can construct a
shared empty `AccumulatorRoot` without nightly overrides or disabled files.

This branch uses that constructor through the shared helpers:

- `packages/account/tests/accumulator_support.move`
- `packages/predict/tests/helper/accumulator_support.move`

The constructor is still only an empty-root test seam. It does not let a package
unit test populate the system settlement barrier with nonzero address-balance
funds.

## What Is Tested Now

Account unit tests cover:

- one canonical account per owner;
- canonical account ID, wrapper ID, owner, and receive-address derivation;
- duplicate account creation aborts;
- owner auth from `TxContext.sender()` and wrong-sender aborts;
- self-owned account auth from mutable owner `UID`;
- app whitelist authorization and deauthorization errors;
- whitelisted app auth using `Permit<App>`;
- app data attach, read, mutable read, detach, and namespace separation;
- stored-balance coin deposit, withdraw, balance, and over-withdraw aborts using
  an empty `AccumulatorRoot`.

Predict unit tests now include the restored empty-root flow suite: mint/redeem
guards, backing/cash sheets, lifecycle, liquidation, pool valuation, passive
settlement, protocol-profit deferral, and strike-exposure boundary coverage.

## Remaining Gap

The remaining gap is specifically the nonzero address-balance settlement path,
which an empty root cannot exercise:

- `balance::send_funds<T>(..., account.receive_address())` becoming visible in
  `balance::settled_funds_value<T>(&root, account.receive_address())`.
- `Account.balance<T>` adding a nonzero unsettled accumulator amount to stored
  balance.
- `Account.settle<T>` moving nonzero accumulator funds into stored balance.
- `balance::withdraw_funds_from_object<T>(&mut account_id, amount)` succeeding
  against real accumulator-delivered funds.
- The same-timestamp guard preventing duplicate settlement attempts when two
  parallel transactions see the same checkpoint-settled funds.
- PLP async fills/refunds that send DUSDC or PLP to `Account.receive_address`
  and depend on a later Account read/write to observe or settle those funds.
- Builder-code fee visibility and claims after Predict sends builder fees to a
  builder-code object address.

The blocker is not Account source structure. Unit tests can create only an empty
`AccumulatorRoot`; external package tests cannot populate it the same way the
system settlement barrier does. The relevant settlement functions live in
`sui::accumulator_settlement`, are not public to Account/Predict, and are
system-gated. Advancing a unit-test scenario through `@0x0` after
`balance::send_funds` does not make `settled_funds_value` observe the sent funds.

## How To Close The Gap

Before mainnet, we need one of these:

- stable Sui framework support that exposes an official test path for settling
  accumulator funds into `AccumulatorRoot`; or
- an integration/localnet test that exercises real checkpoint settlement rather
  than Move unit-test-only state.

Once that exists, add focused tests for Account's nonzero settlement behavior
first, then cover the Predict surfaces that depend on it: PLP fill/refund
delivery to Account and builder-code fee claiming.

## Events

`account::account_events` emits the account-domain events: lifecycle
(`AccountCreated`, `AppAuthorized`, `AppDeauthorized`) and custody (`Deposited`,
`Withdrawn`, `FundsSettled`). Empty-root tests can cover lifecycle and stored
balance custody paths. Nonzero `FundsSettled` emission remains in the deferred
coverage gap above because it needs barrier-delivered funds.
