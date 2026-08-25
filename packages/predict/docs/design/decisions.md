# Design decisions

The significant design decisions behind Predict — what was chosen, why, and the
main alternatives that were rejected. It complements the conceptual docs (which
explain *how* the protocol works) with the rationale for the shape it took. For
the invariants these decisions must preserve, see [invariants.md](./invariants.md).

> **Status:** pre-deploy, living record. The most recent decisions are at the end.

## Economic model

> **PARTIALLY RETIRED 2026-08-14 — leverage removed.** Retired: the first three bullets (deterministic floor, static per-order floor, pure knock-out liquidation) and "v1 scope exclusions". They describe the pre-removal floor/knock-out design; every position is now 1x, with no floor, no financed amount, and no liquidation. Kept for the decision record — see "Leverage removal" at the end of this document. **Still live:** D025 (mint-only ask band) and the adjusted-digital clamp decision, which is RP-15's design record.

- **Leverage is a deterministic floor, not a debt overlay.** A position is one
  binary (digital) contract whose live value is `range-probability value − a
  static floor`, floored at 0 (1× = zero floor); the floor is
  limited-recourse to its own order. *Rejected:* a borrow-index / normalized-debt
  overlay (leverage as a separable debt) and utilization-based borrow rates — the
  floor model keeps one contract with a static per-order floor, with no separate
  debt to track, price, or liquidate.
- **Static per-order floor.** The floor is snapshotted as `floor_shares` at mint
  and is independent of time, spot, and later admission-policy changes. Leveraged
  orders can use the same generic `(lower_tick, higher_tick]` range shape as 1x
  orders; liquidation remains mark-based against the order's current range value.
  *Rejected:* spot-dependent rates.
- **Pure knock-out liquidation.** A leveraged order is removed without paying the
  holder once it falls to/below `floor_amount / liquidation_ltv`; the holder's
  account position is the only remaining record, redeemed later for zero payout
  (the liquidated state is derived from the order's absence from the active
  index, not stored). *Rejected:* residual-paying liquidation; a stored
  tombstone table (removed as a duplicate of the account position).
- **D025 — The ask-price band applies to mint only — redeems price at the live mark.**
  The mint-time `[min_entry_probability, max_entry_probability]` band is admission policy: the protocol
  declines to become counterparty in the tail price regions where the curve is
  least reliable. Once a contract is live, redeeming at the live mark is the
  holder's right; a redeem clamp would systematically underpay legitimate
  deep-ITM winners near expiry (range probability legitimately approaches 1,
  consistent with settlement paying full quantity). *Rejected:* a symmetric
  redeem-side price band.
- **Adjusted one-sided digital prices clamp to probability bounds.** The
  pricing-safe envelope bounds each SVI parameter independently and enforces no
  butterfly/no-arbitrage condition, so an admissible surface can push the raw
  skew-adjusted digital outside `[0, 1]` by an arbitrary margin at any
  moneyness. The one-sided UP price saturates to `[0, 1]` and range differencing
  floors at zero rather than aborting live mint, redeem, or liquidation reads;
  Block Scholes guarantees its published SVI surfaces are monotone and
  butterfly-arbitrage-free (response policy RP-15).
  NAV valuation additionally rejects an active-book surface whose cached finite
  boundary UP prices are non-monotone, because the aggregate payout-tree walk
  nets signed boundary contributions across orders.
- **v1 scope exclusions.** Double-sided range leverage, a fungible "2x beta" token,
  and utilization-based financing rates are excluded from v1 — exact strike-level
  liquidation indexing requires monotonic single-sided payoffs and history-independent
  floors, which those break.

## Data structures

> **PARTIALLY RETIRED 2026-08-14 — leverage removed.** The liquidation book is deleted; only the payout tree remains, and the packed order id no longer carries floor shares or serves as a sort key. Retired: the "Two sparse strike indexes" bullet below, and the floor/sort-key clauses of the order-id bullets. Kept for the decision record.

- **The order id is a packed `u256` — the single on-chain term store.** It packs
  the durable post-mint terms (quantity, floor shares, two strike ticks,
  sequence); there is no separate order table. It is self-authenticating,
  costs zero per-order storage, and doubles as the liquidation sort key.
  *Rejected:* unpacking to a sequence + `Table<u64, Order>`.
  > *2026-08-14:* the layout is now 132 dense bits — quantity lots, two strike
  > ticks, sequence. `floor_shares` is gone and there is no liquidation sort key.
  > The rest of the decision (packed id as the single term store) still holds.
- **Mint-admission policy is kept out of the order id.** Admission caps and price
  thresholds live in config, not in order decoding, so a future policy change can
  never retroactively invalidate an existing packed id. *Rejected:* also packing the
  entry price (`entry_probability` / `leverage_rank`) into the id — `floor_shares`
  reconstructs everything needed; revisit only if a flow needs the lossless entry
  price on-chain.
  > *2026-08-14:* the rejection still stands, but its reason no longer does —
  > `floor_shares` is gone, so nothing in the id reconstructs an entry price.
  > Admission policy stays out of the id because a policy change must never
  > retroactively invalidate an existing packed id.
- **`admin` is a dependency-leaf capability module.** *Rejected:* folding
  `admin`/`AdminCap` into `registry` — it creates a Move import cycle
  (`registry → protocol_config → admin`).

- **Two sparse strike indexes, both tick-keyed.** A sparse height-balanced (AVL)
  payout tree and a flat liquidation book coexist; the exact live NAV is read by
  decomposing the per-order liability across the two (`Σ qty·P` over the tree
  minus the leveraged floor-correction scan over the book).
  *Superseded:* balancing that tree as a treap keyed on `blake2b256(bcs(tick))`.
  Boundary ticks are caller-chosen, so a rotation key derived from a tick is a
  rotation key the caller picks: depth held only in expectation over priorities
  assumed random, and a caller could search for ticks whose priorities descend as
  the ticks ascend and force a spine. Rotations key on measured subtree height,
  which bounds depth for every admissible tick set rather than for a random one.
  *Superseded:* a dense paged NAV matrix (`{quantity, floor_shares}` with
  strike-weighted prefix sums), which existed only to make every LP supply/withdraw
  a cheap synchronous read. It and its whole mitigation stack (the valuation
  liquidation pass, the verified/unscanned bucket split, the uncertainty band, the
  Q-haircut conservative-NAV thread) were deleted when LP flows went async — the
  daily flush can afford an exact brute-force valuation, so the approximation and
  everything compensating for its error are gone.
- **A flat, paged, sorted-`u256` liquidation book**, binary-searched, with a
  bounded keeper head-scan plus a rotating passive watermark; only leveraged
  orders enter. Priority is encoded by storing the quantity field's complement, so
  an ascending id sort is largest-quantity-first with no decode. *Rejected:* a
  two-level skip-tree with slack certificates; a bucketed leverage book.
