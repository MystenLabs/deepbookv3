# Versioning and shared-object loaders

> **Status:** proposed pre-deploy cleanup, *not yet implemented*, recorded here as
> the intended direction. What **has** shipped is the oracle extraction: the market
> oracle and Pyth oracle objects moved to the external `propbook` package and are
> **no longer controlled by Predict's package-version gate at all**. The "shipped
> today" notes below describe the current version surface; the rest is the proposed
> loader/centralization cleanup, which can land on its own merits later.

**Shipped today.** `Registry.allowed_versions` is the authoritative set. Exactly two
Predict objects are version-gated and mirror it — `ExpiryMarket` and `PoolVault` —
each refreshing its `VecSet<u64>` mirror through one permissionless registry sync
(`sync_expiry_market_allowed_versions`, `sync_pool_vault_allowed_versions`). Each
gated flow open-codes `self.assert_version_allowed()` (a plain `VecSet::contains`
read) plus its own flow gates. There are no `Versioned` inner structs and no named
flow loaders yet; the cleanup below proposes both. The external propbook feeds carry
their own version and a forward-only `migrate`, so there is **no** Predict-side
oracle/Pyth-source mirror or sync.

Predict currently repeats the same first-line checks across many public
entrypoints: load the shared object, assert the package version is allowed, then
perform the real flow gates such as pause checks, valuation-lock checks, feed
binding, liveness, freshness, owner/cap authorization, and accounting
preconditions. The version check itself is mechanical. The other assertions are
flow-specific and are easier to reason about when they are named by the flow
that needs them.

DeepBook core already uses `load_inner()` / `load_inner_mut()` to borrow a
`Versioned` inner value and assert that the running package version is enabled.
Predict should use the same idea, but not copy it blindly: many Predict public
reads are raw observability APIs and currently remain available while a version
is disabled.

## Goals

- Collapse repeated package-version checks into shared-object loaders.
- Keep raw getters and operational discovery readable during a version freeze.
- Move duplicated flow preconditions into named flow loaders where they truly
  apply.
- Remove per-object `allowed_versions` mirrors if there is a cleaner central
  pattern.
- Keep emergency, recovery, and harm-reducing paths callable even when the
  active version is disabled.
- Keep Predict independent of the extracted oracle package's versioning (already
  the case — see status).

## Non-goals

- Do not hide pricing, settlement, liquidation, or cash-accounting side effects
  inside a generic loader.
- Do not make every raw getter abort under a version freeze unless that behavior
  is explicitly chosen.
- Do not version-gate user account utility flows such as DUSDC withdrawal,
  cap revocation, or builder-fee claiming by default.
- Do not make Predict assert the package version of external oracle objects.
  The oracle package owns its own version and migration policy (shipped).

## Object categories

Predict shared objects fall into different versioning categories:

| Category | Objects | Version policy |
| --- | --- | --- |
| Version authority | `Registry` | **Shipped:** owns the authoritative `allowed_versions` set; the two gated objects mirror it. Also owns expiry uniqueness, feed approval, cap allowlists, and derived-object creation. Version-management and emergency pause/revocation paths bypass the gate. (The proposal below moves the *runtime* version set to `ProtocolConfig`; that has not shipped.) |
| Global flow gates | `ProtocolConfig` | Owns trading pause, the valuation lock, and admin-tunable config. Does not own the version set today. |
| Version-gated protocol state | `ExpiryMarket`, `PoolVault` | The only two version-gated objects. Each mirrors `Registry.allowed_versions` and asserts it on every mutating flow; raw getters stay ungated. |
| User and attribution objects | `PredictManager`, `BuilderCode` | Not package-version gated. They own user custody, caps, positions, and builder-fee claiming. Flow-specific owner/cap checks stay local. |
| External oracle package | `PythFeed`, `BlockScholesFeed` (in `propbook`) | **Not gated by Predict at all.** Each carries its own `version` and forward-only `migrate`; Predict checks only feed binding (`assert_feeds`) and freshness through their public APIs, never their version. There is no Predict-side oracle mirror or sync. |

