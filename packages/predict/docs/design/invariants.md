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
  plus its unresolved trading-loss rebate reserve (`cash ≥ payout_liability +
  rebate_reserve`), re-asserted after every cash mutation
  (`expiry_cash::assert_backing`).
- **Live payout liability is a settlement floor plus a liquidity buffer.** The
  floor is the maximum summed net payout at any *single* settlement price, read
  from `StrikePayoutTree::net_payout_reserve_terms`; the buffer is
  `backing_buffer_lambda × (Σ net payout − floor)`, with both terms derived from
  the payout tree's aggregate quantity/floor atoms. Because exactly one
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

## Floor and leverage

- Predict sells one binary (digital) contract with a static per-order floor;
  leverage changes the floor amount, not a separate debt overlay.
- Live value = range-probability value − static floor, floored at 0. A 1× order
  has zero floor.
- The floor is **limited-recourse per order**: it offsets only its own order's
  value/payout, capped at that value. Aggregate floor exceeding aggregate
  liability is not positive NAV.
- **Mint creation invariant:** leveraged orders start above the knock-out line:
  `entry_probability × quantity > floor_shares / liquidation_ltv`. Fees are
  transaction costs, not floor value.
- `floor_shares = financed_amount = entry_value − net_premium` is the durable
  per-order static floor amount.

## NAV and valuation

- **`current_nav` is the exact per-expiry mark.** `expiry_market::current_nav =
  free_cash − exact_per_order_liability`, floored at zero, where `free_cash =
  cash − rebate_reserve` and the liability is the payout-tree linear walk
  (`strike_payout_tree::walk_linear`, `Σ qty·P`, caching boundary prices for the
  same valuation) minus the leveraged-book floor correction
  (`liquidation_book::correction_value`, reading order range prices from that
  cache). An underwater leveraged order
  nets to zero by the per-order floor cap, so the read needs no liquidation pass.
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
  expiry timestamp and exact terminal payout liability atomically; the Pyth
  per-feed generation timestamp must equal both its enclosing update timestamp
  and the expiry. A carried row aborts at exact insertion. If no qualifying exact
  read exists, `try_settle` returns false without changing the market. Settled
  consumers read no oracle.
- A settled order pays `quantity − floor_shares` if the settlement price is in
  `(lower, higher]`, else 0 (`strike_exposure::quote_close` settled outcome,
  applied by `strike_exposure::process_close`).
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

## Liquidation

- An order is liquidatable when `range_probability × quantity ≤ floor_shares /
  liquidation_ltv`. Only leveraged orders (`floor_shares > 0`) are ever
  liquidatable.
- Liquidation is **permissionless and bounded** per call by a candidate budget.
  Liquidation removes all of the order's book state; the holder's account
  position is the only remaining record until it is redeemed for zero payout.
  The liquidated state is derived, not stored: every flow that removes an order
  from the active index also removes its position in the same transaction,
  except liquidation — so a leveraged order absent from the index while its
  position exists is liquidated. This derivation replaces the former
  `liquidated_orders` tombstone table and its `ELiquidatedOrderAlreadyExists` /
  `ELiquidatedOrderNotFound` guards, which prevented double-insert / double-clear
  of that table. With the table gone, the invariant is protected instead by
  monotonic per-expiry sequence allocation: order ids are never reused, so a
  liquidated order's id can never be re-inserted into the active index to flip
  its derived state back to live.
- Liquidation **priority is encoded in the order-id high bits**: the packed
  quantity field stores the complement (`U32_MASK − quantity_lots`), so an
  ascending `u256` sort over raw order ids liquidates larger quantities first,
  then by floor shares. The book never decodes a field.

## Mint admission

- Raw `entry_probability` must lie in `[min_entry_probability,
  max_entry_probability]`; fees are not included in this admission bound.
- Leverage is continuous at 1e9 scale: any requested `leverage ≥ 1×` is allowed
  only if it is no greater than the dynamic admission cap derived from entry
  probability, time to expiry, the expiry's snapshotted `max_admission_leverage`,
  and the upgrade-required curve-shape constant.
- Within the expiry's snapshotted `no_leverage_window_ms` of expiry the admission
  cap is exactly 1×, regardless of entry probability; a `0` window disables the
  block. This bounds origination only — an order opened before the window keeps its
  leverage into expiry.
- `net_premium = entry_probability × quantity / leverage ≥
  min_net_premium`; the pool seeds the remainder (`financed_amount`).

## Order encoding

- The order id packs, in 196 dense low bits: quantity lots (u32), floor shares
  (u64), lower and higher strike **tick** (u30 each), and an expiry-local sequence
  (u40). Unused bits are leading bits and are rejected by decode validation. The
  quantity and floor fields store complements, so an ascending sort is
  larger-first. A finite strike is `tick · tick_size`; lower tick `0` is the
  `neg_inf` sentinel and higher tick `pos_inf_tick` is the `pos_inf` sentinel.
- **Lossless tick round-trip.** Every atom the canonical evaluator reads —
  quantity, floor shares, and both ticks — round-trips through the packed id with
  no loss. The two `u30` tick fields encode the *same* absolute ticks used at the
  entrypoints, the payout tree, and the liquidation book, so an order's strike
  range is bit-identical whether read from the id, the tree, or the event. A lossy
  repack would be an accounting bug, not a precision nit.
- Mint-admission policy (max leverage cap, admission curve, price thresholds) is
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
- PLP supply and withdraw carry **no fee**. The former uncertainty-band withdraw
  fee (`withdraw_fee_alpha`) was deleted with the approximate-NAV band — the exact
  single-mark NAV has no valuation uncertainty to price.

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
  a Propbook Pyth spot generated at that exact timestamp cannot be live-valued:
  `value_expiry` tries passive
  settlement first, then `current_nav → pricing::load_live_pricer` aborts if the
  market remains unsettled. This preserves the single exact mark for PLP supply and
  withdraw; no approximate substitute mark is allowed. Because the flush must value
  every active market exactly once, this abort blocks the *whole* pool flush, not
  just the one market — so an expiry whose exact settlement spot is permanently
  unobtainable is a cross-market liveness brick, not a benign wait. Guaranteeing the
  exact per-feed datum is obtainable is an accepted external dependency under
  response policy RP-4; a carried observation is not a valid substitute.

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
  caller's mark, haircut, or stance. `strike_exposure::exact_live_liability` returns
  the liability fact; `expiry_market::current_nav` owns the NAV cash floor.
- **Each economic quantity is clamped exactly once, at the policy owner.** A lossy
  transform (clamp at zero, `min`/`max`, saturating subtraction, rounding) is applied
  once, as the last step before use, in the module that owns the policy — never on a
  value a downstream consumer applies further arithmetic to. The single `current_nav`
  cash floor is the canonical example: the liability producer does not pre-floor it.

## Rounding

- All fixed-point math is at 1e9 scale; `math::mul` and `math::div` round **down**
  uniformly.
- **Solvency rests on bit-identical pairing:** where a reserve and a payout derive
  from the same quantity/floor atoms, they use the same net-payout calculation
  (`quantity − floor_shares`), so a reserve can never be short of the payout it
  backs.
- Dust is biased to the protocol/LP pool, never against solvency: payouts round
  down (the holder absorbs ≤1 unit). The exact NAV walk floors at zero with
  `saturating_sub` so bounded fixed-point ulp dust (which the boundary-aggregated
  liability can carry) cannot underflow and abort valuation. See the "Rounding and
  dust" section of [../risks.md](../risks.md).
