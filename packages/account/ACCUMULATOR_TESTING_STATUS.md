# Account Accumulator Testing Status

This note captures the current state of the Account package around Sui
accumulator support, the temporary dependency choice, and the flows we still
cannot prove with package-local Move unit tests.

## Current State

`account` is wired to the Sui address-balance accumulator:

- `Account.receive_address()` returns the canonical inner account address.
- `Account.balance<T>(root, clock)` returns stored balance plus unsettled funds
  visible in `AccumulatorRoot`.
- `Account.deposit<T>(coin, root, clock)` and `Account.withdraw<T>(amount, root,
  clock, ctx)` passively call `settle_unchecked<T>` before changing stored
  balances.
- `settle_unchecked<T>` reads `balance::settled_funds_value<T>(root,
  account_id.to_address())`, withdraws from the account object's address
  balance, redeems the withdrawal, and deposits into the account's stored
  balance.
- The last settlement timestamp is tracked per coin type with `CoinKey<T>` in a
  `Bag`. If a second transaction reaches settlement for the same coin at the
  same `Clock.timestamp_ms()`, Account skips the accumulator withdrawal attempt.

Predict currently relies on two address-balance paths:

- Account receives PLP / DUSDC / DEEP through `Account.receive_address()`.
- Builder-code fees are sent to the `BuilderCode` object address and claimed with
  `builder_code::claim_all_builder_fees`.

## Temporary Sui Dependency

The current stable/testnet framework lock used by this repo does not expose
`sui::accumulator::create_for_testing`. That means package-local tests cannot
even construct an `AccumulatorRoot`.

To make Account tests compile today, `packages/account/Move.toml` explicitly pins
Sui to a nightly main commit:

```toml
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "2e196df64878a6ee6786cf739474e8bf4a85f726" }
```

This is a temporary development dependency. Before mainnet, once the needed
accumulator test support is available in a stable Sui release, we should:

1. Move Account back to the repo's stable Sui dependency model.
2. Regenerate Account and downstream package lockfiles from that stable release.
3. Avoid mixed framework revisions in downstream packages such as Predict.
4. Re-run Account tests and the relevant Predict build/test suites.
5. Update stale Predict test comments that still describe `AccumulatorRoot` as
   impossible to construct in Move tests.

## What Is Tested Now

`packages/account/tests/account_tests.move` currently covers:

- one canonical account per owner;
- canonical account ID, wrapper ID, owner, and receive-address derivation;
- duplicate account creation aborts;
- owner auth from `TxContext.sender()`;
- wrong-sender auth aborts;
- self-owned account auth from mutable owner `UID`;
- app whitelist authorization and deauthorization errors;
- whitelisted app auth using `Permit<App>`;
- app data attach, read, mutable read, detach, and namespace separation;
- direct Account coin deposit / withdraw with `AccumulatorRoot` and `Clock`
  threaded through the public APIs;
- insufficient stored balance aborts.

The tests verify that Account's public coin APIs are shaped correctly around
`AccumulatorRoot`, but they do not verify nonzero accumulator settlement.

## Flows Not Tested Yet

The missing coverage is specifically the nonzero address-balance path:

- `balance::send_funds<T>(..., account.receive_address())` becoming visible in
  `balance::settled_funds_value<T>(&root, account.receive_address())`.
- `Account.balance<T>` adding a nonzero unsettled accumulator amount to stored
  balance.
- `Account.deposit<T>` / `Account.withdraw<T>` settling a nonzero accumulator
  amount into stored balance before applying the requested operation.
- `balance::withdraw_funds_from_object<T>(&mut account_id, amount)` succeeding
  against real accumulator-delivered funds.
- The same-timestamp guard preventing duplicate settlement attempts when two
  parallel transactions see the same checkpoint-settled funds.
- PLP async fills and refunds that send DUSDC / PLP to `Account.receive_address`
  and depend on a later Account read/write to observe or settle those funds.
- Builder-code fee visibility and claims after Predict sends builder fees to a
  builder-code object address.

The blocker is not Account source structure. We can create `AccumulatorRoot` with
the nightly framework, but external package tests cannot populate it the same way
the system settlement barrier does. The relevant settlement functions live in
`sui::accumulator_settlement`, are not public to Account, and are system-gated.
Advancing a unit-test scenario through `@0x0` after `balance::send_funds` did not
make `settled_funds_value` observe the sent funds.

## How To Close The Gap

Before mainnet, we need one of these:

- stable Sui framework support that exposes an official test path for settling
  accumulator funds into `AccumulatorRoot`; or
- an integration/localnet test that exercises real checkpoint settlement rather
  than Move unit-test-only state.

Once that exists, add focused tests for Account's nonzero settlement behavior
first, then cover the Predict surfaces that depend on it: PLP fill/refund delivery
to Account and builder-code fee claiming.
