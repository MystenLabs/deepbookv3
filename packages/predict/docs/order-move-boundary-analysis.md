# `order.move` Boundary Analysis — Tightening Responsibilities

**Status:** Analysis / design only. No code changes proposed here.
**Decision context:** We are **keeping** the packed `u256 order_id` design (it is the order's compression
format, the manager position key, and the liquidation sort key, with zero per-order storage — see
`order-id-refactor-analysis.md`). This note only redraws **module boundaries** so `order.move` owns
order identity / encoding / structural validity and **not** mint-admission policy.
All line numbers are from the live files on `strike-exposure-rewrite-state`; the paused
`*_rewrite.move` / `*_ledger.md` files are ignored.

---

## 1. The finding (one sentence)

`order.move` is already almost clean: the **only** misplaced thing is
`assert_mint_leverage_tier` — every other admission-policy check already lives outside it. So this is a
**one-function move plus a doc/boundary clarification**, not a restructure.

Evidence that the other admission gates are already external:
- Minimum principal: `strike_exposure.move:233-235` (`EOrderPrincipalBelowMinimum`), inline in
  `allocate_mint_order`, reading `order.user_contribution()` vs `constants::min_order_principal!()`.
- Terminal-floor ≤ LTV: `strike_exposure_config.move:134` (`ETerminalFloorExceedsLiquidationLtv`).
- Above-liquidation-threshold at entry: `strike_exposure_config.move:223-240`
  (`EOrderBelowLiquidationThreshold`), mint-path only via `mint_index_update_terms`.

`assert_mint_leverage_tier` is the lone exception: it is mint-admission policy
(which leverage is allowed at a given live `entry_probability`) but sits in `order.move`.

---

## 2. Current `order.move` responsibility inventory

Three responsibilities are tangled today; only the third is wrong:

1. **Identity / encoding / structural validity** ✅ — packing, decoding, bounds, shape.
2. **Intrinsic contract-term derivations** ✅ — values that are pure functions of the order's own
   immutable terms (`is_leveraged`, `quantity`, `user_contribution`, `floor_seed_amount`, …). These
   are part of *what the contract is*, not policy, and belong with the terms.
3. **Mint-admission policy** ❌ — `assert_mint_leverage_tier` only. Depends on a *live mint input*
   (`entry_probability`) and *upgrade-required policy thresholds*; it answers "is this order allowed
   to be minted **right now**", which is not an order-validity question.

### Why (2) stays and (3) leaves — the test

- **Intrinsic term derivation:** computable from the `Order`'s own fields alone; changing it changes
  *what the contract pays*, not *who may mint*. → belongs in `order.move`.
- **Admission policy:** gates whether a mint is *permitted* under current/tunable rules; can change by
  upgrade (or future config) **without changing what an `Order` is**. → belongs in the mint flow.

`assert_mint_leverage_tier` fails the first and matches the second. `user_contribution` /
`floor_seed_amount` match the first (they feed pricing/NAV/payout and the events — e.g.
`expiry_market.move:762`, `order_events.move:116,121`, `strike_exposure.move:408,535,571`).

---

## 3. Proposed boundary

**`order.move` answers:**
- Is this packed order id structurally valid? (`from_order_id`/`assert_valid`)
- How do we construct/decode order terms? (`new_from_boundary_indices`, `replacement`, all getters)
- What immutable terms does this `Order` encode? (the getters)
- What order-derived quantities are intrinsic to the contract? (`is_leveraged`, `quantity`,
  `user_contribution`, `floor_seed_amount`)
- What is the leverage vocabulary the protocol supports? (the `leverage_*x()` accessors + the
  rank↔multiplier encoding)

**`order.move` does NOT answer:**
- Is this order allowed to be minted under current policy? (leverage tier, principal floor, LTV, entry
  liquidation threshold) — those live on the mint flow / strike-exposure config.

---

## 4. Function-by-function classification

| Function (`order.move`) | Class | Action |
|---|---|---|
| `from_order_id`, `id` | identity/encoding | **stay** |
| `opened_at_ms`, `lower_boundary_index`, `higher_boundary_index`, `leverage`, `entry_probability`, `quantity_lots`, `quantity`, `sequence` | decoding | **stay** |
| `new_from_boundary_indices`, `replacement` | construction | **stay** |
| `assert_valid_quantity` | structural validity (lot-align, u32 fit) | **stay** |
| `is_leveraged` | intrinsic term predicate | **stay** |
| `user_contribution` | intrinsic term derivation | **stay** |
| `floor_seed_amount` | intrinsic term derivation | **stay** |
| `leverage_one_x` … `leverage_three_x` (5 accessors) | leverage vocabulary | **stay** (keep public; the moved policy reads them — see §5/§Q6) |
| `assert_mint_leverage_tier` + `EInvalidLeverageTier` | **mint-admission policy** | **MOVE** out |
| private: `new`, `decode_u*`, `quantity_lots_from_quantity`, `assert_valid`, `entry_exposure_value`, `user_contribution_from_exposure_value`, `assert_valid_leverage`, `leverage_rank`, `leverage_from_rank`, `assert_valid_order_shape`, `max_encoded_boundary_index` | encoding/validation/derivation | **stay** |

