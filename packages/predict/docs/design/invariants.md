# Protocol invariants

A reference list of the facts the Predict protocol maintains — the conditions
that must always hold for it to be correct and solvent. It is a precise,
scannable companion to the prose concept docs, aimed at auditors, integrators,
and contributors. For *how* each mechanism works, follow the links into
[../README.md](../README.md).

> **Status:** pre-deploy. Names refer to modules/functions rather than line
> numbers, which drift.

## Solvency and custody

- **Cash backing.** Every expiry's USDC cash always covers its payout liability
  and isolated inventory-impact reserve
  (`cash ≥ payout_liability + inventory_impact_reserve`),
  re-asserted after every cash mutation
  (`expiry_cash::chk_backing`).
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
  from `StrikePayoutTree::rsv_terms`; the buffer is
  `backing_buffer_lambda × (Σ payout − floor)`, with both terms derived from
  the payout tree's aggregate payout terms (each order's `quantity`). Because exactly one
  settlement price resolves a market, the floor alone covers every settlement
  outcome in full (`settled_liability(p) ≤ floor` for every `p`); the buffer
  governs how much pre-settlement exit demand beyond the floor is funded. A
  lambda of 1.0 reproduces the fully summed reserve. See
  [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md).
- **Early exits are buffer-bounded, settlement is not.** An early sell that
  would push cash below the reserve is refunded at its fill (reason 8), and its
  position returns to its Open record. Smaller closes, later retries, and the
  full settlement payout remain available. Closing a position releases its
  own share of the buffer, so exit liquidity cannot be monopolized.
- **Settled liability is exact.** `StrikeExposure::set_settled` records the
  terminal price and exact payout liability together; the liability is always ≤
  the settlement floor (hence ≤ the live reserve).
- **No pool earmark.** Each expiry is settlement-self-contained at its floor: a
  market that never receives another top-up still pays every settlement winner
  in full. The per-expiry allocation cap snapshotted at market creation is enforced
  on every funding move as a ceiling, and the pool sync tops every market up toward
  its reserve target before an LP withdrawal pays out.
- **Custody.** USDC lives in exactly four places: account-package `Account`
  custody, each expiry's `ExpiryCash`, each queued order's escrow in its
  `deepbook_predict_orders` record, and the pool ledger's idle balance.
  `ExpiryMarket` is the sole authorizer of expiry cash movement. The protocol
  reserve accumulates the protocol's profit share and is excluded from PLP
  redemption.

## Delayed execution

See [../concepts/delayed-execution.md](../concepts/delayed-execution.md).

- **Predict decides every fill.** Every change to a queued order's position,
  market cash, or Predict's order-flow ledger happens inside one Predict
  primitive that checks its own gates and the order's receipt when it runs.
  Admission, commit, and fills also require an allowlisted witness type.
  Predict never names a companion type.
- **A receipt is consumed exactly once.** `OrderReceipt` has `store` only, so
  it cannot be copied, forged, or dropped, and only Predict unpacks it. A
  payout or a full close consumes it, so a position is paid or closed once.
  A receipt is refused on any market but its own, and every primitive checks
  the stage it needs.
- **The ledger is exact.** A market's waiting cash need and payout-tree pins
  enter only through an admission and leave only through the receipt that
  added them.
- **Each record holds exactly its own escrow.** A record's escrow is its
  order's budget, order fee, and reserved subsidy, held next to its receipt.
  A fill or a release requires escrow of at least that sum (`EEscrowMismatch`
  otherwise), and a refund returns exactly that record's escrow, less a fee
  kept for reasons 1 and 2, so no pooled shortfall or residue can arise.
- **Escrow is outside cash, NAV, and backing.** No waiting order changes market
  cash, required cash, NAV, or the pool mark until it fills.
- **Fills never draw on the pool.** A fill pays from the order's escrow and the
  market's own cash, and leaves market cash at or above required cash. The
  fill checks this before anything moves and refunds a cash-short order
  (reason 8), then the backing check re-asserts it after the fill.
- **One price per cohort, fixed by τ.** A cohort accepts only the update stamped
  exactly τ on its stored channel, or, with the backup tick switched on and once
  `gap_wait_ms` has passed, the single update one tick of that channel later.
  Predict stores only a `LazerPrice` built from a Pyth-verified update for the
  receipt's feed and channel, generated at or after τ. A cohort commits whole
  or not at all, and never at or past its deadline.
- **τ and the deadline never decrease along record IDs.** A committed cohort
  never grows, and a cohort never mixes Pyth channels.