- **Liquidation priority is largest-quantity-first, not most-under-floor-first.**
  The sort key lives in the immutable packed id, and an order's health changes
  with the live forward/SVI state — it cannot be a static key. Largest-first is the best
  feasible static proxy for the quantity that matters (how much a stale order can
  overstate NAV). *Rejected:* most-under-floor-first (would require re-keying the
  book whenever marks move).

## Accounting and rounding

- **Per-expiry config is snapshotted immutable at creation**, so admin changes to
  the global template never reprice live orders.
- **The contract defaults ARE the genesis values (AUD-002).** There is no separate
  launch checklist; `config_constants` defaults (`backing_buffer_lambda` 0.31, caps,
  budgets) ship as-is unless an open item changes one. Configured values live in
  [configuration.md](./configuration.md).
- **Uniform round-down math** at 1e9 scale; solvency rests on bit-identical
  reserve↔payout pairing (a reserve and its payout derive from the same quantity
  via the *identical* helper). *Rejected:* mixed ceil/floor primitives, which
  introduced super-additivity drift and were deleted.
- **D026 — Strike-quantity math stays `u64`.** A `u128` widening was tried and reverted:
  the `u64` mul ceiling is accepted because the failure mode is a graceful per-tx
  mint abort at extreme strike×quantity (never a brick), and inline `u128` casts
  duplicated `fixed_math` semantics inside a core module. *Rejected:* the widening.
- **DUSDC pools with a pool-coordinated settled-market sweep.** The sweep returns
  LP cash to the pool, unregisters the expiry from active valuation, and
  materializes terminal profit — there is no expiry-only path that can strand
  capital. *Rejected:* a monolithic single-vault model; a separate expiry-only
  path. *Superseded:* the standalone `compact_storage` compaction step, deleted
  when the dense NAV matrix it reclaimed went away — the payout tree is
  full-lifecycle, so there is no dense per-market state to compact, and the sweep
  alone returns cash and deactivates the expiry.

## Backing and solvency (recent)

- **D030 — The live cash-backing reserve is a settlement floor plus a tunable liquidity
  buffer**: `max_net_payout + λ · (Σ net_payout − max_net_payout)`, with
  `λ` (`backing_buffer_lambda`) an admin template value, default 0.31. The floor
  — the maximum summed payout at any *single* settlement price — pays every
  settlement winner in full on every price path, because exactly one price
  settles a market and ranges that share no price can never all win together.
  The buffer sizes how much *early-exit* demand beyond the floor is funded:
  Monte Carlo and real-data simulation put 95th-percentile sequential-exit demand
  across studied disjoint books at 16–33% of the gap, so the default targets the
  upper end of that range while reserving ~31% of the old requirement on many-bucket
  books. A live redeem that would breach the reserve aborts and can retry
  smaller or later; closing a position releases λ of its own backing, so exit
  liquidity cannot be monopolized by one holder. `λ = 1` reproduces the summed
  reserve exactly. *Superseded:* the summed per-order reserve (full early-exit
  liveness at ~100% capital lockup — itself a cheap capital-lockup grief, since
  ~1 unit of premium locked N units of pool cash on N disjoint buckets); the
  original bufferless single-point reserve (documented full early-exit liveness
  it did not provide).
- **No pool funding-cap earmark.** Each market's own cash covers its reserve, so
  solvency is self-contained per expiry at the floor and the pool owes no
  standing backing to live markets. The snapshotted per-expiry allocation cap remains
  the per-flow funding ceiling, and the pool sync tops every market toward its
  reserve target before an LP withdrawal pays out. *Superseded:* the idle earmark
  (`idle ≥ Σ active (max_funding − net_funding)`), which pinned the full cap of
  pool capital per active market regardless of book shape and whose backing
  duty became void under the settlement-floor guarantee.
- **Keep the payout tree.** The tree's max-net-payout term is the enforced settlement
  floor that anchors the live reserve — an O(1) root read, and the structural
  proof that any reserve ≥ it always pays in full at settlement. The same tree now
  also serves the exact NAV linear walk (`Σ qty·P` over its live boundaries), so it
  is the single full-lifecycle live index. *Rejected:* folding settlement into the
  deleted NAV matrix and dropping the tree.
- **D032 — Inventory impact is the difference of one capped book-level potential.**
  Define the risk coordinate as the existing payout liability
  `L = M + λ(T-M)`, and charge mints / rebate voluntary live closes by the signed
  change of a convex potential whose marginal rate rises linearly to
  `inventory_impact_max_rate` at `B = max_expiry_allocation`, then remains capped.
  The rate snapshots at market creation, ships at zero, and cannot exceed 1.0.
  Charges sit in an isolated escrow excluded from NAV and every ordinary fee
  basis, and settlement releases the residual. One deterministic integer state function makes trade splitting and
  every closed cross-range cycle telescope exactly. The payout tree supplies
  O(log n) in-range/complement peaks needed to compute the true marginal move in
  `M`; the implementation evaluates the complete before/after liability so
  fixed-point buffer carries are part of the state difference. *Rejected:* a
  range-local skew multiplier tied to that range's current
  probability. Its entry and exit rates can be changed by trading another range,
  so a cycle that returns the book to its starting state can extract value. Also
  rejected: live cash/NAV as `B` (trader/pool flows could move the curve under
  existing positions), uncapped quadratic marginal rates, and treating charges
  as fee revenue available for pool sweep.

## Access and operations (recent)

- **Trading-loss-rebate claims have owner and keeper paths.** *RETIRED 2026-08-18 —
  the rebate was removed; see "Staking and the trading-loss rebate removal" below.*
  `claim_trading_loss_rebate` consumed owner auth and `claim_trading_loss_rebate_permissionless`
  Predict app-auth, so a keeper cron could resolve accounts after settlement without
  blocking owner claims when `PredictApp` was deauthorized. The surviving instance of
  that pattern is `redeem_settled` / `redeem_settled_permissionless`.
- **The protocol reserve is write-only.** `protocol_reserve_balance` accrues
  protocol profit and exposes no admin withdrawal path. Decided (2026-07-21,
  predeploy RP-16): no withdraw entrypoint ships in this package — the reserve's
  eventual use (buy-and-burn, withdrawal, incentive recycling, solvency backstop)
  is deliberately undecided and the entrypoint lands with the package upgrade
  that decides it. The cut's booked-order timing property is accepted in the
  same entry. *Rejected:* an admin drain entrypoint in the launch package.
- **Account app-auth is intentionally full-account, package-level authority.** An
  app authorized through `account::AccountRegistry` can mutably load any
  `AccountWrapper` it is handed and use the normal `Account` balance/data APIs — so
  predict-user solvency depends on the account admin's app-authorization hygiene and
  every co-authorized app's honesty. *Rejected:* per-user/per-coin app scoping —
  don't add it unless a future account-margining design needs dependency-aware user
  app grants (e.g. blocking app revocation while open margin obligations require
  cross-app liquidation).