**Borderline, intentionally kept (flag for sign-off):** the *one-sided leveraged range* rule in
`assert_valid_order_shape` (`order.move:325-330`: a >1x order must touch `neg_inf` or `pos_inf`). This
looks policy-ish but is **structural** — a both-sided leveraged order has no coherent floor schedule in
the contract model, so it is "what a valid leveraged `Order` *is*", not a tunable gate. Keep it in
`order.move`. (The `entry_probability ≤ float_scaling` and boundary-domain checks are likewise
field-domain structural bounds, not policy — keep.)

---

## 5. Recommended home for the leverage-tier policy

**Move `assert_mint_leverage_tier` into `strike_exposure.move` as a private helper, called from
`allocate_mint_order` exactly where it is called today (`strike_exposure.move:212`).** Give it a
`strike_exposure` error constant `EInvalidLeverageTier`.

Why `strike_exposure.move` (not config, not a new module):

- **Single caller, same module.** `allocate_mint_order` is the only caller and is where
  `entry_probability` is *born* (`pricing::live_range_probability`, `:204`). "Derive where you use it"
  (move.md) → the tier check belongs at this leaf, next to the existing min-principal admission check
  (`:233`).
- **It reads constants, not config.** The thresholds are upgrade-required
  `constants::leverage_one_x_only_price_threshold!()` / `leverage_two_x_max_price_threshold!()`
  (`constants.move:68,71`). move.md says upgrade-required values are read **directly** by the app logic
  that needs them — so this is plain mint-flow logic, *not* a config-module compute. The two checks
  that live in `strike_exposure_config.move` are there precisely because they read **config fields**
  (`liquidation_ltv`); the tier check reads none, so config is the wrong home today.
- **Not a new `mint_policy.move`.** One function does not justify a module (CLAUDE.md simplicity;
  move.md: don't stand up a module for a lone formula).

It needs the `LEVERAGE_ONE_X`/`LEVERAGE_TWO_X` values (private to `order.move`) — read them via the
existing public `order::leverage_one_x()` / `order::leverage_two_x()` accessors. `strike_exposure`
already depends on `order`, so no new dependency edge and **no new API surface**.

**Simplification while moving:** today `assert_mint_leverage_tier` calls
`assert_valid_leverage(leverage)` first (`order.move:193`). Drop that from the moved version —
structural leverage validity is owned by `order::new` during construction (`:216`→`assert_valid_order_shape`→`assert_valid_leverage`), which runs a few lines later (`:224`). Re-validating
in the policy helper is a defensive duplicate (move.md). The moved helper becomes purely the two tier
comparisons. (`assert_valid_leverage` is private and still used internally, so it stays.)

---

## 6. Forward-looking note: are the thresholds constants or config? (Q7)

Keep them as **upgrade-required constants for now — no behavior change.** They are conceptually similar
to `liquidation_ltv` / `max_expiry_floor_premium`, which *are* admin-tunable snapshotted config
(`strike_exposure_config.move:18-25`). If the team later wants leverage tiers to be admin-tunable:
- the thresholds move into `StrikeExposureConfig` (default in `config_constants`, snapshot per expiry,
  `assert_*` validator), and
- `assert_mint_leverage_tier` then naturally relocates **again** into `strike_exposure_config.move`
  next to `assert_mint_above_liquidation_threshold`, reading the snapshotted fields.

So the placement in §5 is correct for the current constant-based design and has a clean migration path
if tunability is added later. Decide tunability now only if it's on the roadmap; otherwise defer.

---

## 7. Test & abort-code impact (Q8)

- **`EInvalidLeverageTier` is currently untested** — no reference exists outside `order.move`
  (verified by `rg`). So the move breaks **no existing test**, but it should *add* the missing coverage
  (unit-tests.md rule 4). The abort code becomes `strike_exposure::EInvalidLeverageTier`.
- **Add a production-valid mint-flow test** (in `strike_exposure_tests.move` or `expiry_market_tests.move`)
  that mints with a leverage exceeding the tier for a given `entry_probability` and expects the abort —
  it must go through real pricing because the check depends on the live quoted probability
  (unit-tests.md rules 5 & 12; AGENTS.md "Predict public flow coverage").
- **No other call sites change.** `order::assert_mint_leverage_tier` has exactly one caller
  (`strike_exposure.move:212`); it becomes a local helper call.
- **Leverage accessors are unaffected** — all `order::leverage_*x()` usages are in tests
  (`order_tests.move`, `expiry_market_tests.move`, `strike_exposure_tests.move`,
  `flows/plp_rebate_flow_tests.move`); they keep working.
- **Error-constant renumbering:** removing `EInvalidLeverageTier` (`= 8`) from `order.move` leaves a
  gap. Either renumber `order.move`'s constants or leave the gap (cosmetic; pre-deploy, so no ABI
  concern). Recommend renumber for tidiness.
