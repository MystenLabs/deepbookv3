# Design decisions

The significant design decisions behind Predict — what was chosen, why, and the
main alternatives that were rejected. It complements the conceptual docs (which
explain *how* the protocol works) with the rationale for the shape it took. For
the invariants these decisions must preserve, see [invariants.md](./invariants.md).

> **Status:** pre-deploy, living record. The most recent decisions are at the end.

## Economic model

- **Leverage is a deterministic floor, not a debt overlay.** A position is one
  option-like contract whose live value is `range-probability value − a
  deterministic, time-varying floor`, floored at 0 (1× = zero floor); the floor is
  limited-recourse to its own order. *Rejected:* a borrow-index / normalized-debt
  overlay (leverage as a separable debt) and utilization-based borrow rates — the
  floor model keeps one contract with a time-varying floor, with no separate debt
  to track, price, or liquidate.
- **Time-only floor schedule.** The floor index rises deterministically with time
  (quadratic ramp) toward a terminal value, independent of spot. *Rejected:*
  double-sided range leverage and spot-dependent rates — double-sided leverage is
  non-monotonic in spot, so there is no exact global liquidation index.
- **Pure-knockout liquidation.** A leveraged order is removed without paying the
  holder once it falls to/below `floor_amount / liquidation_ltv`; a tombstone
  persists until the holder redeems and clears it. *Rejected:* residual-paying
  liquidation.

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

- **The live cash-backing reserve is the summed per-order maximum live backing**
  (`Σ (quantity − floor_at_open)`), not the worst-case liability at a single
  price. This makes a market self-contained: every open position can be
  live-redeemed at its own peak, in any order, without the expiry running dry.
  *Superseded:* the earlier single-point `max_live_backing` reserve, which
  under-reserved disjoint positions.
- **Pool funding-cap earmark.** The pool keeps idle DUSDC ≥ the unfunded portion
  of every active expiry's cap, so any active market can be funded to its cap on
  demand; earmarked idle is not LP-withdrawable, and no market depends on a future
  sync to back positions it has already opened.
- **Uncertainty-band withdrawal fee.** A withdrawing LP pays a fee proportional to
  the pool's unverified-floor valuation uncertainty, retained for the LPs who
  remain — the withdraw-side counterpart to the optimistic (upper-bound) supply
  mark.
- **Keep the payout tree.** Although the summed reserve made the tree's max-live
  term no longer the enforced reserve, the tree is retained: the planned flexible
  backing reserve uses `max_live_backing` as its safe floor — any reserve ≥ it
  always pays in full at settlement. *Rejected for
  now:* folding settlement into the NAV matrix and deleting the tree.

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