## Fees, staking, and rebates (recent)

> **RETIRED 2026-08-18 — DEEP staking and the trading-loss rebate were removed.** Every bullet in this section describes the stake-scaled loss rebate, its reserve, or the stake that gated it. None of that machinery exists: there is no `StakeConfig`, no rebate reserve, and no claim. Kept for the decision record — see "Staking and the trading-loss rebate removal" at the end of this document.

- **The staking programme ships at a zero benefit ratio, and each market freezes its whole
  benefit policy at creation.** `StakeConfig.max_benefit_ratio` scales the stake curve and
  defaults to `0`, so a market created from the shipped template pays no stake-scaled loss
  rebate. There is deliberately no boolean
  switch: "off" is just `0`, which also lets the programme run at partial strength on the way
  up. Every `ExpiryMarket` snapshots the whole config — ratio and both thresholds — at
  creation, and prices the rebate against its own copy; `set_template_max_benefit_ratio`
  and `set_template_benefit_powers` bind only markets created afterwards. *Why a scaled ratio
  and not tuned thresholds:* the `*_benefit_power` envelope has no setting that yields a zero
  benefit — the lowest admissible `lower_benefit_power` still pays a proportional rebate —
  so zero was otherwise unreachable for an admin. *Why snapshotted rather than read live:*
  the rebate resolves after the trade that earned it, at a post-settlement claim, so a
  retune would shrink or erase an already-earned rebate — measured at 2_500_000 -> 1_252_551
  for a full staker when the thresholds were widened post-trade, and the claim removes the
  account's expiry summary, so nothing could recover it. Freezing makes that unrepresentable
  rather than leaving it an operator-ordering hazard, and matches `StrikeExposureConfig`,
  which is already snapshotted per expiry for the same reason. The cost is accepted: raising
  the ratio likewise does not reach live markets, so the programme phases in over about one
  cadence period. Pinned by `settlement_flow_tests::
  retuning_the_stake_benefit_template_cannot_reprice_an_earned_rebate`. *Rejected (moot since
  the fee discount was removed — see "Stake fee-discount removal" below):* making
  `max_fee_discount` admin-tunable at zero, which would silence the fee side while leaving the
  uncapped rebate live, and would move an upgrade-required constant into tunable config.
  *Consequence:* while a market's ratio is zero, its rebate reserve still accrues at that
  market's `trading_loss_rebate_rate` and is released to the pool as the permissionless
  cleanout resolves each account after settlement, not at settlement itself (the settled sweep
  holds the reserve back). Zeroing that rate is likewise a template action, binding only
  markets created after the change.
- **Staking is a gaming-resistance gate for the loss rebate, not a reward per se.**
  The trading-loss rebate exists to move value from winners toward net losers; it
  must target *aggregate* net losers (per trader), else a balanced (50/50) book
  harvests it on its losing legs. Aggregation is sybil-gameable (one address per
  order), so the rebate is scaled by `benefit_ratio(active_stake)` — faking N loser
  accounts then costs N stakes. *Accepted limit:* stake is a refundable, plutocratic
  gate, porous to correlated/directional bundling; genuinely reaching unstaked retail
  would need off-chain identity (out of contract scope).
- **Stake benefit was applied twice, by design.** `benefit_ratio(active_stake)` scales
  both the mint-time fee discount (`× max_fee_discount`) and the settled loss rebate
  (`× trading_loss_rebate_rate`), which are independent config knobs sharing the one
  benefit curve. A high staker pays a small net fee — intended loyalty compounding, not
  a double-count bug. *Superseded 2026-08-18:* the fee discount was removed, so the curve
  now scales the loss rebate alone — see "Stake fee-discount removal" below.
- **Stake is account-global, not per-expiry.** One `active_stake` scales the rebate
  across all of an account's concurrent expiries; it is a rebate multiplier, not a
  per-market budget. It amortizes the sybil-gate cost across markets — accepted.
- **The rebate reserve is conservative by construction, and intrinsically so.** During
  a market's life the full `unresolved_trading_fees_paid × trading_loss_rebate_rate` is
  held out of NAV, because "did this trader net a loss" is unknowable until settlement,
  so the max payable must be reserved. This is the unavoidable cost of an aggregate-net-
  loss rebate; the residual (winners, unstaked, partial-benefit) returns to the pool as
  each account resolves. *Rejected:* removing the reserve (would require downgrading the
  rebate from a hard-guaranteed liability).
- **Unstaking before the cleanout forfeits a pending rebate.** The rebate reads
  `active_stake` at claim; an owner who unstakes post-settlement, pre-claim, is scaled
  to zero. Accepted (self-inflicted; the prompt incentivized sweep bounds the window).
- **`stake_deep` / `unstake_deep` carry no valuation-lock gate.** Staked DEEP is
  excluded from `lp_pool_value`, so neither can move the flush mark; gating them would
  add lock contention for no solvency benefit.

## Oracle extraction (recent)

- **The oracle moved out of Predict into the standalone `propbook` package.** The
	  in-package `MarketOracle`, `PythSource`, `settlement_state`,
	  `market_oracle_config`, `market_oracle_writer_cap`, and `oracle_events` modules
	  were deleted. Live data now comes from Predict-unaware Propbook feeds:
	  `propbook::pyth_feed::PythFeed` (one global spot per Lazer feed), a source-level
	  `propbook::block_scholes_spot_feed::BlockScholesSpotFeed`, and source-level
	  `propbook::block_scholes_forward_feed::BlockScholesForwardFeed` /
	  `propbook::block_scholes_svi_feed::BlockScholesSVIFeed` objects with per-expiry
	  rows. Each is updated permissionlessly — the design intent is that a verified
	  update is self-authenticating, so there is no writer capability (the current
	  `block_scholes_oracle` payload is an unvalidated stub until the production
	  verifier lands; see risks.md).
  *Rationale:* the oracle suite is reusable by the wider ecosystem and has a clean,
  Predict-agnostic boundary; possessing a verified `Update` is the only proof
  needed. *Rejected:* keeping the bespoke in-package oracle with an `AdminCap`-minted
  writer cap. The math package `predict_math` was renamed `fixed_math` to match its
  now-shared, Predict-unaware role.
  *Superseded (in part):* the three Block Scholes feed objects and the stub-verifier
  caveat above were retired by the signed-store cutover — see "The Block Scholes
  feeds became signed-series stores gated by the production verifier" below. The
  extraction itself, the no-writer-capability intent, and the Propbook boundary stand.
