# Protocol invariants

A reference list of the facts the Predict protocol maintains — the conditions
that must always hold for it to be correct and solvent. It is a precise,
scannable companion to the prose concept docs, aimed at auditors, integrators,
and contributors. For *how* each mechanism works, follow the links into
[../README.md](../README.md).

> **Status:** pre-deploy. Names refer to modules/functions rather than line
> numbers, which drift.

## Solvency and custody

- **Cash backing.** Every expiry's DUSDC cash always covers its payout liability,
  unresolved trading-loss rebate reserve, and isolated inventory-impact reserve
  (`cash ≥ payout_liability + rebate_reserve + inventory_impact_reserve`),
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
  cash − rebate_reserve − inventory_impact_reserve` and the liability is the
  payout tree's boundary-linear walk (`strike_payout_tree::walk_linear`,
  `Σ quantity × P(range)`) with no per-order correction.
  It is a **pure read with no backing assert** (backing is owned by the payout-tree
  reserve and proven on every trade); the `saturating_sub` cash floor marks a
  degenerate (underwater) market at 0, the correct per-market limited-recourse
  value, never negative.
- **NAV-mark directional invariant — one mark, equals TRUE.** The flush prices PLP
  supply *and* withdraw at the single `pool_nav = idle + Σ current_nav` (net of the
  protocol's unmaterialized-profit exclusion and any carried `pending_protocol_profit`),
  computed once in `finish_flush`. Because each
  `current_nav` is exact, that one mark equals true recoverable value in both
  directions: a supplier prices `=` fair shares (never over-mints to dilute
  incumbents) and a withdrawer draws `=` fair cash. There is **no conservative
  band** — the bucket/band decomposition belonged to the deleted approximate-NAV
  world. Any liveness clamp inside `current_nav` (the degenerate-underwater cash
  floor) only ever *maximizes* NAV when it fires, preserving the supply-mark
  direction. See [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md).
- **Exactly-once full-pool valuation.** The flush hot potato (`PoolValuation`)
  snapshots the active-expiry set at `start_pool_valuation`; each `value_expiry`
  proves its market is in the snapshot and not already valued, and `finish_flush`
  proves the valued set equals the snapshot. A missed or double-counted market would
  mis-price the pool, so the completeness proof is mandatory; the potato has no
  abilities, so it must be consumed by `finish_flush`.

## Settlement

- **Single explicit settlement transition.** `expiry_market::try_settle` is the sole
  settlement-price writer. It records the exact normalized Pyth spot at the market's
  expiry timestamp and exact terminal payout liability atomically; otherwise it
  returns false without changing the market. Settled consumers read no oracle.
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
- The builder fee and the gas-congestion surcharge are add-ons; both are excluded
  from the trading-loss rebate fee basis (only the trade fee counts).
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
- Trading pause blocks new risk creation; exits, settled-market cleanup, and
  valuation are gated only by the valuation lock.
- The settled-market sweep is **pool-coordinated**: it returns LP cash to the pool,
  unregisters the expiry from active valuation, and materializes terminal profit —
  there is no expiry-only path that can strand capital. (The standalone compaction
  step was deleted with the dense NAV matrix; the payout tree is full-lifecycle, so
  the sweep alone suffices.)
- **Past-expiry exact-data liveness.** A market that crosses its expiry but lacks
  an exact Propbook Pyth spot cannot be live-valued: `value_expiry` tries passive
  settlement first, then `current_nav → pricing::load_live_pricer` aborts if the
  market remains unsettled. This preserves the single exact mark for PLP supply and
  withdraw; no approximate substitute mark is allowed. Because the flush must value
  every active market exactly once, this abort blocks the *whole* pool flush, not
  just the one market — so an expiry whose exact settlement spot is permanently
  unobtainable is a cross-market liveness brick, not a benign wait. Guaranteeing the
  exact-timestamp datum is always obtainable (expiry↔publish-cadence alignment, or a
  bounded settlement fallback) is a pre-testnet open item — see the open-issues
  tracker.

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