The oracle extraction is complete: there is no in-package `MarketOracle` or
`PythSource` to keep a version check on. The only mirrors Predict carries are
`ExpiryMarket` and `PoolVault`.

## Central version authority

The cleaner long-term pattern is to store Predict's authoritative
`allowed_versions` in exactly one Predict object: `ProtocolConfig`.

`ProtocolConfig` is a better home than `Registry` for the runtime version gate:

- It already owns global flow gates such as `trading_paused` and
  `valuation_in_progress`.
- Most hot protocol flows already take `&ProtocolConfig`.
- Moving the version set there removes registry sync calls from runtime
  versioning.
- The registry can stay focused on uniqueness, cap allowlists, factories, and
  derived-object roots.

With this pattern, `ExpiryMarket` and `PoolVault` no longer store
`allowed_versions`. Their checked loaders take `&ProtocolConfig` and call a
package-internal version assertion:

```move
public(package) fun assert_version_allowed(config: &ProtocolConfig) {
    assert!(
        config.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}
```

Disabling the active package version becomes immediate for every flow that uses
the central config gate. This intentionally removes the current stale-mirror
window where a per-object mirror may remain enabled until a sync transaction
updates it. Because Predict is still pre-deploy, this is a reasonable semantic
improvement rather than a migration concern.

## Loader contract

For version-gated protocol objects, use checked loaders for semantic protocol
logic:

```move
public(package) fun load_inner(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
): &ExpiryMarketInner {
    config.assert_version_allowed();
    market.inner.load_value()
}

public(package) fun load_inner_mut(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
): &mut ExpiryMarketInner {
    config.assert_version_allowed();
    market.inner.load_value_mut()
}
```

Raw getters should not be forced through these checked loaders if that would
make basic observability unavailable during a version freeze. A module may either
read raw fields directly for trivial getters or keep a deliberately named
unchecked helper:

```move
fun load_inner_unchecked(market: &ExpiryMarket): &ExpiryMarketInner {
    market.inner.load_value()
}
```

Unchecked helpers should be private by default and used only for:

- raw public getters,
- version management and recovery,
- permissionless sync if any mirror remains during a transition,
- emergency pause paths,
- harm-reducing revocation paths.

The naming should make the bypass obvious. Normal protocol flows should not call
unchecked loaders.

## Should `load_inner()` be version gated?

Yes, when `load_inner()` means "this package version is allowed to interpret
this protocol state." That is the right default for semantic reads such as live
NAV, pricing-dependent reads, valuation steps, and package-internal reads that
drive later mutation.

No, raw observability should not be reclassified as semantic protocol
interpretation. These APIs should remain ungated or use an unchecked borrow:

- object IDs,
- expiry timestamp,
- tick size,
- current raw balances,
- pause state,
- configured version set,
- manager/account metadata,
- builder-code identity.

This gives Predict the readability benefit of checked loaders without turning a
version freeze into an observability outage.

## Flow loaders

The generic loaders should check only shared facts that are truly universal for
that object category. Flow-specific facts belong in named loaders or first-phase
helpers.

Parameter shapes below use the shipped feed signatures (`&PythFeed`,
`&BlockScholesFeed`) and the shipped ownership split — feed *binding* and market
*liveness* are the `ExpiryMarket`'s (`assert_feeds`, `assert_active`), and surface
freshness is constructed inside `pricing::pricer`, so a market loader does **not**
duplicate the freshness check or carry a `clock` for it.

