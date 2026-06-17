# account

A pure, reusable on-chain **account**: a shared object that holds `Coin<T>`
balances and moves them only through an owner-minted, account-bound `Proof`. It is
the intended canonical "container of value" for the DeepBook protocol suite —
independent of `deepbook`, with no notion of trading, orders, referrals, or any
specific app. Apps store their own opaque per-account state in a witness-namespaced
data slot on the account.

This document describes how `account` works, the reasoning behind the shape, and
what is intentionally deferred. Sections marked **Today** describe code that exists;
sections marked **Deferred** describe direction not yet built.

---

## 1. Philosophy

The old `deepbook::balance_manager` conflated three things: custody, an ownership
model that assumed an EOA sender, and deepbook-specific concerns (trade proofs,
referrals, registry coupling). Every consumer that wrapped it (e.g. Predict) had to
re-implement a shadow of the whole cap system.

`account` is the balance manager reduced to its atomic core and rebuilt so that
composition is native:

- An account is **a container of `Coin<T>`**. The only authority it knows is *who
  may move value* — its owner. "Trade" is not an account concept; it is something an
  app expresses as deposits and withdrawals against the container.
- **Two customers, one object:** a normal EOA wallet, and a "self-owned" account
  that a smart contract (a vault/pool) owns and drives.
- **Apps move value by holding the owner's `Proof`, not by registering.** An app is
  just code that receives a proof the owner minted and spends it; the account never
  has to recognize the app. Apps keep their own per-account state in a data slot
  namespaced by an unforgeable witness type, so nothing needs to be wrapped.

---

## 2. Module layout (Today)

Two layers, smallest and most trusted at the bottom:

```
account_core.move   kernel       — Vault + Proof; moves coins against a bound proof. No public surface.
account.move        front door   — Account + OwnerCap; ownership, proof minting, value movement, app-data.
```

The dependency direction is `account → account_core`; the kernel depends on nothing
in the package.

### Why the kernel is a separate, tiny module

Everything that touches money lives in `account_core` and is auditable in isolation.
It performs **no authorization** — it only verifies that a `Proof` is bound to the
vault it is moving, then moves coins. All authority decisions live one layer up in
`account.move`. The kernel's functions are `public(package)`, so `account` is the
**only public surface** of the package: there is exactly one front door.

### Why `Proof` lives in the kernel (not `account.move`)

`Account` embeds `Vault`, so `account.move → account_core`. The kernel's
`deposit_with_proof` / `withdraw_with_proof` *consume* `Proof`, so `Proof` must be
defined at or below the kernel — otherwise `account_core` would have to import
`account.move` and you'd get a module dependency cycle, which Move forbids. So the
kernel owns the `Proof` type and the binding check; `account.move` owns the
authority to mint it.

---

## 3. Core types (Today)

```move
// account_core
public struct Vault has store { account_id: ID, balances: Bag }   // embedded custody value
public struct Proof has drop  { account_id: ID }                  // ephemeral movement authority

// account
public struct Account  has key, store { id: UID, owner: Option<address>, vault: Vault }
public struct OwnerCap has key, store { id: UID, account_id: ID }  // owner authority for self-owned accounts
public struct DataKey<phantom App>()  has copy, drop, store        // app-data slot key, namespaced by witness type
```

- `Account.owner` is `Some(addr)` for an EOA-owned account (authority by
  `ctx.sender()`), or `None` for a self-owned account (authority by `OwnerCap`).
- `Vault.account_id` is a copy of the owning `Account`'s id; it exists so a `Proof`
  can be bound to a specific account.
- `Proof` has `drop` only: it cannot be stored or transferred, so it lives and dies
  inside a single transaction. It *can* flow between PTB commands (it is an owned
  value, not a borrow), which is what makes "mint once, spend many" work.

---

## 4. The `Proof` model — the one authority (Today)

A `Proof` is the single **"may mutate this account"** authority:

> **Authority is established once (mint a `Proof`); the account is mutated many times
> (spend the `Proof`).**

- **The owner mints; apps consume.** Proof minting (`account_core::issue_proof`) is
  `public(package)`, so the only place a proof is created is inside `account.move`,
  *after* it has checked owner authority. There is no app/registry path to a proof.
  An app can only ever *receive* a proof the owner already minted — so no caller can
  move an account's value without the owner's authorization. This is structural, not
  a convention.
- **The kernel checks binding only.** `deposit_with_proof` / `withdraw_with_proof`
  assert `proof.account_id == vault.account_id` and nothing else. This prevents
  using account A's proof against account B's vault inside one PTB — essential for
  withdrawal safety — without the kernel knowing anything about *who* is allowed.
- **One check, surfaced for non-value actions.** That binding check is
  `account_core::assert_bound`. `account::assert_proof` exposes it so a consumer can
  gate an owner action that moves no value (e.g. app config) on the same proof. There
  is only ever one authorization question — *is this proof bound to this account* —
  and value paths ask it in the kernel while config paths ask it via `assert_proof`.
- **Composability.** A protocol mints one proof, then spends it across many
  `deposit` / `withdraw` calls (e.g. against several pools in one PTB) without
  re-checking authority each time.

### Why `Proof` is not a witness

A witness proves **type identity** ("I am app X" — only X's module can construct
`X`). It cannot carry **instance identity** ("...for account `0xABC`"), because the
account is a runtime object id, not a type. A witness-only movement token would be
*universal* — anyone able to mint it could drain any account. `Proof` carries the
one field a witness fundamentally cannot: the account binding. And because the
account package mints it (only after checking the owner), it is a
*protocol-attestation* of owner authority, which a caller cannot be trusted to
attest about itself.

