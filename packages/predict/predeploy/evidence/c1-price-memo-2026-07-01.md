# NAV Price-Memo Findings — 2026-07-01

**Item:** C-1 · **Instrument:** `nav-stress` post-memo rerun (localnet harness) · **Date:** 2026-07-01

Status: measured finding for the landed NAV price-memo change. The single-market
result graduated into open-items C-1's capacity model; the multi-market result
remains a pool-total cap input. Supersedes the pre-memo single-market flush OOG
finding for the single-market case only.

## The change

The full-pool flush values each expiry via `strike_exposure::marked_live_liability`,
which was `walk_linear` (payout-tree, prices each of ≤1,000 distinct boundary ticks
once) **plus** `correction_value` (liquidation book, re-priced every one of up to
5,000 leveraged orders). Every leveraged order's boundary ticks are already tree
nodes, so the correction walk re-priced what the linear walk had just priced.

The memo (`pricing::PriceMemo`) caches each tick's `up_price` during the in-order
linear walk and has the correction read it back by binary search — so the correction
does **zero** pricing evals, only cache hits. It is exact (caches, never
approximates; NAV stays bit-identical), enforced by a 100%-hit invariant
(`ETickNotInPriceMemo` aborts a finite miss). The now-incompatible interpolation
lever (`nav_interpolation_price_tolerance`) and its `min_tick`/`max_tick` machinery
were removed in the same change.

## Method

Harness `nav-stress` / `batch-max-book` (single market) and `batch-max-markets`
(pool total), run against the memo source with `SIM_GAS_BUDGET=50000000000`. Baseline
figures are the pre-memo `nav-stress` runs. Correctness gate: zero `pricing:13`
(`ETickNotInPriceMemo`) aborts and a clean bug oracle.

## Single market — the OOG is eliminated

| | pre-memo | memo |
| --- | --- | --- |
| flush at book ~1,404 | ~1,536M MIST (31% of cap) | ~743M (15%) |
| full-book flush | OOG at ~4,501 (99%) | 4,955 at ~2,676M (54%); 5,000 at ~2,364M (47%) |

The memo roughly halves the per-order flush slope (~1,086K → ~530K MIST/order) and,
crucially, the single-market flush **no longer OOGs before the cap** — the 5,000
`EMaxActiveLeveragedOrders` cap now binds, not NAV computation. So a single market at
the full 5,000 cap is safe (~47–54% of the wall). The removed half was the pricing;
the remaining ~530K/order is the liquidation-book iteration (dynamic-field page walk),
not `nd2`.

## Many markets — still bounded, and entangled

The memo dedupes pricing **within** a market, not across markets: the linear walk is
per-market, so ~9 live markets × up-to-1,000 ticks each stack toward the wall.
`batch-max-markets` reached a pool total of ~14,600 across ~9 markets; the flush last
valued **~8,640 total leveraged orders at ~4,599M (92%), then OOGed** — so the
pool-total gas cliff is ~9,000–9,400 total orders for ~9 markets on the cheap branch.

This number is a **lower bound / entangled**: the run also hit
`expiry_cash::EInsufficientCash` 412× (the ~$10M bootstrapped pool ran out of LP
capital to back the leveraged liability, worsened by the flush-brick locking capital
in unsettled markets). Pool capital and flush gas collided, so the clean gas-only
limit is not isolated here.

Implication for the joint cap: the binding constraint is the **pool total**, not a
per-market cap. 1,000 leveraged/market × ~9 markets ≈ 9,000 ≈ 96% of the wall — no
margin, and worse on the expensive branch or at the contract's 24-market cap. A safe
joint budget targets ~60% of the wall (~5,600–6,100 total leveraged orders across all
live markets on the cheap branch), i.e. `per_market ≈ safe_total / max_live_markets`.

## Correctness

- Zero `ETickNotInPriceMemo`; bug oracle clean on every single-market run.
- `batch-max-markets`' 426 flagged aborts were `expiry_cash:0` (`EInsufficientCash`),
  the capital limit above — NOT the memo (the same-contract `batch-max-book` was
  clean, and the memo does not touch `expiry_cash`). It is an expected admission
  precondition; `analyze.py` flags it only because `expiry_cash` is not whitelisted.
- Still useful before final cap-setting: a broader generated-book property test
  `NAV_with_memo == NAV_reference` over leveraged + 1x books,
  shared/distinct/zero-delta ticks, and ±inf boundaries.

## Follow-up before the number is final

1. Broader property test above.
2. A clean gas-only multi-market run: add LP supply to `batch-max-markets` so
   `EInsufficientCash` does not bound the book before the flush OOGs.
3. A worst-case-moneyness multi variant, since the linear walk (the memo's remaining
   per-market pricing) is where moneyness now bites.

Cross-refs: `c1-nav-stress-2026-06-30.md`, `c3-mint-batch-2026-07-01.md`,
`../open-items.md` (`C-1`, which carries the consolidated capacity model).
