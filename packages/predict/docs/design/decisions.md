# Design decisions

The significant design decisions behind Predict — what was chosen, why, and the
main alternatives that were rejected. It complements the conceptual docs (which
explain *how* the protocol works) with the rationale for the shape it took. For
the invariants these decisions must preserve, see [invariants.md](./invariants.md).

> **Status:** pre-deploy, living record. The most recent decisions are at the end.

## Economic model

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
  holder once it falls to/below `floor_amount / liquidation_ltv`; a tombstone
  persists until the holder redeems and clears it. *Rejected:* residual-paying
  liquidation.
- **The ask-price band applies to mint only — redeems price at the live mark.**
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
  skew-adjusted digital outside `[0, 1]` by an arbitrary margin at any moneyness
  (open-items P-11). The one-sided UP price saturates to `[0, 1]` and range
  differencing floors at zero rather than aborting live mint, redeem, NAV, or
  liquidation reads; surface quality is the Block Scholes feed's responsibility.
- **v1 scope exclusions.** Double-sided range leverage, a fungible "2x beta" token,
  and utilization-based financing rates are excluded from v1 — exact strike-level
  liquidation indexing requires monotonic single-sided payoffs and history-independent
  floors, which those break.

## Data structures

- **The order id is a packed `u256` — the single on-chain term store.** It packs
  the durable post-mint terms (quantity, floor shares, two strike ticks,
  sequence); there is no separate order table. It is self-authenticating,
  costs zero per-order storage, and doubles as the liquidation sort key.
  *Rejected:* unpacking to a sequence + `Table<u64, Order>`.
- **Mint-admission policy is kept out of the order id.** Admission caps and price
  thresholds live in config, not in order decoding, so a future policy change can
  never retroactively invalidate an existing packed id. *Rejected:* also packing the
  entry price (`entry_probability` / `leverage_rank`) into the id — `floor_shares`
  reconstructs everything needed; revisit only if a flow needs the lossless entry
  price on-chain.
- **`admin` is a dependency-leaf capability module.** *Rejected:* folding
  `admin`/`AdminCap` into `registry` — it creates a Move import cycle
  (`registry → protocol_config → admin`).
- **Two sparse strike indexes, both tick-keyed.** A sparse payout treap
  (quantity + floor-share prefixes, deriving net payout) and a flat liquidation
  book coexist; the exact live NAV is read by decomposing the per-order liability
  across the two (`Σ qty·P` over the tree minus the leveraged floor-correction
  scan over the book).
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
  launch checklist; `config_constants` defaults (`backing_buffer_lambda` 0.25, caps,
  budgets) ship as-is unless an open item changes one. Configured values live in
  [configuration.md](./configuration.md).
- **Uniform round-down math** at 1e9 scale; solvency rests on bit-identical
  reserve↔payout pairing (a reserve and its payout derive from the same quantity
  via the *identical* helper). *Rejected:* mixed ceil/floor primitives, which
  introduced super-additivity drift and were deleted.
- **Strike-quantity math stays `u64`.** A `u128` widening was tried and reverted:
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

- **The live cash-backing reserve is a settlement floor plus a tunable liquidity
  buffer**: `max_net_payout + λ · (Σ net_payout − max_net_payout)`, with
  `λ` (`backing_buffer_lambda`) an admin template value, default 0.25. The floor
  — the maximum summed payout at any *single* settlement price — pays every
  settlement winner in full on every price path, because exactly one price
  settles a market and ranges that share no price can never all win together.
  The buffer sizes how much *early-exit* demand beyond the floor is funded:
  Monte Carlo and real-data simulation put worst-case sequential-exit demand on
  disjoint books at 16–33% of the gap (95th percentile), so the default covers
  it with margin while reserving ~30% of the old requirement on many-bucket
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

## Access and operations (recent)

