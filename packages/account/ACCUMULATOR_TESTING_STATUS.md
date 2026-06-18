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
`sui::accumulator::create_for_testing`. That `#[test_only]` shim — a wrapper around
the private genesis constructor — is the only path that builds an `AccumulatorRoot`,
and it ships only in a newer (nightly) framework. Without it, package-local tests
cannot construct an `AccumulatorRoot` at all.

### Account (old-style manifest)

`account` has an `[addresses]` block, so it is an old-style package and can pin the
framework directly. `packages/account/Move.toml` explicitly pins Sui to a nightly
main commit:

```toml
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "2e196df64878a6ee6786cf739474e8bf4a85f726" }
```

### Predict (new-style manifest) — `implicit-dependencies = false` + `override`

`predict` is a new-style package (no `[addresses]`, forced by its transitive
new-style `pyth_lazer`/`propbook` deps), so it cannot pin a system framework in
`[dependencies]` or `[dep-replacements]` ("`Sui` is a legacy system name"). It is
also not enough for `account` to carry the nightly framework: a dependency's
test-only code (and the framework `#[test_only]`s it calls) is stripped when the
dependency is built for a dependent, so Predict tests cannot reach
`create_for_testing` through `account`. Predict's OWN canonical framework must carry
the constructor. The mechanism that works:

```toml
[package]
implicit-dependencies = false

[dependencies]
sui = { git = "...sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "2e196df6...", override = true }
std = { git = "...sui.git", subdir = "crates/sui-framework/packages/move-stdlib",   rev = "2e196df6...", override = true }
```

This makes nightly the canonical `sui`/`std` that Predict (and `account`) bind to, so
Predict's root test code can call `accumulator::create_for_testing` directly. The
other in-repo deps (deepbook/propbook/dusdc/fixed_math/block_scholes_oracle) keep the
repo-standard testnet framework (`Sui_1` in the lock); both revisions are `0x2` with
identical manifest digests, so their types link. The split is a deliberate, isolated
dual-pin, not resolver churn.

### Reverting before mainnet

These are temporary development dependencies. Once a stable Sui release exposes an
accumulator test constructor, we should:

1. Drop Account's explicit Sui pin and Predict's `implicit-dependencies = false` +
   `sui`/`std` overrides, restoring the implicit testnet framework everywhere.
2. Regenerate Account and downstream package lockfiles from that stable release.
3. Confirm a single framework revision across Predict's lockfile.
4. Re-run Account tests and the relevant Predict build/test suites.

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

## What Predict Can Now Test (empty root)

With the `override` framework pin above, Predict tests construct an **empty**
`AccumulatorRoot` directly (`accumulator::create_for_testing`). Every flow whose
funds move through the account's **stored** balance — the empty-root settle is a
no-op — is therefore unit-testable end to end: account creation/deposit, mint,
live and settled redeem (paid from stored balance), liquidation cleanup, fee and
penalty accounting, and the PLP genesis lock / flush / valuation paths that read
stored balance. These are covered by the Predict flow suite.

## Flows Not Tested Yet

The remaining gap is specifically the **nonzero** address-balance (barrier) path,
which an empty root cannot exercise:

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

## Account events + indexer suite

`account::account_events` emits the account-domain events (lifecycle:
`AccountCreated`, `AppAuthorized`, `AppDeauthorized`; custody: `Deposited`,
`Withdrawn`, `FundsSettled`), indexed by the standalone `account-{schema,
indexer,server}` crates (separate tables / watermark namespace / process from
Predict). See `crates/account-server/API.md` for the served endpoints.

The Move tests in `account_tests.move` assert `AccountCreated`,
`AppAuthorized`/`AppDeauthorized`, `Deposited`, and `Withdrawn` fire with the
expected fields (all reachable against the empty test root). **Nonzero
`FundsSettled` emission stays in the deferred-coverage gap above** — it needs
barrier-delivered funds, the same system-settlement path no Move unit test can
populate. A deposit/withdraw against the empty root settles nothing, so it emits
zero `FundsSettled` (asserted). The Rust side covers `FundsSettled`'s decode →
row mapping and its fold into `account_balance` regardless
(`crates/account-indexer/tests/`), so the only untested link is the on-chain
emission of a nonzero settlement — closed by the same localnet/integration work
the gap above describes.
