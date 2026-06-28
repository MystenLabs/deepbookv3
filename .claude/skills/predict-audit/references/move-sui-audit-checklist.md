# Move / Sui audit checklist (reference)

Distilled from public Move/Sui audit practice (SlowMist Sui-Move primer, Hacken Move checklist) and this
repo's `.claude/rules/move.md`. Lenses cite this instead of re-deriving. Move removes whole bug classes that
plague Solidity (reentrancy, raw integer overflow, double-spend), so audit effort concentrates on the items
below.

## Access control & ownership (the #1 loss class)
- Any `Object<T>` can be passed by anyone. A function that trusts an object must check the right authority:
  `object::owner`, a held capability (`&Cap`), a witness, or a `Permit`/auth token — not merely that the object
  exists.
- Visibility: `public` is a permanent commitment; custody/accounting mutators should be `public(package)` or
  guarded. Flag any `public` that mutates a balance/liability and any leaf primitive that exposes
  application-level state.
- Shared-object transitions: `share_object` makes a previously-owned object usable by anyone — confirm every
  shared object's mutators are gated.
- Capability hygiene: `store` makes a cap transferable (sellable/leakable) — what does a leaked cap enable, for
  how long, and is it revocable (by id, by allowlist removal, by version freeze)? `destroy` should not silently
  leave an authorized allowlist entry.

## Atomicity & PTB batching
- A PTB calls many functions atomically. If the protocol assumes "one action at a time" (one redeem, one
  liquidation, one valuation), confirm batching/interleaving in a single PTB can't violate it.
- Hot-potato discipline: a no-ability struct (e.g. `PoolValuation`) must be created and consumed in the same
  PTB; verify it cannot be left open, closed early, or consumed against partial state.
- First-writer-wins terminal transitions (settlement): if two paths can write the same terminal state, both
  must apply the same validation, or the weaker path can pre-empt the stronger.

## Arithmetic & rounding
- Move aborts on overflow/underflow automatically — do NOT add asserts that merely re-implement that (it's a
  free invariant check). DO add named guards for semantic bounds, division-by-zero with a real zero, and
  solvency/accounting invariants.
- Rounding direction is a money decision: user-facing outflows round DOWN, protocol-held reserves/liabilities
  round UP or bit-equal (ROUNDING_POLICY R2). A `>=` that can become `<` by one ulp on a backing path is the
  R1 liveness bug class.
- `saturating_sub` is a policy clamp, not a bug-hide; `a - a.min(b)` / hand-rolled sat-sub are smells. Fixed-
  point intermediates (`i64` magnitude = u64 with u128 intermediates) can truncate on cast-back.

## DoS / liveness
- Unbounded iteration on a hot path (valuation, treap walk, liquidation paging/scan) lets a griefer inflate gas
  until a flow is un-runnable. Confirm gas-bounded passes with cursors/watermarks that never skip or double-process.
- A permissionless settlement/claim/keeper function should treat empty/zero cases as a no-op (early return,
  `if (amount > 0)`), not an abort, so a batch sweep can't be reverted by one empty account.
- Funds-trapped: any state where value is owed but no reachable transition pays it out.

## Sentinels & domain edges
- Open-range sentinels (`pos_inf_tick`, `neg_inf`) must be intercepted before finite arithmetic; half-open
  boundary conventions must match across pricing, the payout tree, and settlement classification.
- Degenerate inputs: zero variance/spot, params at their bound, tick edges, smallest/largest position.

## Move idiom / correctness hygiene
- Timestamp semantics: a "last price update" field must not be bumped by unrelated updates (breaks staleness).
- On-chain landing time vs source-data time must be distinguishable in the field name (`*_timestamp_ms` vs
  `*_published_at_us`).
- Cross-module returns are owned facts, not pre-applied consumer policy (no `*_optimistic`/clamp-at-two-altitudes).

## Refactor & API-surface safety
- Guard-preservation across extraction: a moved write path keeps every pre-split auth + value guard (cap, non-zero, in-range, freshness, whole-ms key), or the removal is a journaled decision with the new trust model. (Origin: the oracle split dropped the BS writer-cap + `EZeroForward`/`EZeroSpot` + whole-ms guards.)
- Trust-boundary input validation is owned by the public entrypoint (fail-fast), independent of any leaf guard — a MISSING boundary check is a finding; a boundary check that duplicates a leaf is NOT.
- Open–Closed / irreversibility: a shipped `public` signature, event field, packed-id layout, or error meaning is a permanent commitment — minimize the surface; design extension around a predicted axis of variation.
- Two-sided safety bounds: a circuit breaker / pricing envelope / band bounds BOTH sides, has an admin recovery path (not a hard upgrade-only constant), and is `expected_failure`-tested at each boundary.
