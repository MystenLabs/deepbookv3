# Design decisions

The significant design decisions behind Predict — what was chosen, why, and the
main alternatives that were rejected. It complements the conceptual docs (which
explain *how* the protocol works) with the rationale for the shape it took. For
the invariants these decisions must preserve, see [invariants.md](./invariants.md).

> **Status:** pre-deploy, living record. The most recent decisions are at the end.

## Economic model

- **Leverage is a deterministic floor, not a debt overlay.** A position is one
  binary (digital) contract whose live value is `range-probability value − a
  deterministic, time-varying floor`, floored at 0 (1× = zero floor); the floor is
  limited-recourse to its own order. *Rejected:* a borrow-index / normalized-debt
  overlay (leverage as a separable debt) and utilization-based borrow rates — the
  floor model keeps one contract with a time-varying floor, with no separate debt
  to track, price, or liquidate.
- **Time-only floor schedule.** The floor index rises deterministically with time
  (quadratic ramp) toward a terminal value, independent of spot. *Rejected:*
  double-sided range leverage and spot-dependent rates — double-sided leverage is
  non-monotonic in spot, so there is no exact global liquidation index.
- **Pure knock-out liquidation.** A leveraged order is removed without paying the
  holder once it falls to/below `floor_amount / liquidation_ltv`; a tombstone
  persists until the holder redeems and clears it. *Rejected:* residual-paying
  liquidation.
- **The ask-price band applies to mint only — redeems price at the live mark.**
  The mint-time `[min_ask, max_ask]` band is admission policy: the protocol
  declines to become counterparty in the tail price regions where the curve is
  least reliable. Once a contract is live, redeeming at the live mark is the
  holder's right; a redeem clamp would systematically underpay legitimate
  deep-ITM winners near expiry (range probability legitimately approaches 1,
  consistent with settlement paying full quantity). *Rejected:* a symmetric
  redeem-side price band.

## Data structures

- **The order id is a packed `u256` — the single on-chain term store.** It packs
  the durable post-mint terms (quantity, floor shares, opened-at, two strike
  ticks, sequence); there is no separate order table. It is self-authenticating,
  costs zero per-order storage, and doubles as the liquidation sort key.
  *Rejected:* unpacking to a sequence + `Table<u64, Order>`.
- **Mint-admission policy is kept out of the order id.** Leverage tiers and price
  thresholds live in config, not in order decoding, so a future policy change can
  never retroactively invalidate an existing packed id.
- **Two sparse strike indexes, both tick-keyed.** A sparse payout treap
  (terminal-payout + live-backing prefixes) and a flat liquidation book coexist;
  the exact live NAV is read by decomposing the per-order liability across the two
  (`Σ qty·P` over the tree minus the leveraged floor-correction scan over the book).
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
  The sort key lives in the immutable packed id, and an order's floor deficit is
  time-varying — it cannot be a static key. Largest-first is the best feasible
  static proxy for the quantity that matters (how much a stale order can
  overstate NAV). *Rejected:* most-under-floor-first (would require re-keying the
  book on every index tick).

## Accounting and rounding

- **Per-expiry config is snapshotted immutable at creation**, so admin changes to
  the global template never reprice live orders.
- **Uniform round-down math** at 1e9 scale; solvency rests on bit-identical
  reserve↔payout pairing (a reserve and its payout derive from the same quantity
  via the *identical* helper). *Rejected:* mixed ceil/floor primitives, which
  introduced super-additivity drift and were deleted.
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
  buffer**: `max_live_backing + λ · (Σ live_backing − max_live_backing)`, with
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
- **Keep the payout tree.** The tree's max-live term is the enforced settlement
  floor that anchors the live reserve — an O(1) root read, and the structural
  proof that any reserve ≥ it always pays in full at settlement. The same tree now
  also serves the exact NAV linear walk (`Σ qty·P` over its live boundaries), so it
  is the single full-lifecycle live index. *Rejected:* folding settlement into the
  deleted NAV matrix and dropping the tree.

## Access and operations (recent)

- **Trading-loss-rebate claims are permissionless.** `claim_trading_loss_rebate`
  has no owner gate — anyone may resolve any manager's rebate. Intentional: a
  keeper cron runs after each settlement to close out all user redemptions and
  economically clean out the expiry, so resolution must not depend on each user
  acting. *Rejected:* an owner gate, which would let an inactive user's rebate
  strand and block the post-settlement cleanout. *Accepted residual:* a griefer
  can resolve a victim's rebate at a less-favorable active-stake snapshot; the
  prompt post-settlement sweep bounds the window.
- **The protocol reserve is write-only.** `protocol_reserve_balance` accrues
  protocol profit and exposes no admin withdrawal path. Intentional for now — the
  reserve is left in the protocol backing solvency, and an explicit admin
  withdrawal flow can be added later if it is needed. *Rejected (for now):* an
  admin drain entrypoint.

## Oracle extraction (recent)

- **The oracle moved out of Predict into the standalone `propbook` package.** The
	  in-package `MarketOracle`, `PythSource`, `settlement_state`,
	  `market_oracle_config`, `market_oracle_writer_cap`, and `oracle_events` modules
	  were deleted. Live data now comes from two Predict-unaware feeds —
	  `propbook::pyth_feed::PythFeed` (one global spot per Lazer feed) and
	  `propbook::block_scholes_feed::BlockScholesFeed` (one per source id, with
	  per-expiry surfaces plus exact timestamp history) — each updated permissionlessly
	  from a self-authenticating verified `Update`, so there is no writer capability.
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
  fresh, else the normalized Block Scholes `forward`;
	  the Block Scholes *surface* must be fresh either way (`EBlockScholesSurfaceStale`).
	  *Rationale:* the surface alone carries a usable forward, so a momentarily stale
	  or non-positive/unrepresentable spot should not block trading. An oversized
	  normalized Pyth spot still aborts under Predict's pricing envelope. The freshness
	  windows for Pyth spot and the BS surface collapsed to one window each — the surface
	  row writes spot + forward + SVI together, so the former separate price and SVI
	  windows became one.
- **Predict does not version-gate the feeds.** The propbook feeds carry their own
  package version and a forward-only `migrate`; Predict reads them and never asserts
  their version. *Rationale:* an external, independently-upgraded package owns its
  own version policy; a stale feed caller is harmless (it just reads an old, still
  migratable feed). This removed the per-object `allowed_versions` mirror and
  `sync_*` entry that the old in-package oracle objects carried.

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
  `MarketCreated` carries `tick_size` and `max_expiry_allocation`, not min/max strike.
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
  market until settlement. Saturation keeps those reads live; the `[min_ask, max_ask]`
  admission band, not an abort, is what keeps the protocol from writing a tail it
  prices poorly. *Rejected:* a standalone reject-at-mint strike-range guard (redundant
  with the ask band on mint, and it would not cover redeem / NAV / liquidation, which
  re-price already-minted orders with no band).

## Async LP, exact NAV, and the privileged flush (recent)

- **LP supply/withdraw is asynchronous; the daily flush values the pool exactly.**
  LPs queue escrowed `request_supply`/`request_withdraw` (cancellable for an
  immediate refund), and a daily flush drains both queues at one frozen mark.
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
  entrypoints were brought under the gate; per-user `PredictManager`/`builder_code`
  custody stays ungated so user exits survive a freeze.