| Flow loader | Shared validation |
| --- | --- |
| `expiry_market::load_inner(config)` | package version allowed for semantic reads |
| `expiry_market::load_inner_mut(config)` | package version allowed for normal market mutation |
| `expiry_market::load_mint_market_mut(config, pyth, bs)` | market version, mint not paused, trading not paused, no valuation lock, feed binding, active market |
| `expiry_market::load_redeem_market_mut(config, pyth, bs)` | market version, no valuation lock, feed binding; live-vs-settled branch checks remain outside |
| `expiry_market::load_liquidation_market_mut(config, pyth, bs, clock)` | market version, no valuation lock, feed binding, active market |
| `plp::load_vault_inner(config)` | package version allowed for semantic reads that value or account for the vault |
| `plp::load_vault_inner_mut(config)` | package version allowed for normal vault mutation |
| `plp::load_registered_market_mut(config, market)` | vault version, market version, expiry registered to the vault |
| `plp::load_valuation_step_mut(config, valuation, market)` | valuation lock active, valuation belongs to vault, market is in the snapshot and not yet valued, plus registered-market checks |

Do not put these facts into one generic `load_inner_mut()`:

- trading pause,
- valuation lock state,
- mint pause,
- manager owner/proof/cap authority,
- feed object binding (`assert_feeds`),
- market liveness (`assert_active`),
- surface freshness (owned by `pricing::pricer`),
- cash backing,
- position ownership.

Those are not universal. Keeping them in named flow loaders makes each
entrypoint read as "load the object for this flow, then do the flow."

## Version management paths

Version-management and emergency paths need explicit bypass rules:

| Path | Version behavior |
| --- | --- |
| `enable_version` | Bypasses the current version gate so admin can recover from a disabled active version. |
| `disable_version` | Bypasses the current version gate; refuses to leave the allowed set empty. |
| Pause-cap version disable | Bypasses the version gate and requires a valid `PauseCap`. |
| Pause-cap global trading pause | Bypasses the version gate and can only set `trading_paused = true`. |
| Pause-cap market mint pause | Bypasses the version gate and can only set `mint_paused = true`. |
| Cap revocation | Bypasses the version gate when revocation is harm-reducing and should remain available during recovery. |
| Cap mint / authority grant | Version-gated unless it is an emergency cap whose purpose is to work during a freeze. |
| Raw getters and discovery | Ungated. |

If the version set moves to `ProtocolConfig`, pause-cap version disable should
take both the registry and config:

```move
public fun disable_version_pause_cap(
    registry: &Registry,
    config: &mut ProtocolConfig,
    pause_cap: &PauseCap,
    version: u64,
)
```

The registry proves the pause cap is valid. The config mutates the version set.

## Public API impact

Removing per-object mirrors means some currently version-gated functions need
`&ProtocolConfig` if they do not already have it.

Likely additions (there is no `create_pyth_source` — Predict no longer creates
oracle objects; feeds are created in `propbook`):

- `registry::mint_lifecycle_cap(..., config: &ProtocolConfig, ...)`, if granting
  lifecycle authority stays version-gated.
- `registry::create_expiry_market(..., config: &ProtocolConfig, ...)` — it already
  takes `&ProtocolConfig`, so no change.
- `expiry_market::set_mint_paused(market, config, admin_cap, paused)`, unless
  admin unpause is intentionally allowed during a version freeze.
- `plp::stake_deep(vault, manager, config, deep, ctx)`, if staking new DEEP
  should remain version-gated.

Likely unchanged:

- mint, redeem, liquidation, valuation, and cash rebalance already take
  `ProtocolConfig`.
- `PredictManager` deposit, withdraw, cap revocation, and proof generation should
  not require `ProtocolConfig`.
- `BuilderCode` fee claiming should not require `ProtocolConfig`.

This API churn is acceptable pre-deploy if it deletes sync functions and
per-object mirrors. If minimizing public signature churn is more important, keep
mirrors and use a shared `VersionGate` component instead.

## Alternatives considered

### Keep per-object mirrors, but wrap them

Store a shared `VersionGate` component in each gated object and keep
permissionless sync from the registry or config.

Pros:

