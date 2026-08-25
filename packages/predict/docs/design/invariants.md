# Protocol invariants

A reference list of the facts the Predict protocol maintains — the conditions
that must always hold for it to be correct and solvent. It is a precise,
scannable companion to the prose concept docs, aimed at auditors, integrators,
and contributors. For *how* each mechanism works, follow the links into
[../README.md](../README.md).

> **Status:** pre-deploy. Names refer to modules/functions rather than line
> numbers, which drift.

## Solvency and custody

- **Cash backing.** Every expiry's DUSDC cash always covers its payout liability
  and isolated inventory-impact reserve
  (`cash ≥ payout_liability + inventory_impact_reserve`),
  re-asserted after every cash mutation
  (`expiry_cash::assert_backing`).
- **Inventory-impact escrow covers the current potential.** While live,
  `inventory_impact_reserve ≥ phi(payout_liability)`. Mints credit exactly the
  potential increase and voluntary live closes may withdraw only the potential
  decrease;
  settlement releases the residual earmark when live closes become impossible.
- **Inventory cycles telescope.** Inventory charge/rebate is always the signed
  difference between two evaluations of the same deterministic integer state
  function. Therefore any sequence returning the payout book to its starting
  state has exactly zero net inventory transfer, including rounding and
  cross-range reorderings.
- **Live payout liability is a settlement floor plus a liquidity buffer.** The
  floor is the maximum summed payout at any *single* settlement price, read
  from `StrikePayoutTree::payout_reserve_terms`; the buffer is
  `backing_buffer_lambda × (Σ payout − floor)`, with both terms derived from
  the payout tree's aggregate payout terms (each order's `quantity`). Because exactly one
  settlement price resolves a market, the floor alone covers every settlement
  outcome in full (`settled_liability(p) ≤ floor` for every `p`); the buffer
  governs how much pre-settlement exit demand beyond the floor is funded. A
  lambda of 1.0 reproduces the fully summed reserve. See
  [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md).
- **Early exits are buffer-bounded, settlement is not.** A live redeem that
  would push cash below the reserve aborts; smaller closes, later retries, and
  the full settlement payout remain available. Closing a position releases its
  own share of the buffer, so exit liquidity cannot be monopolized.
- **Settled liability is exact.** `StrikeExposure::record_settlement` records the
  terminal price and exact payout liability together; the liability is always ≤
  the settlement floor (hence ≤ the live reserve).
- **No pool earmark.** Each expiry is settlement-self-contained at its floor: a
  market that never receives another top-up still pays every settlement winner
  in full. The per-expiry allocation cap snapshotted at market creation is enforced
  on every funding move as a ceiling, and the pool sync tops every market up toward
  its reserve target before an LP withdrawal pays out.
- **Custody.** DUSDC lives in exactly three places: account-package `Account`
  custody, each expiry's `ExpiryCash`, and the pool ledger's idle balance.
  `ExpiryMarket` is the sole authorizer of expiry cash movement. The protocol
  reserve accumulates the protocol's profit share and is excluded from PLP
  redemption.

## Position value

- **Live value.** `range_probability × quantity`; no floor and no per-order clamp beyond the payout tree's own zero floor.
- **Settled payout.** The full `quantity` for a winning position (settlement price inside `(lower, higher]`), zero otherwise.

## NAV and valuation

- **`current_nav` is the exact per-expiry mark.** `expiry_market::current_nav =
  free_cash − live_marked_liability`, floored at zero, where `free_cash =
  cash − inventory_impact_reserve` and the liability is the
  payout tree's boundary-linear walk (`strike_payout_tree::walk_linear`,
  `Σ quantity × P(range)`) with no per-order correction.
  It is a **pure read with no backing assert** (backing is owned by the payout-tree
  reserve and proven on every trade); the `saturating_sub` cash floor marks a
  degenerate (underwater) market at 0, the correct per-market limited-recourse
  value, never negative.