- **The deadline is final.** At or past its deadline an unfinished order can
  only be refunded in full. Predict refuses a deadline less than 5 seconds
  before expiry, so every waiting order is due before the market can settle.
- **Fill, refund, and settlement calls create no objects.** Commit, resolve,
  refund, and `settle_step` take `&TxContext`, admission creates and pins
  every payout-tree node a fill will touch, and the trader whose order creates
  a market's ledger pays its storage. A pinned node is never pruned, and a
  snapshot release keeps it. A market's queue is created once, by a separate
  call.
- **Settlement never waits on the queue.** `try_settle` reads nothing from the
  queue. `settle_step` refunds waiting orders and pays Open records in bounded
  batches, one phase per call, and never aborts because of a queued order. A
  record the market cannot pay stays Open (`OpenRecordPayoutSkipped`). Each
  batch fits Sui's 1,000 dynamic-field loads per transaction.
- **Exits need no authority.** Refunds and settled payouts go through `release`
  and `try_pay_settled`, which need no witness and check only the version
  floor, so they keep working while frozen and after the witness is disabled.
- **A queued fill never enters the account.** It stays an Open record until an
  early sell moves it out or the settlement payout closes it. Status moves only
  forward, except that a refunded sell returns to Open.

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
- **Exactly-once full-pool valuation, on vault-held state.** The in-flight valuation (`PoolValuation`) lives on the vault across transactions, with the `ProtocolConfig` flag (`valuation_in_progress`) engaged for its whole span. `start_pool_valuation` records the active-expiry set and commits the per-queue drain budgets; each `value_expiry` proves its market is in the snapshot and skips it if already valued (idempotent, so a permissionless caller racing the keeper cannot wedge or double-count it); `finish_flush` proves the valued set equals the snapshot. A missed or double-counted market would mis-price the pool, so the completeness proof is mandatory. Only the snapshot is privileged; `value_expiry` and `finish_flush` are permissionless once it seals. The state is released on exactly two paths: `finish_flush` (after the completeness proof and the queue drain, refused past `max_valuation_window_ms` for everyone including the operator), or a fresh `start_pool_valuation`, which discards the in-flight valuation and re-snapshots (folding stop into start). Both discard the partial NAV — frozen marks are sound only as a simultaneous set — while cash already moved by valuation settled sweeps stays (an invariant-preserving per-market move); the discard bumps the flush ordinal, so stale market stamps are lazily dropped by the next trade or settle attempt without visiting them.
- **One instant per flush.** Every live market's `Pricer` is frozen inside the single snapshot transaction — the ability-less `SnapshotStage` hot potato cannot leave it — and no later stage reads an oracle: the frozen map alone decides each market's sweep-vs-value branch and its mark. The pool NAV a flush prices, and every LP fill against it, is therefore the pool's value at one instant.
- **Post-snapshot trades cannot reach the snapshot figure.** A stamped (snapshotted-not-yet-valued) market's snapshot state is captured, not reconstructed: the stamp copies the two cash rows NAV reads at the snapshot instant, and each payout-tree node copies its boundary quantities into a shadow before its first mutation under the flush's generation (a node emptied mid-window is retained as a live-zero husk until the valuation consumes it). `snapshot_nav` is then the SAME linear walk as the live read over the captured terms — identical rounding and monotonicity contract by construction — against the captured cash, so the folded figure equals the market's NAV at the snapshot instant with no per-trade record and no trade budget. Trades after the market's valuation are invisible to the already-folded figure (as-of-snapshot either way).

## Settlement

- **Single explicit settlement transition.** `expiry_market::try_settle` is the sole
  settlement-price writer. It records exact Pyth at the market expiry when available, or exact
  Block Scholes after the 30-second Pyth-exclusive window, and exact terminal payout liability
  atomically; otherwise it returns false without changing the market. Settled consumers read no
  oracle.
- A settled order pays its full `quantity` if the settlement price is in
  `(lower, higher]`, else 0 (`strike_exposure::settle_close`).
- **R1 settlement-consistency under the tick re-encode.** Settlement compares raw
  prices against tick boundaries through one threshold tick, `prefix_limit_tick =
  ceil(settlement / tick_size)` (`range_codec`): a finite boundary at tick `t` is
  active in the prefix walk iff `t < limit_tick`, which is exactly
  `t · tick_size < settlement`. The payout-tree prefix-sum winner therefore equals
  the per-order settled-close winner — both use the same half-open `(lower, higher]`
  threshold and the same `tick_size`, so settlement equal to a higher boundary still
  wins at `higher`. `limit_tick` is a plain `u64` comparison bound (it can
  legitimately exceed `pos_inf_tick` when settlement is above the encodable range)
  and is never validated as a domain tick.