- `order.move` drops its two `constants::leverage_*_threshold!()` calls; the `constants` import stays
  (still used for `position_lot_size!`, `float_scaling!`, `oracle_strike_grid_ticks!`).

---

## 8. Minimal staged implementation plan (do not implement here)

This is small enough to be one PR, but it splits cleanly into two reviewable steps:

1. **Relocate the policy.** Add private `fun assert_mint_leverage_tier(entry_probability, leverage)` +
   `EInvalidLeverageTier` to `strike_exposure.move`; call it in `allocate_mint_order` where
   `order::assert_mint_leverage_tier` is called today; read thresholds from `constants` and leverage
   values via `order::leverage_*x()`; drop the redundant internal `assert_valid_leverage`. Delete
   `assert_mint_leverage_tier` + `EInvalidLeverageTier` from `order.move`. *Verify:* `sui move build`
   clean; full Predict suite green.
2. **Close the coverage + doc gap.** Add the production-valid tier abort test (§7). Update `order.move`'s
   module doc to state the boundary ("identity, encoding, structural validity, and intrinsic term
   derivations; **not** mint-admission policy"); add a one-line doc on the moved helper in
   `strike_exposure.move` naming it as mint-admission policy. *Verify:* new test triggers the abort on
   the intended line (trailing `abort 999` guard per unit-tests.md).

---

## 9. Answers to the 10 questions

1. **What should `order.move` own?** Identity/encoding (`from_order_id`, `id`, getters, `new_*`,
   `replacement`), structural validity (`assert_valid*`, `assert_valid_quantity`, shape/domain bounds),
   and intrinsic term derivations (`is_leveraged`, `quantity`, `user_contribution`,
   `floor_seed_amount`) + the leverage vocabulary. Nothing policy.
2. **Pure structural encoding/decoding that stays:** `from_order_id`, `id`, all field getters, `new`,
   `new_from_boundary_indices`, `replacement`, `decode_u*`, `assert_valid`, `assert_valid_quantity`,
   `assert_valid_leverage`, `assert_valid_order_shape`, `leverage_rank`/`leverage_from_rank`,
   `max_encoded_boundary_index`.
3. **Intrinsic term derivations that stay:** `user_contribution`, `floor_seed_amount`, `is_leveraged`,
   `quantity` (and `entry_probability`/`quantity_lots`/etc.) — all pure functions of the order's own
   terms; consumed by pricing/NAV/payout/events.
4. **Admission policy to move:** `assert_mint_leverage_tier` (the only one).
5. **Where it goes:** private helper in `strike_exposure.move`, called by `allocate_mint_order`
   (§5). Not config (reads constants, not config fields), not a new module (overkill).
6. **Leverage constants/accessors:** keep in `order.move`; **no new accessor needed** —
   `order::leverage_one_x()`/`leverage_two_x()` already exist and are exactly what the moved policy
   compares against. A separate `leverage.move` would wrongly split the value vocabulary from the
   rank↔multiplier encoding.
7. **Thresholds constant vs config:** keep as upgrade-required constants now (no behavior change); if
   made admin-tunable later, move them to `StrikeExposureConfig` (snapshot) and relocate the helper to
   `strike_exposure_config.move` (§6).
8. **Test/abort impact:** `EInvalidLeverageTier` is currently untested → no breakage; add a
   production-valid mint-flow abort test; abort code moves to `strike_exposure`; one source call site
   changes; renumber `order.move` constants (§7).
9. **Other admission policy too close to `order.move`?** No — min-principal, terminal-floor LTV, and
   entry liquidation-threshold checks already live in `strike_exposure.move` /
   `strike_exposure_config.move`. The tier check is the sole exception.
10. **Comments/docs:** update `order.move`'s module doc to assert the boundary (own terms + structural
    validity, not admission policy); annotate the moved helper in `strike_exposure.move` as mint
    admission policy.

---

## 10. Risks & gotchas

- **Sequencing of structural leverage validation.** The moved helper runs *before*
  `order::new_from_boundary_indices` (which is where leverage is structurally validated). Confirm an
  invalid leverage value still aborts cleanly: the tier comparison is well-defined for any integer, and
  construction rejects non-whitelisted leverage immediately after — so dropping the helper's internal
  `assert_valid_leverage` is safe, but verify with a test minting an unsupported multiplier (should hit
  `order::EInvalidLeverage` during construction, not the tier code).
- **Don't widen API surface.** Keep `assert_valid_leverage` private; the moved helper must use the
  existing public `leverage_*x()` accessors, not a newly-exposed internal.
- **Keep it surgical.** Resist also moving `user_contribution`/`floor_seed_amount` or the one-sided
  leverage shape rule — they are intrinsic/structural and belong in `order.move`. The temptation to
  "clean more" here would blur the very boundary we're sharpening.
- **Coverage, not just relocation.** The real latent issue this surfaces is that the tier policy was
  *untested*. The move is only fully done once the abort is covered by a production-valid flow test.