- Minimal public API churn.
- Hot flows do not need a central version object unless they already need it.
- Close to the existing DeepBook mirror pattern.

Cons:

- Duplicated storage remains.
- Sync functions remain.
- A disabled version may not take effect on every object until its mirror is
  updated.

This is the safest incremental implementation, but it leaves the awkwardness the
cleanup is trying to remove.

### Central version set on `Registry`

Make every version-gated loader take `&Registry`.

Pros:

- Matches the current mental model that `Registry` owns versions.
- One authoritative set and no mirrors.

Cons:

- Adds `Registry` to hot trade, liquidation, valuation, and pool flows that do
  not otherwise need it.
- Keeps a runtime safety gate on the factory/index object instead of the global
  flow-gate object.

This is worse than using `ProtocolConfig`.

### Version ticket

Have `ProtocolConfig` mint an ephemeral `VersionTicket` after one version check,
then pass `&VersionTicket` into checked loaders.

Pros:

- Makes the version proof explicit.
- Can amortize one config version check across many object loaders in a large
  PTB.

Cons:

- Adds ceremony to every public flow.
- Harder for Move integrators than passing `&ProtocolConfig`.
- Does not remove the need for flow-specific assertions.

This can be revisited if repeated config checks become a measured gas issue.

### Single allowed version scalar

Store one allowed package version instead of a set.

Pros:

- Less storage and simpler checks.

Cons:

- No overlapping upgrade window.
- Harder to run old and new package versions during a controlled migration.

The set is worth keeping.

## Recommended design

Use `ProtocolConfig.allowed_versions` as the single authoritative Predict
version set. Delete per-object `allowed_versions` mirrors from long-term Predict
objects and remove the corresponding sync entrypoints.

Use checked `load_inner(config)` and `load_inner_mut(config)` for
version-gated protocol objects, especially `ExpiryMarket` and `PoolVault`.
Keep raw getters ungated by reading directly or through explicitly named
unchecked helpers.

Build named flow loaders on top of the generic loaders for repeated entrypoint
preconditions. The generic loader checks package-version eligibility. The flow
loader checks the rest of the facts that are common to that specific flow.

Exclude `PredictManager` and `BuilderCode` from the package-version freeze by
default. Exclude external oracle objects entirely; Predict should validate that
the supplied oracle/feed objects match the market and are fresh enough, while
the oracle package validates its own version.

## Implementation notes

- Introduce inner structs for protocol objects before moving large flows, so
  field access changes are mechanical.
- Move the version set and version-management entrypoints to
  `ProtocolConfig`, or expose them there and leave registry wrappers only if the
  public surface needs compatibility.
- Delete mirror setters and sync functions once all checked loaders use
  `ProtocolConfig`.
- Keep bypass helpers small and local. Every unchecked call site should be easy
  to audit.
- Update tests to cover disabled-version behavior for:
  - mint/redeem/liquidate,
  - pool valuation and cash rebalance,
  - market creation and lifecycle-cap mint,
  - emergency pause and version re-enable,
  - raw getters still working while disabled.

---

# Design review — feasibility, tradeoffs, blindspots

> Appended 2026-06-13 after reading the version surface end to end:
> `protocol_config.move`, `registry.move`, `expiry_market.move`, `plp.move`,
> `oracle/market_oracle.move`, `oracle/pyth/pyth_source.move`, and DeepBook core's
> `packages/deepbook/sources/pool.move` `load_inner` (the pattern this doc cites).
> Claims cite the code that backs them.

## Verdict

**The direction is right and part of it should land as-is — but the doc fuses
three changes with very different risk/value profiles under one "collapse repeated
version checks" banner, and the most consequential of the three is mis-motivated.**
Pull them apart:

- **(A) Centralize the package allowed-versions set on `ProtocolConfig`, delete the
  per-object mirrors + sync.** High value, low risk, and actually a *security*
  improvement the doc undersells (§3). **Recommend doing this.**