- **NAV-mark directional invariant — one mark, equals TRUE.** The flush prices PLP supply *and* withdraw at the single `pool_nav = idle + Σ snapshot-instant market NAV` (net of the protocol's unmaterialized-profit exclusion and any carried `pending_protocol_profit`), computed once in `finish_flush`. Because each market's snapshot NAV is exact — `current_nav`'s shape over the reconstructed snapshot-instant book — that one mark equals true recoverable value in both directions: a supplier prices `=` fair shares (never over-mints to dilute incumbents) and a withdrawer draws `=` fair cash. There is **no conservative band** — the bucket/band decomposition belonged to the deleted approximate-NAV world. Any liveness clamp inside the NAV shape (the degenerate-underwater cash floor) only ever *maximizes* NAV when it fires, preserving the supply-mark direction. See [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md).
- **Exactly-once full-pool valuation, on vault-held state.** The in-flight valuation (`PoolValuation`) lives on the vault across transactions, with the `ProtocolConfig` flag (`valuation_in_progress`) engaged for its whole span. `start_pool_valuation` records the active-expiry set; each `value_expiry` proves its market is in the snapshot and not already valued; `finish_flush` proves the valued set equals the snapshot. A missed or double-counted market would mis-price the pool, so the completeness proof is mandatory. The state is released on exactly three paths: `finish_flush` (after the completeness proof and the queue drain), `abort_valuation_privileged` (immediate, lifecycle authority), and permissionless `abort_valuation` once the flush has been in flight longer than `max_valuation_window_ms`. Both aborts discard the partial NAV — frozen marks are sound only as a simultaneous set — while cash already moved by valuation settled sweeps stays (an invariant-preserving per-market move); stale market stamps are lazily discarded by the next trade or settle attempt.
- **One instant per flush.** Every live market's `Pricer` is frozen inside the single snapshot transaction — the ability-less `SnapshotStage` hot potato cannot leave it — and no later stage reads an oracle: the frozen map alone decides each market's sweep-vs-value branch and its mark. The pool NAV a flush prices, and every LP fill against it, is therefore the pool's value at one instant.
- **Post-snapshot trades are recorded exactly once and rolled back.** Every mint or live close on a stamped (snapshotted-not-yet-valued) market records exactly one delta entry: the payout-tree range op as applied plus the measured deltas of the two cash rows NAV reads (`ValuationStamp`). `snapshot_nav` rolls them back — the live tree walked with per-boundary quantities reversed, same rounding and monotonicity contract as the live walk, log-only boundaries priced directly; cash rows reversed by the measured deltas — so the folded figure equals the market's NAV at the snapshot instant. Trades after the market's valuation run unrecorded and are invisible to the already-folded figure (as-of-snapshot either way); a full delta log (`max_valuation_log_ops`) makes further trades abort rather than go unrecorded.

## Settlement

- **Single explicit settlement transition.** `expiry_market::try_settle` is the sole
  settlement-price writer. It records exact Pyth at the market expiry when available, or exact
  Block Scholes after the 30-second Pyth-exclusive window, and exact terminal payout liability
  atomically; otherwise it returns false without changing the market. Settled consumers read no
  oracle.
- A settled order pays its full `quantity` if the settlement price is in
  `(lower, higher]`, else 0 (`strike_exposure::process_settled_close`).
- **R1 settlement-consistency under the tick re-encode.** Settlement compares raw
  prices against tick boundaries through one threshold tick, `prefix_limit_tick =
  ceil(settlement / tick_size)` (`range_codec`): a finite boundary at tick `t` is
  active in the prefix walk iff `t < prefix_limit_tick`, which is exactly
  `t · tick_size < settlement`. The payout-tree prefix-sum winner therefore equals
  the per-order settled-close winner — both use the same half-open `(lower, higher]`
  threshold and the same `tick_size`, so settlement equal to a higher boundary still
  wins at `higher`. `prefix_limit_tick` is a plain `u64` comparison bound (it can
  legitimately exceed `pos_inf_tick` when settlement is above the encodable range)
  and is never validated as a domain tick.
- `StrikeExposure` owns the settled phase: its settlement-price option is the phase
  discriminator, and its cached liability decreases as settled winners redeem.
  Live indexes survive until the settled-market sweep deactivates the expiry.

## Mint admission

- Raw `entry_probability` must lie in `[min_entry_probability,
  max_entry_probability]`; fees are not included in this admission bound.
- `premium = entry_probability × quantity ≥ min_premium`; the holder
  pays this in full — there is no financed remainder.

## Order encoding

- The order id packs, in 132 dense low bits: quantity lots (u32), lower and
  higher strike **tick** (u30 each), and an expiry-local sequence (u40). Unused
  bits are leading bits and are rejected by decode validation. Every field stores
  its raw value — the complement encoding went away with the liquidation scan that
  needed the ordering. A finite strike is `tick · tick_size`; lower tick `0` is the
  `neg_inf` sentinel and higher tick `pos_inf_tick` is the `pos_inf` sentinel.
- **Lossless tick round-trip.** Every atom the canonical evaluator reads —
  quantity and both ticks — round-trips through the packed id with no loss. The two `u30` tick fields encode the *same* absolute ticks used at the
  entrypoints and the payout tree, so an order's strike
  range is bit-identical whether read from the id, the tree, or the event. A lossy
  repack would be an accounting bug, not a precision nit.
- Mint-admission policy (the entry-probability band, minimum premium) is
  **not** part of
  order decoding or structural validation — a future policy change must never
  invalidate an existing packed id.
- Order ids are scoped by `(expiry_market_id, order_id)` and do not encode market
  lifecycle (expiry) in the id.

## Fees

- Trade fee = `fee_rate × quantity`, where `fee_rate = max(base_fee × √(p·(1−p)),
  min_fee) × expiry_fee_multiplier`; the Bernoulli term is 0 at `p ∈ {0, 1}`.
- On a referred mint, `referral_fee = floor(referral_fee_rate × ((trading_fee − fee_incentive_subsidy) + penalty_fee))`. It is split from protocol proceeds, never added to `all_in_cost`; builder fees and inventory-impact charges are excluded. The DUSDC destination is the stored referrer receive address, while `OrderMinted.referrer_account_id` preserves the canonical attribution even when the calculated amount is zero.
- PLP supply and withdraw carry independent flat rates (`plp_supply_fee_rate`,
  `plp_withdraw_fee_rate`; shipped 0 and 20 bps), charged on the DUSDC leg
  **outside** the mark and retained by the pool, so it accrues to remaining
  holders; request limits are measured net of it, and it rounds up to the pool.
  The former uncertainty-band withdraw fee (`withdraw_fee_alpha`) was deleted with
  the approximate-NAV band and is not what this is — the exact single-mark NAV
  still has no valuation uncertainty to price, and the mark is unchanged.

## Lifecycle

- Two orthogonal axes — market status (active → past-expiry → settled) and pool
  registration (registered → deactivated) — plus three
  independent gate flags (`trading_paused`, `mint_paused`, `valuation_in_progress`).
  "Paused" is not a state.
- Trading pause blocks new risk creation. Trade flows (mint, live redeem, settled redeem) are never gated on the valuation flag — a stamped market records deltas instead; the flag gates fee-incentive sponsorship, market creation, LP request cancels, and most config setters; cash rebalancing runs at any time, with in-window live moves recorded on the market's stamp and reversed out of the flush's pool total and profit basis, so the mark is invariant to maintenance timing.
- The settled-market sweep is **pool-coordinated**: it returns LP cash to the pool,
  unregisters the expiry from active valuation, and materializes terminal profit —
  there is no expiry-only path that can strand capital. (The standalone compaction
  step was deleted with the dense NAV matrix; the payout tree is full-lifecycle, so
  the sweep alone suffices.)
- **Past-expiry exact-data liveness.** A market past its expiry cannot be live-valued (`pricing::load_live_pricer` refuses it), so the flush's snapshot stage refuses to stamp an expired-but-unsettled market: it must be settled (`try_settle`) before a flush can start. This preserves the single exact mark for PLP supply and withdraw; no approximate substitute mark is allowed. A market that expires *after* the snapshot is valued as-is at its frozen pre-expiry mark, and its settlement waits only for that one `value_expiry` (or a flush abort). Because the snapshot must cover every active market, an expiry whose exact settlement data is unobtainable at both sources blocks starting the *whole* pool flush — trading continues, but every queued LP fill waits — so a permanently unobtainable settlement spot is a cross-market LP-liveness brick, not a benign wait. Guaranteeing the exact-timestamp datum is always obtainable (expiry↔publish-cadence alignment, plus the bounded Block Scholes settlement fallback) remains tracked in the open-issues tracker.

## Configuration

- Admin-tunable values have a stored field plus a `default_*` seed and an
  `assert_*` bound in `config_constants`, snapshotted per object at creation;
  later admin updates do not reprice active markets. Upgrade-required values stay
  as constants/macros read directly. `min_*`/`max_*` bounds are upgrade-required
  validation envelopes, not config fields. See
  [configuration.md](./configuration.md).

## Cross-object binding

- `ExpiryMarket` stores the Propbook underlying ID; `pricing::load_live_pricer`
  validates that the two propbook feeds passed to a priced flow match Propbook's
  current canonical binding for that underlying and that the market is still
  pre-expiry for live pricing. The registry records one admin-approved config row
  per Propbook underlying. Predict does not version-gate the external feeds.

## Producer facts and single clamp

- **Cross-module returns carry owned facts, not a consumer's policy.** A module
  returns quantities it is the source of truth for (an exposure book returns its raw
  live liability; the pool returns its profit basis), never a value pre-shaped for a
  caller's mark, haircut, or stance. `strike_exposure::live_marked_liability` returns
  the liability fact; `expiry_market::current_nav` owns the NAV cash floor.
- **Each economic quantity is clamped exactly once, at the policy owner.** A lossy
  transform (clamp at zero, `min`/`max`, saturating subtraction, rounding) is applied
  once, as the last step before use, in the module that owns the policy — never on a
  value a downstream consumer applies further arithmetic to. The single `current_nav`
  cash floor is the canonical example: the liability producer does not pre-floor it.

## Rounding

- All fixed-point math is at 1e9 scale; `math::mul_down` and `math::div_down` round **down**
  uniformly.
- **Solvency rests on bit-identical pairing:** where a reserve and a payout derive
  from the same quantity atom, they use the same payout calculation, so a
  reserve can never be short of the payout it
  backs.
- Dust is biased to the protocol/LP pool, never against solvency: payouts round
  down (the holder absorbs ≤1 unit). The exact NAV walk floors at zero with
  `saturating_sub` so bounded fixed-point ulp dust (which the boundary-aggregated
  liability can carry) cannot underflow and abort valuation. See the "Rounding and
  dust" section of [../risks.md](../risks.md).