- **Ownership split: the market owns flow state, `pricing` owns oracle ingress.**
  `ExpiryMarket` stores `propbook_underlying_id` and tick size, not the current
  oracle object IDs. `pricing` validates passed feeds against Propbook's current
  canonical binding and issues either an exact-history spot read for reference
  tick and settlement or a live `Pricer` after applying liveness, freshness, and the
  pricing-safe envelope. *Rationale:* Propbook owns source identity and canonical
  binding; Predict pricing owns the only conversion from Propbook objects into
  business logic.
- **Pyth-stale/unusable is a fallback, not an abort.** Live forward is
  `pyth_spot * (bs.forward / bs.spot)` when normalized Pyth spot is present and
  fresh, else the normalized Block Scholes `forward`. The BS spot and forward must
	  be fresh under the BS price window, and SVI must be fresh under its own looser
	  window (`EBlockScholesPriceStale` / `EBlockScholesSVIStale`; an absent or
	  non-normalizable BS input aborts `EBlockScholesPriceUnavailable` /
	  `EBlockScholesSVIUnavailable` instead).
	  *Rationale:* the BS forward feed alone carries a usable forward, so a momentarily
	  stale or non-positive/unrepresentable Pyth spot should not block trading. An oversized
	  normalized Pyth spot still aborts under Predict's pricing envelope. BS spot, forward,
	  and SVI are independent Propbook feeds, so price freshness and SVI freshness remain
	  separate policy windows.
	  *Now conditional:* both statements above describe the default only. "Switchable
	  live-forward source" below made the formula an admin setting, so with
	  `use_pyth_spot_for_forward` clear the Block Scholes forward is used on every load,
	  no fresh Pyth spot re-anchors it, and an oversized normalized Pyth spot is ignored
	  rather than aborting — `EPythSpotInvalid` guards only the value the re-anchor consumes.
- **Predict does not version-gate the feeds.** The propbook feeds carry their own
  package version and a forward-only `migrate`; Predict reads them and never asserts
  their version. *Rationale:* an external, independently-upgraded package owns its
  own version policy; a stale feed caller is harmless (it just reads an old, still
  migratable feed). This removed the per-object `allowed_versions` mirror and
  `sync_*` entry that the old in-package oracle objects carried.
- **No inventory-aware mid shift.** *Rejected:* skewing the quoted mid by pool
  inventory — the aggregate drifts when the SVI surface moves and it carried an `i64`
  overflow risk (built, then fully reverted). Revisit only if the drift and overflow
  are solved AND skew is shown to help LPs.

- **The Block Scholes feeds became signed-series stores gated by the production verifier.** The three per-source feed objects and the stub `block_scholes_oracle` package were replaced by two per-underlying stores (`propbook::block_scholes_store`) keyed by the series id Block Scholes signs and written only through batch types the `bs_oracle` signature verifier mints. Holding a verified batch is the provenance proof, so relayers are untrusted. Each store pair is immutably bound to one provider base-asset spelling; typed spot, forward, and SVI ingestion derives the accepted ids through the provider-owned `bs_sid` package from the complete subscription descriptor, and forward/SVI expiry witnesses are checked through that derivation. Each observation carries the provider's model time and batch-envelope time separately, replacing on-chain change-detection that reconstructed the anchor. (Freshness and the SVI roll-down anchor originally keyed on the model time; "Pricing keys on the publish time" below moved both to the envelope time.) *Rationale:* authenticity moves from the writer to the data, closing predeploy gate S-4. *Rejected:* keeping the stub constructors behind an allowlisted writer (retains our own key custody in the trust set), and an on-chain sid→slot mapping table (a registration step per new expiry on the market-roll path; deriving the provider-defined id from immutable store identity needs no state).

## One canonical strike representation — absolute ticks (recent)

- **There is exactly one strike interpretation protocol-wide: an absolute integer
  tick from zero, `raw_strike = tick * tick_size`.** `strike_grid` (the market-local
  centered grid) was deleted and `strike_exposure/range_codec` is its replacement:
  it owns the tick→raw conversion at the pricing/settlement boundary and the
  settlement prefix threshold. Public entrypoints and events carry the
  `(lower_tick, higher_tick)` pair directly, and only the order ID packs the ticks.
  Order IDs, the payout tree, and the liquidation book
  all key on ticks; raw strikes are recovered only at the pricing/settlement
  boundary. *Rationale:* the centered origin existed only to page the deleted dense
  NAV matrix; once that was gone it just forced every order decode through
  `min_strike + index·tick_size`. Collapsing to one representation makes misaligned
  strikes unrepresentable and makes strike analytics feed-global. *Rejected:* keeping
  grid-relative boundary indices, storing raw `u64` strikes in the id (they do not
  fit), and an opaque id with a separate order table.
- **No-spot market creation.** Because the tick domain is absolute, market creation
  reads no live spot — it snapshots the cadence `tick_size` and starts with zero cash.
  `MarketCreated` carries `tick_size`, `max_expiry_allocation`, and
  `initial_expiry_cash` plus the immutable per-expiry policy snapshot, not min/max strike.
  *Rationale:* the only reason creation needed a fresh spot was to center the deleted grid; a market simply
  cannot admit risk until the normal live-pricing freshness gates pass. *Rejected:*
  re-adding a creation-time spot read purely to sanity-check the tick size against the
  asset's price scale — the tick size is sized operationally and a mismatch fails
  loud at the first mint.
- **Deep-tail pricing stays live, and it is computed rather than asserted.**
  `compute_nd2` takes log-moneyness as a difference of logarithms, `k = ln(strike) -
  ln(forward)`, so both tails price through the ordinary formula and converge on
  their limits via `d2`'s normal-CDF clamp. *Rationale:* the widened tick domain
  makes a deep tail reachable by a forward drift alone, and the NAV walk prices every
  live boundary — one unpriceable order would otherwise brick NAV, redeem, and
  liquidation for the whole market until settlement. The `[min_entry_probability,
  max_entry_probability]` admission band, not an abort, is what keeps the protocol
  from writing a tail it prices poorly. *Superseded:* the original form computed
  `strike/forward` as a fixed-point ratio and short-circuited to the exact digital
  limits when that quotient floored to zero or left `u64`. Those limits hold only
  while total variance is small, and the branch returned them without reading the
  surface, so a high-variance surface was mispriced by up to 100% in either
  direction — `predeploy/response-policies.md` RP-26. Removing the ratio removed the
  need for the shortcut. *Rejected:* a standalone reject-at-mint strike-range guard
  (redundant with the ask band on mint, and it would not cover redeem / NAV /
  liquidation, which re-price already-minted orders with no band); and bounding the
  SVI envelope so the shortcut became exact (no envelope that admits arbitrage-free
  surfaces can — RP-26).

## Async LP, exact NAV, and the privileged flush (recent)