- **(B) Named flow loaders for repeated entrypoint gates.** Mostly well-scoped
  already; one item (`load_mint_market_mut`'s "fresh pricing inputs") reaches into a
  precondition `Pricing` owns and should be trimmed (§4). **Recommend, trimmed.**
- **(C) Adopt `sui::versioned::Versioned` inner structs (`load_inner`/`load_value`).**
  This is a *post-deploy upgradability* decision wearing a dedup-cleanup costume. It
  does not itself reduce version-check repetition (A does that), it is a large
  mechanical refactor, and the repo's standing rule is "don't build migration
  machinery pre-deploy unless explicitly wanted." **Recommend deciding it on its own
  merits, separately (§5) — not as a side effect of the cleanup.**

The single most useful reframing: **the doc conflates two orthogonal version axes
and three separable refactors.** Untangling them (below) makes the safe parts
obviously safe and isolates the one real architectural decision.

## 1. This is three changes, not one

The doc reads as one cleanup, but the code touches three independent things:

1. **Where the package allowed-versions set lives.** Today `Registry` is the source
   of truth and `ExpiryMarket` / `PoolVault` each hold a `VecSet<u64>` *mirror*
   refreshed by two permissionless `sync_*_allowed_versions` entrypoints. (The
   former `MarketOracle` / `PythSource` mirrors and their syncs are gone — those
   objects left for `propbook`, which versions itself.) (A) moves the set to
   `ProtocolConfig` and deletes the remaining two mirrors + syncs.
2. **How the repeated gates are expressed.** Today each entrypoint open-codes
   `self.assert_version_allowed()` + flow gates (`expiry_market.move:201-204`,
   `plp.move:173`,`224`,…). (B) replaces the version line with a central assertion and
   bundles the rest into named flow loaders.
3. **Whether protocol state moves behind a `Versioned` wrapper.** Today Predict uses
   *no* `Versioned`; objects store fields plainly and `assert_version_allowed` reads a
   plain `VecSet` field. (C) introduces `*Inner` structs wrapped in
   `sui::versioned::Versioned` so `load_inner` can `inner.load_value()`.

(A) and (B) deliver the doc's stated goal (fewer, clearer checks) **without** (C).
(C)'s only real payoff is unrelated to check-deduplication — see §5. Treat them as
three PRs with three justifications.

## 2. Two different "versions" are conflated

The doc's `load_inner` mirrors DeepBook core, but core's `load_inner`
(`pool.move:1883-1900`) does **two** things that are easy to read as one:

- `self.inner.load_value()` — borrows the `Versioned` inner. This guards the
  **object-data layout version**: after an upgrade that changes the inner struct's
  shape, `load_value` forces a migration before the new code can read the object.
  This axis is about *data*.
- `assert!(inner.allowed_versions.contains(current_version), …)` — the **package
  allowed-versions** kill-switch / upgrade window. This axis is about *code*.

These are independent. Predict today has only the second axis (a plain `VecSet`
gate); it has no first axis at all. The proposal's (A) is entirely about the second
axis (where the set lives); (C) is entirely about adding the first axis. The doc
never separates them, which is what lets a *data-migration mechanism* (`Versioned`)
get justified by a *code-gate dedup* goal. State the two axes explicitly in the doc;
it dissolves most of the confusion. A clean end state is in fact *better* than core
here: central package gate on `ProtocolConfig` + per-object `Versioned` layout
version, rather than core's per-pool `allowed_versions` fused inside each inner.

## 3. (A) Centralize the version set — strong win, and a security upgrade the doc undersells

The doc frames immediacy as a mild "semantic improvement." It is more than that.

- **Today's disable is eventually-consistent, not immediate.** `disable_version`
  removes the version from `Registry` only; every `ExpiryMarket`/`PoolVault` keeps
  minting/trading on its *stale mirror* until someone lands a `sync_*` tx
  (`registry.move:144-151`). Nothing forces those syncs. So a version-disable — a
  safety lever — does not actually stop hot flows until N per-object syncs are
  mined. Centralizing on `ProtocolConfig`, which every hot flow already borrows
  immutably, makes the disable atomic for all of them. That is a real reduction in
  blast-radius-to-effect latency.
- **Caveat that keeps it honest:** the *fast* emergency stop is already
  `trading_paused` (a bool on `ProtocolConfig`, immediate — `protocol_config.move:42`,
  `:334`), so the stale-mirror window mostly bites *version/upgrade hygiene* rather
  than a live exploit (operators would hit trading-pause first). Frame the win as
  "version-disable becomes immediate and the mirror/sync surface disappears," not "we
  gain an emergency stop we lacked."
- **Concurrency is neutral — a point in favor the doc omits.** The version set is
  *read* (`VecSet::contains`) off an **immutably**-borrowed `ProtocolConfig`; many
  txs read a shared object immutably without serializing. Hot flows that already take
  `&ProtocolConfig` (mint/redeem/liquidate/valuation/rebalance) gain nothing to
  contend on. Only `disable_version` needs `&mut`, and it is rare. So centralization
  does not add hot-path contention.
- **The deletion is real but smaller than it looks post-extraction.** Four `sync_*`
  fns, four mirror fields, four setters/getters, plus moving enable/disable off
  `Registry`. But `MarketOracle`/`PythSource` mirrors are leaving Predict's gate
  anyway via oracle extraction (§6), so the *net* mirrors this change deletes are
  `ExpiryMarket` + `PoolVault` (two), plus the registry→config move. Worth stating so
  the cleanup isn't oversold.
- **Consistent with the repo's "improve on core, don't copy its weaknesses" ethos**
  (the same principle the predict crates follow against core). Core's per-pool mirror
  *is* the stale-mirror weakness; declining to copy it is in-character, not a risky
  deviation — but see §6 on validating the divergence.

## 4. (B) Flow loaders — mostly well-scoped; one item violates the repo's ownership rules

The decomposition is more careful than a first read suggests: version + object
binding live in `load_registered_market_mut`, and `load_valuation_step_mut`
*composes* it and adds the valuation-only facts. That layering is good and matches
how the code already nests checks (`value_expiry` defers the version+binding to
`rebalance_expiry_cash_inner` at `plp.move:458-459`).

**The one real over-reach is `load_mint_market_mut`'s "fresh pricing inputs."**
Freshness is owned by `Pricing` and is asserted *as a side effect of constructing the
`Pricer`* (`pricing::pricer` → `live_inputs` → `assert_live_quote_available`). The
repo rules are explicit: "`Pricing` owns live oracle freshness"; "do not preflight
another module's local leaf preconditions just to avoid a later abort"; "avoid
defensive duplicates." A market loader that also asserts freshness must either (i)
duplicate the Pricing check (then `mint_internal` builds the pricer and re-asserts —
the exact duplicate the rules forbid), or (ii) build and return the `Pricer` from the
loader — which the doc's own Non-goal forbids ("do not hide pricing … inside a generic
loader"). **Resolution: drop "fresh pricing inputs" from the mint/liquidation loaders.**
Let them assert only what the *flow* owns — version, mint-pause, trading-pause,
valuation-lock, and the `ExpiryMarket`-owned feed bindings (`assert_feeds`) — and
return `&mut ExpiryMarket`; freshness stays where it already lives, in pricer
construction. This also means the loaders do **not** need a `clock` just to check
freshness, shrinking their signatures. (This is already how the shipped code is
structured after the oracle extraction: `pricing::pricer` builds the value-typed
`Pricer` and gates surface freshness; the market owns `assert_feeds` + `assert_active`.)

`load_redeem_market_mut` correctly notes "live-vs-settled branch checks remain
outside" — that respects the branch-policy ownership rule and is the model the mint
loader should follow. "Active market" is fine to keep (it calls the `ExpiryMarket`'s
own `assert_active`, the owner's exposed assertion, not a reconstruction).

**Naming caveat tied to (C):** the name `load_inner` presupposes there *is* an inner
to load. Without (C) there is no `*Inner` struct, so the generic pair should be a
plain `config.assert_version_allowed()` plus the named flow loaders — not
`load_inner`/`load_inner_mut`. Don't import core's name without core's inner struct.

## 5. (C) `Versioned` inner structs — an upgradability decision, not a dedup cleanup

`sui::versioned::Versioned` exists for one purpose: letting an already-shared
object's **data layout** evolve across package upgrades (`load_value` forces a
migrate-before-read; `pool.move:1850` creates it, `:1886`/`:1896` load it). It does
nothing for check-deduplication — (A)'s central `assert_version_allowed(config)`
already removes the repetition. So (C)'s justification cannot be "collapse repeated
checks"; its only real payoff is **post-deploy upgradability of `ExpiryMarket` /
`PoolVault` state**.

Two facts make this a genuine decision rather than a free cleanup:

- **It is last-chance.** You cannot retrofit `Versioned` after mainnet — objects
  created as plain structs can never be migrated later. If Predict wants *any* ability
  to change shared-object layout post-deploy, the wrapper must exist at first deploy.
  This is exactly why core has it from day one.
- **It cuts against a standing repo rule.** `.claude/rules/move.md`: "do not optimize
  contract changes for backwards compatibility, object layout preservation, or
  migration paths unless the user explicitly says deployed objects or upgrade
  compatibility matter," and "do not add `sui::dynamic_field` storage unless
  explicitly requested" (`Versioned` stores its inner under a dynamic field). So
  adopting it needs an explicit "yes, we want upgradable object state before
  mainnet," not an implicit ride-along on a loader cleanup.

**Recommendation:** decide (C) as its own line item with the upgrade strategy in view.
If the answer is "yes, we want migratable object state at mainnet," adopt `Versioned`
deliberately and accept the mechanical refactor (every field access behind
`load_inner`/`load_inner_unchecked`). If the answer is "not yet," ship (A) + (B-trimmed)
now — they stand entirely on their own — and add `Versioned` in a dedicated PR before
the deploy freeze. The worst outcome is adopting the big refactor *because* it looked
like part of the dedup, then discovering the dedup never needed it.

## 6. Other blindspots and risks

- **Valuation-lock × version-gate: a mid-valuation disable can strand the lock.**
  `finish_flush` asserts `vault.assert_version_allowed()` *before* `end_valuation()`
  (`plp.move:224-257`). If the active version is disabled after `start_pool_valuation`
  but before `finish_flush`, the finisher aborts on the version gate and the
  `valuation_in_progress` lock is left set → no NAV op or new valuation until the
  version is re-enabled. **In practice this is currently unreachable** because
  `PoolValuation` is a *hot potato* (`plp.move:172`, consumed by `finish_flush`), so
  the whole valuation is one atomic PTB and the version cannot change mid-flight. But
  (A)+(B) are the moment to make that safety explicit: either keep the hot-potato
  guarantee (and note that it, not the version gate, is what bounds the lock) or add
  valuation *finish/abort* to the bypass list in "Version management paths" (it is a
  recovery/harm-reducing path, like the others there, and is conspicuously absent).
  The hot-potato bound also means the per-step version re-checks inside
  `rebalance_expiry_cash_inner` are redundant *within a valuation* — they exist for the
  standalone `rebalance_expiry_cash` path, which is fine, but the loader refactor
  should not add a *second* top-level version gate to `value_expiry`
  (`plp.move:189-209` deliberately has none today).
- **Centralization is a divergence from core — validate it independently.** Core keeps
  `allowed_versions` per-pool *inside* the `Versioned` inner; Predict would make it
  central on `ProtocolConfig`. That is the better choice (it is what removes the
  stale-mirror window), but it means "core does it this way" is *not* cover for the
  centralization — only for the `load_inner` mechanism. Lean on core for (C)'s
  mechanics, not for (A)'s topology.
- **Oracle-extraction ordering — now resolved.** This blindspot was about sequencing
  the version cleanup against an in-flight oracle extraction. The extraction has since
  *fully* shipped: there is no in-package `MarketOracle` / `PythSource` left to carry a
  mirror, the two feeds live in `propbook` and version themselves, and Predict's only
  mirrors are `ExpiryMarket` + `PoolVault`. So the version cleanup (A)+(B)+(C) is now a
  single clean pass over exactly two objects, with no oracle objects about to leave.
- **Raw getters are already ungated — this is preservation, not a change.** None of
  the `ExpiryMarket`/`PoolVault` getters call `assert_version_allowed` today, so
  "keep getters readable under a freeze" is only a *constraint on (C)*: if state moves
  behind `load_inner`, do not route getters through the checked loader. Without (C)
  there is nothing to preserve. Say so, so the section isn't read as new behavior.
- **`set_mint_paused` under a freeze (doc's "likely additions").** Gating admin
  *unpause* on the version is a real policy choice: a disabled version that also blocks
  un-pausing couples two levers. Since `enable_version` bypasses the gate, it is
  recoverable, but decide deliberately whether admin should be able to unpause a market
  while the version is disabled (the doc flags this — just make it an explicit yes/no,
  not a default).

## 7. Ownership / correctness checks I ran (all consistent)

- **`ProtocolConfig` is the right home and is already shaped for it.** It owns the
  sibling global gates `trading_paused` and `valuation_in_progress`
  (`protocol_config.move:42-45`), and `assert_trading_allowed` *already documents* that
  it deliberately omits the version gate because per-object mirrors carry it
  (`:305-312`) — (A) is precisely deleting that seam. ✓
- **No new hot-path objects.** Every flow the version gate guards already borrows
  `&ProtocolConfig` (mint/redeem/liquidate/valuation/rebalance); the "likely additions"
  list (`stake_deep`, `mint_lifecycle_cap`, `set_mint_paused`) is the complete set that
  gains a `config` param, and all are cold paths. ✓
- **Pause-cap version disable correctly needs both objects.** Proving the cap is a
  `Registry` allowlist fact; mutating the set is a `ProtocolConfig` fact — so the
  proposed `disable_version_pause_cap(registry, config, pause_cap, version)` two-object
  signature is the right consequence, not accidental coupling. ✓
- **Keeping the set (not a scalar) is right,** and the doc rejects the scalar for the
  right reason (overlapping upgrade window). With `current_version == 1` there is no
  overlap yet, but the capability is cheap to keep and expensive to add back. ✓

## 8. Decision points for the author

1. **Ship (A) now.** Centralize on `ProtocolConfig`, delete `ExpiryMarket`/`PoolVault`
   mirrors + the `sync_*` entrypoints, move enable/disable (and the pause-cap disable's
   config arg). Frame the win as immediate disable + smaller surface, not a new
   emergency stop.
2. **Ship (B), trimmed.** Build named flow loaders for the gates each flow *owns*; drop
   "fresh pricing inputs" (and the `clock`) from the mint/liquidation loaders and leave
   freshness in pricer construction. Don't call them `load_inner` unless (C) lands.
3. **Decide (C) separately, with the upgrade strategy in view.** Yes → adopt `Versioned`
   deliberately as upgradability infrastructure before the deploy freeze. Not yet →
   keep plain structs; (A)+(B) lose nothing.
4. **No oracle-extraction sequencing remains** (§6 — the extraction shipped; only
   `ExpiryMarket` + `PoolVault` are gated). Still **add valuation finish/abort to the
   version bypass list** (§6) when (A)+(B) land.