---

## 5. Authority — one lane: the owner (Today)

Both account kinds act by minting a `Proof`:

- **EOA** (`owner = Some`): `generate_proof_as_owner(account, ctx)` checks
  `sender == owner`.
- **Self-owned** (`owner = None`): `generate_proof_with_owner_cap(account, cap)`
  checks the `OwnerCap` binds to the account. A self-owned account's funds move only
  through proofs minted with its `OwnerCap` — the cap is owner authority, not a
  separate fund-moving cap.

Both produce the same `Proof`, so downstream code never branches on how it was
minted. There are **no held-object capabilities** (`TradeCap` / `DepositCap` /
`WithdrawCap`), **no app authorization lane**, and **no registry**. Delegating "let
address B act for my account" is an app-layer concern (an app stores its own
allowlist), not an account concept.

---

## 6. Value movement (Today)

```move
// account — the only public movement surface, proof-taking
public fun deposit<T>(account, proof: &Proof, coin: Coin<T>)
public fun withdraw<T>(account, proof: &Proof, amount: u64, ctx): Coin<T>
```

Deposit and withdraw are **uniform**: both are gated by a `Proof`, and both delegate
to the `public(package)` kernel (`account_core::{deposit,withdraw}_with_proof`).
There is no generate-and-spend convenience wrapper and no `vault_mut` handle — the
proof-taking front door is the one path, so the same proof funds many movements in a
PTB.

---

## 7. App-data lane (Today)

Apps store opaque per-account state as a dynamic field, namespaced by the app's
witness type so apps cannot collide:

```move
public fun attach<App: drop, Data: store>(account, _app: App, data)
public fun has_data<App>(account): bool
public fun borrow_data<App, Data: store>(account): &Data            // open read
public fun borrow_data_mut<App: drop, Data: store>(account, _app): &mut Data  // witness-gated
public fun detach<App: drop, Data: store>(account, _app): Data
```

Two rules:

- **Namespace by phantom witness type.** Keyed by `DataKey<App>`; one opaque `Data`
  slot per app (an app bundles its state into one struct). Only `App`'s own module
  can construct its witness, so only that app writes its slot — the account never
  understands an app's data shape.
- **Writes witness-gated, reads open.** Mutators take `_app: App` by value (proves
  it is the app's own code). Reads take no witness — on-chain state is public anyway,
  and composing apps should be able to read it.

The data lane is **independent of value**: it never moves coins, so it needs no
`Proof`. The two axes are orthogonal and answer different questions — the **witness**
answers *"whose slot, and is it the app's own code"* (namespacing + integrity); the
**`Proof`** answers *"did the owner authorize this"*. An app applies the proof
itself, at the flow level, only where owner consent is required (an app's autonomous
bookkeeping on its own slot is witness-only).

---

## 8. Deliberately not here (Deferred)

The current model is **owner-proof-only**: an app moves an account's value only with
the owner's proof. So flows where an app would push value into a *user's* account
without the owner present (a keeper crediting a settled payout, an async fill) are
**pull-based** — the app parks the value in its own account and the user collects it
later with their own proof.

The following were considered and are **not** part of this model:

- **Cross-app value composability / lock ledger / settle-against-lock.** The earlier
  "everything in an account, apps push value across accounts" direction required a
  global app registry, an app value-authorization lane, and per-account opt-in
  conventions — all removed in favor of the proof-only model above. Re-introducing
  autonomous cross-account value movement would mean extending the model with an
  explicit, scoped app-authority primitive; it is deferred until a real multi-app
  need exists.
- **Versioning.** When added: a single watermark (not per-account — too many objects
  to migrate), checked at the one chokepoint that gates all mutation. Mirrors the
  monotonic, derive-from-`current_version!()` watermark Predict already uses. Each
  app still self-gates on its own version (the witness proves "app X's code"; the
  app's own gate makes it "app X's *current* code"), so the account never duplicates
  app versions. Deferred.
- **Events.** Created / deposit / withdraw events, added when an indexer needs them.

---

## 9. Build

```
sui move build --path packages/account --warnings-are-errors
```

No tests yet — this is an incrementally-built primitive.

---

## Appendix: design decisions

- **Standalone package, not a deepbook module.** Package `account`, core struct
  `Account`. Named address `account` (unprefixed; revisit at publish).
- **Reduced to atomic custody.** Authorities are only deposit/withdraw; "trade" is an
  app concept. No held-object caps in the core.
- **`owner: Option<address>`** unifies EOA (`Some`) and self-owned (`None` +
  `OwnerCap`).
- **Two-module split, kernel at the bottom**; `Proof` in the kernel (the dependency
  cycle forces it). The kernel is `public(package)`, so `account.move` is the single
  public front door.
- **`Proof` is movement-only and account-bound**, minted only by the owner; apps
  consume proofs, never mint them, so owner authorization is structural.
- **One authorization check.** `assert_bound` (binding) gates value movement in the
  kernel and, surfaced as `account::assert_proof`, gates owner-gated non-value
  actions. A `Proof` is the single "may mutate this account" authority.
- **App-data lane is witness-namespaced**, orthogonal to the proof: witness =
  app-identity/integrity, proof = owner authority.
- **Removed (vs the earlier design):** the `Registry` + `AdminCap`, the app
  authorization lane (`generate_proof_as_app`), per-account opt-in and the
  app-convention consent layer, the generate-and-spend convenience wrappers, and the
  public `vault`/`vault_mut` handles. The proof-only, owner-authored model makes them
  unnecessary.
- **Versioning and cross-app composability deferred**, with the watermark-at-the-
  chokepoint and lock-ledger directions recorded above for if/when they are needed.