- **LP supply/withdraw is asynchronous; the daily flush values the pool exactly.**
  LPs queue escrowed `request_supply`/`request_withdraw` (cancellable for an
  immediate refund, with request-time minimum-output limits), and a daily flush
  fills eligible queued heads at one frozen mark.
  *Rationale:* moving valuation off the trading hot path lets the flush afford an
  exact brute-force NAV, which deletes the entire approximate-NAV mitigation stack;
  the cost is a ~24h LP settlement delay. *Rejected:* an operator-posted NAV (this is
  a trustless on-chain crank) and a flush that pauses trading. A multi-tx crank was
  rejected here on the premise that it forfeits the single exact mark; the staged
  flush (below) overturned that rejection by freezing every market's pricer in one
  atomic snapshot and cancelling concurrent trades out of the valuation, which keeps
  the one exact mark the rejection existed to protect. Re-reading the oracle per
  valuation transaction stays rejected.
- **`current_nav` is the exact per-expiry mark — one mark, no band.** Per expiry,
  `current_nav = free_cash − live_marked_liability`, floored at zero, where the
  liability is the payout tree's boundary-linear walk alone, with no per-order
  correction (leverage was removed — see "Leverage removal" below). The flush
  prices supply *and* withdraw at the single `pool_nav = idle + Σ current_nav` (net of
  the pending-protocol-profit exclusion). *Rationale (audit L10):* one mark used in
  both directions must equal true recoverable value, so it must be exact — a
  conservative band would over-mint on one side or over-pay on the other. The
  supply-mark-≥-true directional invariant is satisfied with equality. *Superseded:*
  the optimistic supply mark + uncertainty-band withdraw fee of the approximate-NAV
  world.
- **The flush is privileged (cron-driven), not permissionless (audit L8).** Only a
  market-deployer `MarketLifecycleCap` (`start_pool_valuation`) may start a flush; the
  root-`AdminCap` flush path was removed (the flush is routine maintenance and should
  not ride the irrevocable root cap — admin keeps break-glass by minting itself a
  revocable lifecycle cap). The flush prices off the live oracle and Pyth updates are
  permissionless, so a flush-capable holder who manipulated the live oracle in a
  preceding tx could fill their own queued request at a mark they chose. *Rationale:*
  the cap-holder is trusted not to manipulate the oracle, and the cap is revocable
  (bounded blast radius, better key hygiene than the root cap). NAV manipulation is
  closed by privileging the start; dilution by the fair FIFO drain at the frozen mark.
  *Rejected:* a permissionless flush.
