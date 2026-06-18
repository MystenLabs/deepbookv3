# Account Accumulator Testing Status

This note captures the current state of the Account package around Sui
accumulator support, the stable-framework PR choice, the optional nightly
verification path, and the flows we still cannot prove with package-local Move
unit tests.

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

## Current Dependency Choice

The current stable/testnet framework lock used by this repo does not expose
`sui::accumulator::create_for_testing`. That `#[test_only]` shim, a wrapper around
the private genesis constructor, is the only path that builds an
`AccumulatorRoot`, and it ships only in a newer nightly framework. Without it,
package-local tests cannot construct an `AccumulatorRoot` at all.

This PR intentionally keeps the Move manifests on the repo-standard testnet
framework:

- `packages/account/Move.toml` has no explicit Sui framework dependency.
- `packages/predict/Move.toml` keeps the implicit framework dependencies and has
  no `implicit-dependencies = false`, no explicit `sui` / `std` entries, and no
  framework `override = true`.
- `packages/account/Move.lock` and `packages/predict/Move.lock` pin a single
  testnet framework revision (`718ae563a42fb4ba0d055588f81c704dcef58c25`).

The tradeoff is explicit test fragmentation: the shared
`accumulator_support::create_shared_root` helper is a no-op on this branch, the
root-dependent Predict flow files are renamed `*.move.disabled`, and the mixed
Account/Predict test files keep their AccumulatorRoot-dependent cases
block-commented.

## Nightly Verification Path

The alternate development setup that re-enables the empty-root unit tests is:

### Account (old-style manifest)

`account` has an `[addresses]` block, so it is an old-style package and can pin the
framework directly:

```toml
Sui = { git = "https://github.com/MystenLabs/sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "2e196df64878a6ee6786cf739474e8bf4a85f726" }
```

### Predict (new-style manifest) - `implicit-dependencies = false` + `override`

`predict` is a new-style package (no `[addresses]`, forced by its transitive
new-style `pyth_lazer` / `propbook` deps), so it cannot pin a system framework in
`[dependencies]` or `[dep-replacements]` (`Sui` is a legacy system name). It is
also not enough for `account` to carry the nightly framework: a dependency's
test-only code, and the framework `#[test_only]`s it calls, are stripped when the
dependency is built for a dependent, so Predict tests cannot reach
`create_for_testing` through `account`. Predict's own canonical framework must
carry the constructor. The mechanism that works is:

```toml
[package]
implicit-dependencies = false

[dependencies]
sui = { git = "...sui.git", subdir = "crates/sui-framework/packages/sui-framework", rev = "2e196df6...", override = true }
std = { git = "...sui.git", subdir = "crates/sui-framework/packages/move-stdlib",   rev = "2e196df6...", override = true }
```

This makes nightly the canonical `sui` / `std` that Predict and `account` bind to,
so Predict's root test code can call `accumulator::create_for_testing` directly.
The other in-repo deps keep the repo-standard testnet framework (`Sui_1` in the
lock). Both revisions are `0x2` with identical manifest digests, so their types
link. The split is a deliberate, isolated dual-pin.

That path is useful for development verification, but it is not the dependency
shape landed by this clean PR. It also still creates only an empty
`AccumulatorRoot`; it does not make package-local unit tests able to populate the
system settlement barrier.

## When Stable Support Lands

Once a stable Sui release exposes an accumulator test constructor, we should:

1. Restore the real body of both `accumulator_support::create_shared_root`
   helpers (`accumulator::create_for_testing(scenario.ctx())`).
2. Rename the Predict `*.move.disabled` files back to `*.move` and uncomment the
   root-dependent cases in mixed test files.
3. Regenerate Account and downstream package lockfiles from the stable release.
4. Confirm Predict's lockfile still has a single framework revision.
5. Re-run Account tests and the relevant Predict build/test suites.

## What Is Tested Now

On the stable/testnet framework branch, `packages/account/tests/account_tests.move`
currently covers:

- one canonical account per owner;
- canonical account ID, wrapper ID, owner, and receive-address derivation;
- duplicate account creation aborts;
- owner auth from `TxContext.sender()`;
- wrong-sender auth aborts;
- self-owned account auth from mutable owner `UID`;
- app whitelist authorization and deauthorization errors;
- whitelisted app auth using `Permit<App>`;
- app data attach, read, mutable read, detach, and namespace separation.

The Account coin deposit / withdraw tests are disabled on this branch because
they need a constructible `AccumulatorRoot`. The source still threads
`AccumulatorRoot` and `Clock` through the public coin APIs, but current
package-local stable-framework tests cannot execute those APIs.

## What Nightly Empty-Root Tests Can Cover

With the nightly override path above, Predict tests construct an empty
`AccumulatorRoot` directly (`accumulator::create_for_testing`). Every flow whose
funds move through the account's stored balance, where the empty-root settle is a
no-op, is unit-testable end to end: account creation/deposit, mint, live and
settled redeem, liquidation cleanup, fee and penalty accounting, and the PLP
genesis lock / flush / valuation paths that read stored balance.

Those Predict flow files remain disabled in this stable-framework PR. Run the
nightly verification branch/path when you need that broader empty-root unit-test
signal before stable Sui exposes the constructor.

## Flows Not Tested Yet

The remaining gap is specifically the nonzero address-balance (barrier) path,
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

The blocker is not Account source structure. Even with the nightly framework, unit
tests can create only an empty `AccumulatorRoot`; external package tests cannot
populate it the same way the system settlement barrier does. The relevant
settlement functions live in `sui::accumulator_settlement`, are not public to
Account, and are system-gated. Advancing a unit-test scenario through `@0x0`
after `balance::send_funds` did not make `settled_funds_value` observe the sent
funds.

## How To Close The Gap

Before mainnet, we need one of these:

- stable Sui framework support that exposes an official test path for settling
  accumulator funds into `AccumulatorRoot`; or
- an integration/localnet test that exercises real checkpoint settlement rather
  than Move unit-test-only state.

Once that exists, add focused tests for Account's nonzero settlement behavior
first, then cover the Predict surfaces that depend on it: PLP fill/refund delivery
to Account and builder-code fee claiming.

## Events

`account::account_events` emits the account-domain events: lifecycle
(`AccountCreated`, `AppAuthorized`, `AppDeauthorized`) and custody (`Deposited`,
`Withdrawn`, `FundsSettled`). The Move tests on this branch assert
`AccountCreated`, `AppAuthorized`, and `AppDeauthorized`. `Deposited`,
`Withdrawn`, and zero-amount `FundsSettled` assertions are part of the disabled
root-dependent Account tests.

Nonzero `FundsSettled` emission stays in the deferred-coverage gap above because
it needs barrier-delivered funds, the same system-settlement path no Move unit
test can populate. The account indexer/server work is intentionally outside this
clean Move-only PR, so event indexing coverage belongs to that follow-up branch.