- `StrikeExposure` owns the settled phase: its settlement-price option is the phase
  discriminator, and its cached liability decreases as settled winners redeem.
  Live indexes survive until the settled-market sweep deactivates the expiry.

## Mint admission

- Raw `entry_probability` and every finite leg's probability (lower ABOVE, upper BELOW) must lie in `[min_entry_probability, max_entry_probability]`; fees are not included in these mint-only bounds, and infinite sentinels are exempt.
- `premium = entry_probability × quantity ≥ min_premium`; the holder pays this in full — there is no financed remainder.
- `all_in_cost ≤ quantity`; the complete trader debit cannot exceed the position's maximum settlement payout.

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

- Trade fee sums the independently rounded amount for each finite boundary, whose per-unit rate is `max(base_fee × √(p·(1−p)), min_fee) × expiry_fee_multiplier`. Infinite boundaries contribute zero; finite boundaries at `p ∈ {0, 1}` still pay the floor. Live-close collection is capped at redemption value.
- On a referred mint, `referral_fee = floor(referral_fee_rate × ((trading_fee − fee_incentive_subsidy) + penalty_fee))`. It is split from protocol proceeds, never added to `all_in_cost`; builder fees and inventory-impact charges are excluded. The USDC destination is the stored referrer receive address, while `OrderMinted.referrer_account_id` preserves the canonical attribution even when the calculated amount is zero.
- PLP supply and withdraw carry independent flat rates (`plp_supply_fee_rate`,
  `plp_withdraw_fee_rate`; shipped 0 and 20 bps), charged on the USDC leg
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
- A queued fill prices at the committed Pyth price for its τ and never reads the stored on-chain spot, and admission does not require that spot to be fresh. Valuation (`current_nav`, `live_order_value`, the flush snapshot) and the mint quotes accept a pricer that fell back to the Block Scholes forward, and settlement and settled redemption read no live price, so a gap in stored Pyth updates blocks neither trading, the flush, nor settlement. A gap in signed Pyth Lazer updates refunds the affected cohorts at their deadlines.
- Trading pause blocks new risk creation: queued mints abort, while early sells, commit, resolve, refunds, and settlement run. Trade flows (queued admission and fills, settled redeem) are never gated on the whole-flush valuation flag — a stamped market's snapshot state is already captured, so trades touch nothing the flush reads — but they ARE refused inside the atomic snapshot PTB (`ESnapshotInProgress`), so the keeper cannot compose a trade into its own snapshot before the seal; the flag gates fee-incentive sponsorship, LP request cancels, and most config setters; cash rebalancing runs at any time post-seal, and the mark is invariant to maintenance timing because every figure it reads — idle, the profit basis, the pending protocol cut, and each market's cash — is frozen at the seal, so no in-window move can reach it (refused only inside the still-open snapshot stage).
- The settled-market sweep is **pool-coordinated**: it returns LP cash to the pool,
  unregisters the expiry from active valuation, and materializes terminal profit —
  there is no expiry-only path that can strand capital. (The standalone compaction
  step was deleted with the dense NAV matrix; the payout tree is full-lifecycle, so
  the sweep alone suffices.)
- **Past-expiry exact-data liveness.** A market past its expiry cannot be live-valued (`pricing::load_live_pricer` refuses it), so the flush's snapshot stage refuses to stamp an expired-but-unsettled market: it must be settled (`try_settle`) before a flush can start. This preserves the single exact mark for PLP supply and withdraw; no approximate substitute mark is allowed. A market that expires *after* the snapshot is valued as-is at its frozen pre-expiry mark, and its settlement is not blocked by the flush at all — it settles the instant it expires, because the frozen mark is settlement-invariant. Because the snapshot must cover every active market, an expiry whose exact settlement data is unobtainable at both sources blocks starting the *whole* pool flush — trading continues, but every queued LP fill waits — so a permanently unobtainable settlement spot is a cross-market LP-liveness brick, not a benign wait. Guaranteeing the exact-timestamp datum is always obtainable (expiry↔publish-cadence alignment, plus the bounded Block Scholes settlement fallback) remains tracked in the open-issues tracker.

## Configuration

- Admin-tunable values have a stored field plus a `default_*` seed and an
  `chk_*` bound in `config_constants`, snapshotted per object at creation;
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
  caller's mark, haircut, or stance. `strike_exposure::marked_liab` returns
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