- **Cash maintenance is decoupled from the flush.** Cash rebalance and the
  settled-market sweep are standalone, permissionless, per-market entrypoints; the
  flush alone carries the exactly-once-per-market completeness proof (its snapshot
  stage's hot potato enforces only the one-transaction snapshot). *Rationale:* each
  maintenance op is per-market local and invariant-preserving, so it needs neither
  the completeness proof nor the valuation flag; keeping exits responsive
  (rebalance) must not wait for the daily flush. *Rejected:* a mode flag on one
  shared potato; two potatoes.

## Resumable lock-free flush (2026-08-24)

- **Valuation is resumable across transactions; the mark is frozen atomically and
  concurrent trades are cancelled out (RP-29 resolves C-1).** The flush's snapshot
  stage — one atomic PTB under a `SnapshotStage` hot potato — freezes every live
  market's `Pricer`, stamps those markets, and records each LP queue's eligibility
  cutoff; valuation then runs one market per transaction, reconstructing each
  market's snapshot-instant NAV by rolling recorded trade deltas back off the live
  rows (bit-identical walk rounding; deleted boundaries price from the delta log);
  `finish_flush` drains only pre-snapshot requests. *Rationale:* the joint object
  budget C-1 measured is gone by construction while trading never pauses — the
  original "flush that pauses trading" rejection above stands, and the exact-mark
  requirement (audit L10) survives because exactness is defined at the snapshot
  instant and reconstruction is exact. *Rejected:* a cross-transaction valuation
  lock over the whole mutation surface (pauses all trading for the window and turns
  a dead keeper into a protocol-wide pause); an approximate or banded mark (audit
  L10); per-market progressive locking (still pauses each market for the flush
  tail, at most of the review cost of corrections).
- **Duty inventory for the dropped whole-flush potato.** *Snapshot atomicity* —
  kept, type-enforced by `SnapshotStage`. *Completeness* — kept: sealing requires a
  frozen entry per expected market, finishing requires every expected market
  valued. *Authorization* — kept via `started_by`: only the starter values and
  finishes; there is deliberately no permissionless completion, only
  permissionless discard past `max_valuation_window_ms`. *Lock releases
  in-transaction* — surrendered for the valuation stage only, and what the flag
  now gates across transactions is fee-incentive sponsorship, config, and LP
  cancels — never trading, maintenance, or market creation (a new market sits
  outside the flush's frozen expected set and joins the next snapshot). *Vault binding* — unrepresentable (the
  valuation lives on the vault).
- **LP cancels are gated during a flush; new requests are not.** The frozen mark
  is on-chain readable once the snapshot lands, so an ungated cancel of an
  eligible request is a free option against a stale price; new requests are
  quarantined by the recorded queue cutoffs instead of a gate. *Rejected:* gating
  requests too (needless — the cutoff is airtight and keeps the queue live).
- **Cash maintenance runs mid-flush, compensated on every mark term.** An
  in-window live top-up or surplus sweep records on the pending market's stamp
  (so `snapshot_nav` rolls it back with the trades and the zero floors see no
  unrecorded movement) and on two flush accumulators that `finish_flush` reverses
  out of idle AND the profit basis's credits and debits, so the mark is invariant
  to maintenance timing. *Rationale:* gating the rebalance for the window left a
  market that exhausted its buffer mid-flush unable to admit mints or closes
  until the flush landed — exits paying for a purity gate — and a gross-only
  compensation would misprice the mark by the protocol profit share of every
  moved amount, so all three terms are corrected together. Settled sweeps stay
  uncompensated: a swept market contributes zero and idle is its recoverable
  cash's counted location. *Rejected:* gating `rebalance_expiry_cash` for the
  window (the exit-freeze above); compensating gross alone (mispriced by
  `share × moved`); a starter-gated maintenance entrypoint (needless — with the
  compensation the mark cannot be moved by rebalancing, so permissionless
  maintenance has no lever).
- **Settlement is gated per market, not globally.** `try_settle` refuses only a
  market whose stamp names the in-flight flush — the frozen sweep-vs-value branch
  and the recorded deltas are only sound while settlement cannot reclassify the
  rows. A market expiring mid-window is valued at its frozen pre-expiry mark and
  settles the moment its stamp clears (RP-29 ratifies this against RP-4's
  original blanket block).

## Explicit exact-timestamp settlement (recent)

- **Settlement is one public permissionless transition.** `expiry_market::try_settle`
  consumes pricing's canonical exact-history selection and calls
  `StrikeExposure::record_settlement`, which stores the terminal price and exact
  remaining payout liability together. The exposure's settlement-price option is
  the phase discriminator; settled redeem, pool rebalance, and valuation
  consume only that recorded phase. Keepers compose settlement first in the same PTB
  when needed. *Rationale:* one writer makes the market phase transition atomic,
  keeps price and book liability under one owner, and removes oracle ingress from
  every later settled consumer. *Rejected:* implicit settlement inside each consumer.
- **Pyth is exclusive for 30 seconds, then Block Scholes is an exact fallback.** Every settlement attempt reads exact Pyth first. At or after `expiry + 30_000`, Pyth absence permits the exact Block Scholes spot at the same timestamp; missing, zero, or over-wide fallback values return false. After the grace boundary the first successful transaction is final, so Block Scholes may win before a Pyth row that lands later; `MarketSettled` records the source. *Rationale:* the second independent exact source bounds the former Pyth-only permanent flush brick without admitting latest, nearest, interpolated, or administrative prices. *Rejected:* an admin settlement lever and approximate boundary lookup.
- **Expired-unsettled cash maintenance is a no-op.** A standalone rebalance after
  expiry moves no cash until `try_settle` succeeds; valuation still aborts through
  live-pricing expiry. *Rationale:* live cash targets have no purpose after expiry,
  while an unsettled market has no exact terminal liability from which to sweep.
- **Accepted consequence: exact-data liveness.** If both exact sources are missing
  after expiry, the market remains unsettled and live valuation aborts.
  *Rationale:* there is no solvency-safe NAV for a past-expiry-but-unsettled market —
  the single flush mark needs a true value that is settlement-dependent and undefined
  until the exact timestamp spot exists. Substituting contribute-0 dilutes incumbents
  on supply while free-cash over-pays withdrawals. *Rejected:* an approximate
  substitute mark for the unsettled market.

## Single version watermark on ProtocolConfig (recent)

- **One monotonic watermark replaces the per-object `allowed_versions` set + mirrors.**
  Versioning collapsed from `Registry.allowed_versions` (authoritative set) plus
  permissionlessly-synced `ExpiryMarket`/`PoolVault` mirrors to a single
  `ProtocolConfig.version_watermark`. A gated flow asserts
  `current_version!() >= version_watermark`. `ProtocolConfig` is threaded into every
  gated public entrypoint and was already present in nearly all of them, so this
  removed N copies of one fact, the cross-module gate call, and the `sync_*` surface.
  *Rejected:* keeping the set-of-versions scheme (non-contiguous support was never
  used; only a floor is needed) and carrying the watermark on `Registry` (it is not
  present on the trade/pool hot paths, unlike `ProtocolConfig`).
- **The setter derives the floor from the running binary, never an input.**
  `bump_version_watermark` takes no target — it advances the watermark to the
  compiled-in `current_version!()`. *Rationale:* the floor can only ever move to a
  version a published binary embeds, so admin can never set it above the running
  package and brick it; retiring old versions requires executing the bump from the
  upgraded package. *Rejected:* `set_version_watermark(value)` — an arbitrary value
  above the current version is a pure footgun (recoverable only by upgrade).
- **Monotonic, so version-disable is one-way.** The watermark cannot be lowered; a
  disabled running version is recovered by upgrading, not by re-enabling. The
  PauseCap version-disable path was removed — reversible emergencies are covered by
  `trading_paused` / `mint_paused` and the protocol-wide freeze (below).
- **A reversible protocol-wide freeze gives the version-disable blast radius without
  an upgrade.** `frozen` on `ProtocolConfig`, checked inside `assert_version`, halts
  every version-gated flow (mint, redeem, settlement, valuation, LP flush/supply/
  withdraw) when set; force-on via `PauseCap` (`registry::freeze_protocol_pause_cap`),
  lifted only by `AdminCap` (`set_frozen`, deliberately ungated so a freeze is never
  unrecoverable-without-upgrade). It reuses the watermark's blast radius by folding
  into the one gate (zero new call sites) but is reversible, where a version-disable
  recovers only by upgrade; account-package custody withdrawals and builder-fee
  claims stay ungated, so already-credited custody balances and earned builder fees
  remain withdrawable while frozen (unredeemed positions and pending LP-queue escrow
  are frozen until admin lifts it). *Rejected:* freezing via
  `bump_version_watermark` (it cannot set the floor above the running version, so it
  cannot freeze the current version at all, and relaxing its advance assert reopens a
  downgrade through an old package); and a one-way upgrade-to-resume freeze (it
  reimposes the upgrade cost the freeze exists to remove). Recorded RP-18; disclosed
  in `docs/risks.md`.
- **Gate placement is uniform: line 1 of every public `&mut` entrypoint, nowhere
  else.** Internal `*_internal`/`*_inner` cores do not re-gate (the public caller
  owns it), and the watermark setter + kill switches + revocations are the documented
  ungated bypasses. *Rationale:* "is this gated?" becomes a one-line grep instead of
  a delegation trace. The admin `ProtocolConfig` setters and the registry creation
  entrypoints were brought under the gate; per-account custody and builder-code
  config stay ungated so user exits survive a freeze.
- **Three deliberate pause/valuation-gate exemptions.** `rebalance_expiry_cash`'s grow
  direction (`top_up_live_expiry_cash`) is NOT trading-pause-gated — pause blocks risk
  creation at the mint gate, while top-up only backs existing exposure and keeps exits
  fundable (gating it could starve redeems mid-emergency). `plp::lock_capital` carries
  no valuation-lock gate — it is legal only at `total_supply == 0` (both LP request
  entrypoints abort `ENotBootstrapped` until supply > 0), so nothing the lock protects
  can exist when it runs.

## Near-expiry leverage block (recent)

> **RETIRED 2026-08-14 — leverage removed.** There is no leverage to originate or block; every position is 1x regardless of time to expiry. Kept for the decision record.

- **Leverage origination stops entirely inside a window before expiry.** Within the
  expiry's snapshotted `no_leverage_window_ms` the mint-admission cap is exactly 1x,
  regardless of entry probability. Near expiry a contract's probability can move far
  in a single tick, which can carry a leveraged order past its knockout before
  liquidation can fire — the LP absorbs that gap, so leverage is riskiest exactly
  where it is least useful.
  *Rejected:* a linear taper of the cap down to 1x at expiry. The taper's case was
  that a hard cutoff concentrates max-leverage opens just before the boundary, but
  both designs gate origination only — a position opened before the window carries
  full leverage into expiry either way — so the taper does not actually remove that
  incentive, and it prices a range of near-expiry leverage the block simply declines
  to originate.
- **The block replaces the low-probability curve inside the window, rather than
  scaling it.** The cap is 1x flat, not `1 + (max - 1) * risk_curve * taper`, so the
  policy reads as one sentence and the window is the only thing to reason about near
  expiry.
- **Admin-tunable per template, snapshotted per expiry, `0` disables.** It is a
  contract term like `max_admission_leverage`: future markets pick up a new value,
  live markets keep the one they snapshotted, so an admin cannot retroactively
  change a live market's economics. `0` is a deliberate escape hatch, mirroring how
  `expiry_fee_max_multiplier = 1x` disables the fee ramp.
- **Origination only; no repricing and no forced deleveraging.** Admitted orders keep
  their frozen floor `F` and their terms, and closing / liquidation / settlement are
  untouched. Reducing risk on positions already open into the window would need a
  different lever (e.g. a near-expiry `liquidation_ltv` tightening), not an admission
  gate.
- **This does NOT resolve O-1, and O-1 is not one of its arms.** O-1's exploit is a
  *1x buy-and-hold* of systematically underpriced contracts in `[0.60, 0.95)`
  (`evidence/o1-oracle-calibration.md`: +0.05 per contract at 0% fee, confirmed
  on-chain), and unleveraged minting stays open inside the window by design — so the
  mispricing edge itself is untouched. What the block removes is the leverage
  *amplifier* on that edge: across O-1's own price range the admission cap is
  ~2.8-3.0x, so leverage roughly tripled the exploit's return on capital and now does
  not. O-1's stated mitigations remain recalibrating the near-expiry surface or
  blocking the affected market shape outright; it stays OPEN, and near-expiry markets
  are still gated on it. Bounding the residual 1x exposure is a separate decision.

## Switchable live-forward source (recent)

- **The live-forward formula is an admin setting, not a hard-coded choice.**
  `PricingConfig.use_pyth_spot_for_forward` selects between carrying the Block
  Scholes basis on the fresh Pyth spot (`pyth_spot × bs.forward / bs.spot`, the
  default and the prior fixed behaviour) and using the Block Scholes forward
  directly. *Rationale:* off-chain calibration work reports the Block Scholes
  forward as the more accurate input (not yet recorded under
  `predeploy/evidence/` — treat it as a working result, not a measured one), but
  two facts block adopting it outright — settlement is Pyth-exclusive for 30 seconds and
  Pyth-preferred afterward but can finish from Block Scholes, so either live source can differ
  from the terminal source; and the Pyth spot's freshness advantage over the
  Block Scholes forward has never been measured against that accuracy gap. Colocation and other latency work can move that
  comparison, so the choice has to stay reversible from data rather than be
  frozen by a package upgrade. This does not supersede the Pyth-stale fallback
  decision above: under the default setting that fallback is unchanged, and with
  the setting off there is nothing to fall back from. It does narrow that entry's
  one sub-claim that an oversized normalized Pyth spot "still aborts under
  Predict's pricing envelope" — `EPythSpotInvalid` guards the value the re-anchor
  consumes, so with the setting off an oversized print is ignored along with every
  other Pyth print instead of aborting.
- **One global switch, live-read, valuation-locked.** It sits in `PricingConfig`
  with the freshness windows rather than in the per-expiry template snapshot, so
  it is not a contract term and it moves for every market at once — the same
  reasoning that makes the freshness thresholds live. The setter carries
  `assert_not_valuation_in_progress`, so a single flush marks every market against
  one formula. *Rejected:* a per-market or per-expiry selector, which would let two
  live markets on the same underlying disagree about the forward and produce a
  mixed pool NAV for no calibration benefit.
- **D031 — No cross-source deviation guard comes with it.** Flipping the setting can move
  every live mark by the current Pyth-vs-Block-Scholes divergence. Nothing bounds
  that divergence directly: the envelope bounds each formula's inputs, and the
  re-anchored forward is deliberately not re-checked against it (its own bound is
  the basis factor, `forward <= 100 × pyth_spot`). Adding a band here would
  reintroduce exactly the state-triggered abort over an externally-controlled
  variable that response policy RP-5 removed. Disclosed in `docs/risks.md` instead.
- **Pricing keys on the publish time; the model time is calibration identity.**
  Freshness for all three Block Scholes reads, the SVI roll-down anchor, and the
  timestamps snapshotted onto the `Pricer` for trade events all key on each
  stored observation's signed batch-envelope time (`source_timestamp_ms`), which
  advances on every provider flush including retransmissions of an unchanged
  value; the model time stays on the stored observation and its ingestion
  events. This implements the provider contract: the model timestamp is
  re-derived roughly every 20 seconds, and an SVI publish whose model time is
  unchanged carries the same calibration already rolled down to its new publish
  time — duplicate SVI retransmission does not exist — so every publish carries
  values valid as-of that publish, a republication re-anchors the roll-down and
  refreshes the tuple, and pricing halts only when envelopes stop arriving
  (stopped transport).
  The store additionally refuses to move a series' stored envelope time backwards
  (`propbook::block_scholes_store::apply`), since a regressed anchor would stretch
  the roll-down horizon and understate rolled `a`/`b`. *Supersedes* the
  model-time keying in "The Block Scholes feeds became signed-series stores"
  above. *Rationale:* the provider's `a`/`b` describe the horizon remaining at
  publish; anchoring on the earlier model time systematically under-scaled them
  whenever publish lagged calibration, and model-keyed freshness halted pricing
  on quiet-but-alive feeds (`docs/risks.md` § stopped transport carries the
  residual trust cost). *Rejected:* keying freshness on the envelope while
  anchoring on the model time — since published values are already
  provider-rolled to the publish, a model anchor would apply that discount a
  second time — and an
  envelope-first store ordering (newest envelope always wins — order-independent,
  but lets a later envelope roll a series' model data back; the envelope floor
  keeps the model-first ordering and accepts first-writer-wins for the degenerate
  publish-stream-regression case instead).

## Leverage removal (2026-08-14)

- **Leverage, the static floor, and knock-out liquidation are removed entirely.** Every position is 1x: live value is `quantity × range_probability`, and a winning position settles for its full `quantity`. There is no floor, no financed amount, no liquidation book, no knock-out threshold, and no near-expiry leverage-admission window. *Rationale:* leverage's risk surface — the liquidation book, the NAV floor correction, the bounded liquidation sweep folded into mint and live redeem, the probability-sensitive admission cap, and the near-expiry block — was disproportionate to its value pre-launch; removing it collapses NAV to a single boundary-linear walk and deletes an entire class of keeper-timeliness risk. *Superseded:* every leverage/floor/knock-out decision above in "Economic model", "Data structures", and "Near-expiry leverage block", retired in place rather than deleted, per the response-policy register's RETIRED convention (RP-17).
- **Mint admission is an entry-probability band plus a minimum premium.** `strike_exposure_config::assert_mint_admission` requires `entry_probability` inside `[min_entry_probability, max_entry_probability]` and `premium = entry_probability × quantity >= min_premium`; the holder pays the contract's full entry value, so premium equals entry value. *Rejected:* keeping the admission machinery as a dead 1x-only code path — deleting it removes the liquidation book's guard surface entirely rather than leaving it unreachable.
- **NAV is the payout tree's boundary-linear walk alone.** `current_nav = free_cash − walk_linear(pricer)`, floored at zero. `walk_linear` still prices every boundary; what is gone is the `correction_value` term, the liquidation-book scan, and the price memo. The non-monotone-surface guard moved with the memo's deletion, from `pricing::ENonMonotonePriceMemo` to `strike_payout_tree::ENonMonotonePrice`, and is still enforced at every boundary (RP-15).

See `predeploy/response-policies.md` RP-27 for the guard-duty inventory this removal required.

## Stake fee-discount removal (2026-08-18)

- **DEEP stake no longer discounts the trading fee.** `stake_config::fee_amount_after_discount` and the `constants::max_fee_discount` cap are deleted; mint and live redeem charge the fee `StrikeExposureConfig` computes, and neither path reads `active_stake` any more. *Rationale:* the discount was the half of the staking programme that had to be priced into every trade — it made the trading fee account-dependent, so the quote surface had to expose an account-aware variant whose answer went stale on an epoch boundary, and it forced the redeem path to clamp the fee before discounting so a discounted staker could not net exactly zero. Both benefits shipped at `max_benefit_ratio = 0`, so removing the fee side costs no live behavior and leaves one benefit to reason about. *Rejected:* keeping the discount at a zero cap — an unreachable multiplier through the hottest path in the protocol is still surface a reader and an auditor must clear.
- **`benefit_ratio` survives, scaling the settled loss rebate alone.** `StakeConfig`, its two-segment curve, the per-market snapshot, and the template setters are unchanged; only the fee consumer is gone. Stake, the epoch rollover, and the rebate claim behave exactly as before. *Consequence:* a fee quote is now the same for every account holding the same builder-code state, and `quote_mint_for_account` differs from the anonymous quote only by the builder fee. *Superseded 2026-08-18:* staking and the rebate were then removed entirely — see "Staking and the trading-loss rebate removal" below.
- **The fee-side pinning tests were dropped, not migrated.** `quote_mint_tests` lost the two tests whose subject was the discount (the mint-side snapshot freeze and the stale-quote/rolled-quote pair); the market-snapshot freeze remains pinned on the rebate side by `settlement_flow_tests::retuning_the_stake_benefit_template_cannot_reprice_an_earned_rebate`, and `stake_config_tests` now exercises the curve through `rebate_amount`. *Superseded 2026-08-18:* both surviving pins were deleted with the rebate itself — see "Staking and the trading-loss rebate removal" below.

RP-11's late-stake reasoning changed with this removal — the rebate is now the whole of staking's value rather than half of it, so the epoch activation gate is the only bound left on the late-stake leak. The register entry carries the updated reasoning and reopen condition.

## Staking and the trading-loss rebate removal (2026-08-18)

- **DEEP staking and the trading-loss rebate are removed entirely.** `stake_deep` / `unstake_deep`, the pool's `staked_deep` custody, the account's active/inactive stake split and its lazy epoch roll, `StakeConfig` and its two template setters, the rebate reserve and its `trading_loss_rebate_rate` (with the whole `ExpiryCashConfig` it was the only field of), both rebate-claim entrypoints, and the `DeepStaked` / `DeepUnstaked` / `TradingLossRebateClaimed` events are all deleted. *Rationale:* the rebate was the last surviving staking benefit after the fee discount went (see "Stake fee-discount removal"), and it is a mechanism the protocol ships disabled — `max_benefit_ratio` is `0`, so no market pays it. What it did cost, unconditionally, was solvency-critical surface: a second term in the expiry cash-backing invariant, a per-account per-expiry summary table with a claim as its only reaper, a permissionless claim flow whose economics needed their own gas measurements, and a one-shot claim whose ordering against settlement, unstaking, and the settled sweep had to be reasoned about. Removing it is the largest single reduction in tail-state surface available before the deploy freezes the ABI. *Rejected:* keeping the rebate without stake scaling — the stake was the sybil gate that made an aggregate-net-loss rebate targetable at all (a rebate paid at the flat rate to every address is farmable one address per order), so an unstaked rebate is a different and worse mechanism, not a smaller one.
- **The expiry cash-backing invariant is now payout liability plus the inventory-impact escrow.** `required_cash = payout_liability + inventory_impact_reserve`; `free_cash` nets out the escrow alone. The settled sweep therefore returns all free cash at settlement instead of holding a per-account reserve back until a keeper resolves it, and an expiry no longer strands cash waiting on a cleanout.
- **`ExpiryTradingSummary` is deleted with the rebate, not kept for its position count.** The summary's other three fields (fees paid, gross paid, gross received) existed only to price a rebate, and its open-position count only gated the claim. Its row was created lazily per account per expiry and removed by the claim, so keeping the table without the claim would leak one row per account per expiry forever. Position state is the `positions` table, which is complete on its own. *Consequence:* `expiry_position_count` and `trading_fees_paid` are gone from the public read surface.
- **`MarketCreated` no longer carries `trading_loss_rebate_rate`, `max_benefit_ratio`, or the two `*_benefit_power` thresholds.** The market policy snapshot keeps the strike-exposure terms only. Off-chain consumers of those four fields must be updated with this change.

`predeploy/response-policies.md` RP-11 is retired by this removal; the register carries the retirement note.

## Mint referral fee distribution (2026-08-21)

- **Referral rewards redistribute protocol proceeds without changing mint quotes.** A referred mint sends `referral_fee_rate × ((trading_fee − fee_incentive_subsidy) + penalty_fee)`, rounded down, to the referring Account. Builder fees remain an add-on owned by the builder, while inventory-impact charges remain isolated escrow; neither enters the referral basis. `MintQuote` remains the trader-payment decomposition because referral distribution does not change `all_in_cost`.
- **The referral rate is live protocol config.** `ProtocolConfig.referral_fee_rate` defaults to 10%, accepts 0% through 25%, and is read on every mint. Accounts and expiry markets do not snapshot it, so an admin update applies to subsequent mints protocol-wide.
- **Account stores identity and payment routing separately.** Referral creation snapshots the existing referrer's canonical Account ID for attribution and its outer wrapper receive address for `balance::send_funds`. The relation is immutable, direct, and one level. A newly created Account cannot refer to itself because its referrer must already exist and the registry permits one canonical Account per owner; common beneficial ownership across distinct owner addresses is not checked.
- **Mint events preserve attribution when payment is zero.** `OrderMinted` reports the calculated referral amount and the stored canonical referrer Account ID independently, so a zero rate or rounded-zero amount does not erase the referral relation from the event stream.
