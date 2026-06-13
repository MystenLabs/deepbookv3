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
  the durable post-mint terms (quantity, floor shares, opened-at, boundary
  indices, sequence); there is no separate order table. It is self-authenticating,
  costs zero per-order storage, and doubles as the liquidation sort key.
  *Rejected:* unpacking to a sequence + `Table<u64, Order>`.
- **Mint-admission policy is kept out of the order id.** Leverage tiers and price
  thresholds live in config, not in order decoding, so a future policy change can
  never retroactively invalidate an existing packed id.
- **Two separate strike indexes.** A dense paged NAV matrix (`{quantity,
  floor_shares}` with strike-weighted prefix sums) and a sparse payout treap
  (terminal-payout prefix) coexist because NAV and payout need different algebra
  and rounding. *Rejected:* a single combined matrix (made every op heavier) and a
  treap-only mark-to-market (per-node dynamic-field storage too gassy).
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
- **DUSDC pools with pool-coordinated compaction.** Compaction returns LP cash to
  the pool, unregisters the expiry from active valuation, and leaves it as
  payout/rebate escrow — there is no expiry-only path that can strand capital.
  *Rejected:* a monolithic single-vault model; a separate expiry-only compaction
  path.

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
  standing backing to live markets. `max_expiry_funding` remains the per-flow
  funding ceiling, and the pool sync tops every market toward its reserve
  target before an LP withdrawal pays out. *Superseded:* the idle earmark
  (`idle ≥ Σ active (max_funding − net_funding)`), which pinned the full cap of
  pool capital per active market regardless of book shape and whose backing
  duty became void under the settlement-floor guarantee.
- **Uncertainty-band withdrawal fee.** A withdrawing LP pays a fee proportional to
  the pool's unverified-floor valuation uncertainty, retained for the LPs who
  remain — the withdraw-side counterpart to the optimistic (upper-bound) supply
  mark.
- **Keep the payout tree.** The tree's max-live term is the enforced settlement
  floor that anchors the live reserve — an O(1) root read, and the structural
  proof that any reserve ≥ it always pays in full at settlement. *Rejected:*
  folding settlement into the NAV matrix and deleting the tree.

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
