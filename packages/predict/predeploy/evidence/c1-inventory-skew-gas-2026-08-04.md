# Inventory-Skew Gas Findings — 2026-08-04

**Item:** C-1 · **Instrument:** static instruction accounting (ESTIMATED — no
harness A/B yet) · **Date:** 2026-08-04

Status: **estimated, not measured.** This records the analytical cost of the
inventory-skew charge (transaction-price skew, unsigned, escrowed) against
C-1's capacity model, and names the harness A/B that would confirm it. Treat
every number below as a bound derived from the code, not an observation. The
precedent for the measured form of this note is
`c1-skew-gas-2026-07-09.md` (SVI smile skew: **+2.2% per-order flush slope**,
+3.3% at full book), which is the yardstick a real A/B should be read against.

## The change

Two new reads on `StrikeExposure`:

- `marginal_reserve_consumption(lower, higher, net_payout, adding)` — how much
  enforced payout reserve a candidate range would add or release, via
  `strike_payout_tree::range_max_net_payout` (and, on remove,
  `complement_max_net_payout`).
- `inventory_skew_charge(...)` — that consumption priced into a per-unit rate
  `gamma · (delta / net_payout) · p(1 − p)`, capped. Pool-wide load is not in
  this product (priced by the utilization fee multiplier instead).

`quote_mint_terms` calls the charge once per mint. `quote_live_close` calls it
once per live close, and only when the expiry snapshotted
`inventory_skew_rebate_enabled`.

## Where the cost does and does not land

**The pool flush is untouched.** `plp::value_expiry` →
`expiry_market::current_nav` → `strike_exposure::exact_live_liability` never
reaches either new function. The only flush-visible change is one extra `u64`
field read and one add inside `expiry_cash::free_cash` (the skew escrow joins
the rebate reserve in the netting). **C-1's flush capacity model — the 5,000
leveraged-order single-market cap, the 1,000-node cap, and the pool-total
`Σ_markets` envelope — is therefore unchanged by this feature.** That is the
substantive difference from the SVI smile skew, which repriced every boundary
tick inside the flush and did move the model.

The added cost is per-transaction, on mint and on rebate-enabled close.

**At the shipped defaults the added cost is nil.** `inventory_skew_rate`
short-circuits on `gamma == 0` (the sole kill switch) before touching the
tree, and gamma ships at `0`; `quote_live_close` short-circuits on
`inventory_skew_rebate_enabled == false`, which also ships off. An unarmed
market pays one config field read and one comparison per mint. Unit test
`gamma_zero_kill_switch_returns_zero_on_a_piled_book` pins the kill switch
against a book that would otherwise force range-max walks.

## Estimated cost when armed

`range_max_net_payout` is two read-only descents of the AVL payout tree:

| walk | dynamic-field loads per level | bound |
| --- | --- | --- |
| `settlement_prefix_net_payout` | 1 node + 1 child summary when descending right | ≤ 2h |
| `window_summary` (split walk, two arms) | 1 node + ≤ 1 whole-subtree summary per level per arm | ≤ 4h |

The tree is height-balanced (AVL, rotations driven by measured height), so
`h ≤ 1.44·log₂(n + 2)`. At the `max_payout_tree_nodes` cap of 1,000, `h ≤ 14`:

- **worst case ≈ 84 read-only dynamic-field loads** per armed mint (or armed
  close) at a fully saturated 1,000-node book;
- **typical ≈ 20–35 loads** at a realistic 20–100-boundary book (`h ≈ 5–8`).

On top of that: one `net_payout_reserve_terms` root read and roughly four
`mul_down`/`mul_div_down` fixed-point ops. No `exp`, no `ln`, no oracle read —
the charge is pure integer arithmetic over values the book already stores.

For scale on the same transaction: a mint **already** runs `apply_range` twice
(the start and end boundary), and those are read-**write** descents with
rotations and a `resummarize` write per level. Dynamic-field writes dominate
reads in Sui gas, so the skew charge adds the cheap half of a walk the mint is
already paying for the expensive half of, plus two `compute_nd2` pricing evals
that each carry an `exp` chain. **Estimated per-mint delta: low single-digit
percent when armed**, and structurally similar on the close side.

## What would confirm it

The A/B that produces a measured number, matching `c1-skew-gas-2026-07-09.md`'s
instrument:

1. Harness `batch-max-book` on localnet with `SIM_GAS_BUDGET=50000000000`,
   two sides at the same commit: `gamma = 0` (control) vs `gamma` armed with
   `inventory_skew_rebate_enabled = true`.
2. Report **per-mint** and **per-close** computation, not the flush slope — the
   flush is not on this feature's path. Sample at a small book and again near
   the 1,000-node cap, because the cost is `O(log n)` in boundary count, not in
   order count.
3. Cross-check the batched case against `c3-mint-batch-2026-07-01.md`: a
   batched leveraged mint is amplified ~15–20× by per-transaction metering, so
   a per-op delta that is negligible standalone is the one to re-measure inside
   a 100-mint PTB before arming `gamma` in production.

Until (1)–(3) run, `gamma` stays at its inert `0` default, so nothing here
gates the deploy.

## Amendment — complement-max on the close path (2026-08-04)

The removal branch of `marginal_reserve_consumption` now queries
`complement_max_net_payout` (two `range_max_net_payout` arms over
`(-inf, lower]` and `(higher, +inf]`) so the max-point drop is
`M − max(R − N, C)` rather than a blind `N`. **Open path unchanged.**

Added close-path cost when rebates are armed:

| walk | bound |
| --- | --- |
| in-range `range_max_net_payout` (already counted above) | ≤ 6h loads |
| complement left arm (skipped when `lower == 0`) | ≤ 6h |
| complement right arm (skipped when `higher == pos_inf`) | ≤ 6h |

At the 1,000-node cap (`h ≤ 14`): worst-case close ≈ **252** read-only
dynamic-field loads (3× the single-range walk), typical ≈ **60–100** at a
20–100-boundary book. Still no `exp`/`ln`/oracle, and still dominated by the
close's existing write-side `remove_range` work. **Revised per-close estimate
when armed: low-to-mid single-digit percent** vs the prior low single-digit
figure that assumed one range walk; mint estimate unchanged.

The round-trip crowding equality in `decisions.md` depends on this complement
read — falling back to `g_removal = 0` would be cheaper but was rejected here
because the extra two `O(log n)` descents stay inside the same capacity band.

## Amendment — load factor removed (2026-08-04)

`skew_capital_basis` / `u_after` left the rate. Kill switch is `gamma == 0`
alone; the early return still precedes every range-max walk. Mint-path
arithmetic is slightly cheaper (no liability/utilization mul). Close-path tree
cost unchanged.