- **Trading-loss-rebate claims have owner and keeper paths.**
  `claim_trading_loss_rebate` consumes owner auth; `claim_trading_loss_rebate_permissionless`
  uses Predict app-auth so a keeper cron can resolve accounts after settlement.
  Intentional: post-settlement cleanout must not depend on each user acting, but
  deauthorizing `PredictApp` should stop keeper automation without blocking owner
  claims. *Accepted residual (now measured — predeploy RP-11):* a keeper resolves at
  the claim-time active-stake snapshot, but the ~24h stake-activation gate makes
  gaming that snapshot structurally unreachable on the sub-epoch cadences (1m/5m/1h),
  and the permissionless cleanout is self-incentivized (negative net gas — a searcher
  is paid the storage rebate to run the redeems and the claim, standalone or bundled),
  so accounts resolve without relying on a protocol cron.
- **The protocol reserve is write-only.** `protocol_reserve_balance` accrues
  protocol profit and exposes no admin withdrawal path. Intentional for now — the
  reserve is left in the protocol backing solvency, and an explicit admin
  withdrawal flow can be added later if it is needed. *Rejected (for now):* an
  admin drain entrypoint. Whether to ship a withdrawal path pre-deploy is still an
  open decision — tracked as predeploy `open-items.md` P-8.
- **Account app-auth is intentionally full-account, package-level authority.** An
  app authorized through `account::AccountRegistry` can mutably load any
  `AccountWrapper` it is handed and use the normal `Account` balance/data APIs — so
  predict-user solvency depends on the account admin's app-authorization hygiene and
  every co-authorized app's honesty. *Rejected:* per-user/per-coin app scoping —
  don't add it unless a future account-margining design needs dependency-aware user
  app grants (e.g. blocking app revocation while open margin obligations require
  cross-app liquidation).

## Fees, staking, and rebates (recent)

- **Staking is a gaming-resistance gate for the loss rebate, not a reward per se.**
  The trading-loss rebate exists to move value from winners toward net losers; it
  must target *aggregate* net losers (per trader), else a balanced (50/50) book
  harvests it on its losing legs. Aggregation is sybil-gameable (one address per
  order), so the rebate is scaled by `benefit_ratio(active_stake)` — faking N loser
  accounts then costs N stakes. *Accepted limit:* stake is a refundable, plutocratic
  gate, porous to correlated/directional bundling; genuinely reaching unstaked retail
  would need off-chain identity (out of contract scope).
- **Stake benefit is applied twice, by design.** `benefit_ratio(active_stake)` scales
  both the mint-time fee discount (`× max_fee_discount`) and the settled loss rebate
  (`× trading_loss_rebate_rate`), which are independent config knobs sharing the one
  benefit curve. A high staker pays a small net fee — intended loyalty compounding, not
  a double-count bug.
- **Stake is account-global, not per-expiry.** One `active_stake` scales benefits
  across all of an account's concurrent expiries; it is a discount multiplier, not a
  per-market budget. It amortizes the sybil-gate cost across markets — accepted, same
  as the fee discount.
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
- **Ownership split: the market owns flow state, `pricing` owns the live oracle
  boundary.** `ExpiryMarket` stores `propbook_underlying_id` and tick size, not the
  current oracle object IDs. Every priced flow asks `pricing::load_live_pricer` to
  validate the passed feeds against Propbook's current canonical binding, reject a
  past-expiry live price, apply freshness and Predict's pricing-safe envelope, and
  return a value-typed `Pricer`. *Rationale:* Propbook owns source identity and
  canonical binding; Predict pricing owns the only conversion from Propbook objects
  into business logic.
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
- **Deep-tail pricing saturates, it does not abort.** `compute_nd2` computes
  `strike/forward` in `u128` and saturates both tails (deep-ITM up tail → ~1.0, the
  `neg_inf` limit; deep-OTM up tail → 0) instead of aborting on underflow or wrapping
  the `u64` cast. *Rationale:* the widened tick domain makes a deep tail reachable by
  a forward drift alone, and the NAV walk prices every live boundary — one
  unpriceable order would otherwise brick NAV, redeem, and liquidation for the whole
  market until settlement. Saturation keeps those reads live; the `[min_entry_probability, max_entry_probability]`
  admission band, not an abort, is what keeps the protocol from writing a tail it
  prices poorly. *Rejected:* a standalone reject-at-mint strike-range guard (redundant
  with the ask band on mint, and it would not cover redeem / NAV / liquidation, which
  re-price already-minted orders with no band).

## Async LP, exact NAV, and the privileged flush (recent)

- **LP supply/withdraw is asynchronous; the daily flush values the pool exactly.**
  LPs queue escrowed `request_supply`/`request_withdraw` (cancellable for an
  immediate refund, with request-time minimum-output limits), and a daily flush
  fills eligible queued heads at one frozen mark.
  *Rationale:* moving valuation off the trading hot path lets the flush afford an
  exact brute-force NAV, which deletes the entire approximate-NAV mitigation stack;
  the cost is a ~24h LP settlement delay. *Rejected:* an operator-posted NAV (this is
  a trustless on-chain crank), a multi-tx crank, and a flush that pauses trading.
- **`current_nav` is the exact per-expiry mark — one mark, no band.** Per expiry,
  `current_nav = free_cash − exact_per_order_liability`, floored at zero, where the
  liability is the payout-tree linear walk minus the leveraged-book floor correction;
  an underwater leveraged order nets to zero with no liquidation pass. The flush
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
- **Cash maintenance is decoupled from the flush potato.** Cash rebalance, the
  settled-market sweep, and liquidation are standalone, permissionless, per-market
  entrypoints; the hot potato exists only for the flush, the one flow that needs the
  exactly-once-per-market completeness proof. *Rationale:* each maintenance op is
  per-market local and invariant-preserving, so it needs neither the completeness
  proof nor the valuation lock; keeping exits responsive (rebalance) must not wait for
  the daily flush. *Rejected:* a mode flag on one shared potato; two potatoes.

## Passive exact-timestamp settlement (recent)

- **Settlement is passive, not a public operator action.** Normal flows that branch
  on settlement call `expiry_market::ensure_settled` first. It validates the supplied
  Pyth feed against Propbook's canonical binding for the market's underlying and
  records `pyth.normalized_spot_at(expiry)` when present. *Rationale:* terminal
  settlement should use Propbook exact timestamp history, and users/keepers should
  continue through ordinary redeem or pool-maintenance flows rather than calling a
  separate settle-only API. *Rejected:* a public `settle_if_possible` entrypoint.
- **Accepted consequence: exact-data liveness.** If the exact Pyth timestamp is
  missing after expiry, the market remains unsettled and live valuation aborts.
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
  `trading_paused` / `mint_paused`; PauseCaps keep only those.
- **Gate placement is uniform: line 1 of every public `&mut` entrypoint, nowhere
  else.** Internal `*_internal`/`*_inner` cores do not re-gate (the public caller
  owns it), and the watermark setter + kill switches + revocations are the documented
  ungated bypasses. *Rationale:* "is this gated?" becomes a one-line grep instead of
  a delegation trace. The admin `ProtocolConfig` setters and the registry creation
  entrypoints were brought under the gate; per-account custody and builder-code
  config stay ungated so user exits survive a freeze.
- **Two deliberate pause/valuation-gate exemptions.** `rebalance_expiry_cash`'s grow
  direction (`top_up_live_expiry_cash`) is NOT trading-pause-gated — pause blocks risk
  creation at the mint gate, while top-up only backs existing exposure and keeps exits
  fundable (gating it could starve redeems mid-emergency). `plp::lock_capital` carries
  no valuation-lock gate — it is legal only at `total_supply == 0` (both LP request
  entrypoints abort `ENotBootstrapped` until supply > 0), so nothing the lock protects
  can exist when it runs.

## Near-expiry leverage block (recent)

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
