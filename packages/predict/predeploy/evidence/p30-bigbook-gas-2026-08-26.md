# Big-Book Mint and Flush Gas, AVL vs Inline Vector — 2026-08-26

**Item:** P-30 (capacity model remeasure) / RP-30 (record-cap sizing) · **Instrument:** freeform parity-sim scenario (950 distinct-tick mints + flush) on localnet · **Date:** 2026-08-26

Status: measured. Prices the inline-vector walk P-30 called for, on real localnet transactions with the CI-pinned `testnet-v1.74.1`, against the AVL store as baseline. Two findings: the full-book valuation walk fits one transaction with ~4-5x compute headroom (RP-30's cap-sizing input), and the inline store's mint cost GROWS with book size where the AVL's was flat — a serialization tax the small-book benchmark could not see.

## Method

One market, 950 distinct boundary ticks (one-sided `(strike, +inf]` mints at 1e9-aligned strikes spanning the admissible probability band [0.05, 0.95] around the fixture forward), then one full staged flush. Deterministic scenario built from the parity generator's own `mint_row` admissibility logic against the synthetic oracle fixture, single oracle surface throughout, daily cadence so the market outlives the ~35-minute run. Config overrides for the run only: `initial_expiry_cash` 5,000e9, `max_expiry_allocation` 10,000e9, seeds 20,000e9, spend 0.5-1.0e9 per mint. The sim's fixed 20-action sequence guard was bypassed with a temporary local `SIM_FREEFORM` env gate (skips `validateCompleteScenario`, the required-actions check, and the Python parity pass — gas is unaffected); the patch was not committed and is documented here as method. CU = `computationCost` / localnet reference gas price (1,000); the compute cap is 5,000,000 CU per transaction.

Heads measured: `db450ce9` (#1265 — AVL table store, one dynamic-field child per tick) and `0f0ce59b` (#1265+#1270 — inline sorted vector with per-record snapshot shadows, 48B/record).

## Mint compute vs book size (CU; % of the 5M cap)

| distinct ticks | AVL | inline vector |
| --- | --- | --- |
| 1 | 2,570 (0.051%) | 2,530 (0.051%) |
| 100 | 2,640 | 2,910 |
| 300 | 2,670 | 4,210 |
| 600 | 2,690 | 10,940 |
| 900 | 2,690 | 54,400 |
| 950 | 2,680 (0.054%) | 63,000 (1.26%) |

The AVL mint is flat: subtree summaries answer the reserve reads in O(log n), noise beside pricing math. The vector mint grows with the book because the live path's reserve and admission reads (`payout_reserve_terms`, `range_max_payout`, `complement_max_payout`) are O(records) linear passes — they replaced the AVL's summaries — plus the record splice. Whole-object re-serialization is NOT the driver: a settled redeem mutates the same ~46KB market object at the full book and stays flat (see the settled section below), so the cost concentrates in operations that run reserve math or splice the record vector. Net gas at 950 ticks (localnet RGP 1,000, net of rebates): AVL ~8.8M MIST, vector ~70.2M MIST; at an assumed mainnet RGP of 100 the gap is ~2x (~0.006 vs ~0.013 SUI). Capacity is unaffected (1.26% of the cap at the full book); this is a per-trade cost curve, not a wall.

## Flush at the 950-tick book (all staged legs combined)

| store | CU | % of 5M cap | net MIST @ RGP 1,000 |
| --- | --- | --- | --- |
| AVL | 1,183,730 | 23.67% | 1,184,223,696 |
| inline vector | 1,023,390 | 20.47% | 1,030,807,752 |

The figure sums the snapshot PTB, the `value_expiry` leg, and `finish_flush` for one market; the value leg dominates (the whole cycle measured 5,650 CU at a 25-tick book, so snapshot + finish overhead is small and the leg is upper-bounded by these totals). The vector walk is ~14% cheaper than the AVL's (no per-child access overhead). Both figures corroborate the independent ~25%-of-cap estimate for a ~1k-record NAV read and place the per-transaction compute wall for one market's valuation at roughly **4,500-4,900 records** — the full 960-record book fits one transaction with ~4-5x headroom.

## Settled flows at the full book (hourly cadence, N=55; 955 records at settlement)

| action | AVL CU | inline vector CU |
| --- | --- | --- |
| settle | 1,890 | 3,360 |
| redeem_settled (each of 55, exactly flat) | 1,450 | 2,160 |
| filler rebalance (2,200 per store, median) | 1,330 | 2,840 |

Settled redemption is flat and negligible on both stores at the full book — the per-order settled payout needs no tree walk and no reserve math. Net gas: the AVL settled redeem is rebate-dominated (≈ −1.41M MIST median — deleting order state refunds more than the transaction charges); the vector's is ≈ +2.78M MIST. One vector filler rebalance cost 42,400 CU (the only one above 5,000 across 2,200) — consistent with a cash-moving live rebalance paying the same O(records) reserve reads the mint pays; every AVL filler stayed ≤ 1,340 CU. This section is what falsifies the serialization attribution corrected above.

## Conclusions

- **RP-30 cap sizing:** the inline walk at the 960 cap is MEASURED at ~20% of one transaction's compute. Raising the cap toward ~2,000 records is compute-safe on these numbers; the next binding surfaces past that are the mint serialization slope above and the 250KB object-size limit (~5k records with shadows). Any raise should re-run this scenario at the candidate cap first.
- **Store trade-off, stated precisely:** the vector removes the child-object wall and cheapens the flush, and is cheaper per mint below ~100 ticks (the small-book benchmark's -24%); above ~300 ticks the serialization tax inverts the mint comparison, reaching ~2x net at the full book at mainnet-like gas prices. For minute-cadence markets (small, short-lived books) the vector is strictly better; long-dated markets that accumulate hundreds of distinct strikes pay the slope. Mitigation if it ever matters: carry O(1) running aggregates (max-payout prefix, totals) alongside the vector so reserve reads stop walking — a small reintroduction of what the summaries provided, without the tree.
- The 2026-07-01 compute figures (15-54% for a ~1,000-node single-market walk, leveraged orders included) are superseded by these post-leverage numbers for the walk; the object-cache wall of `c1-object-cache-flush-2026-07-07.md` does not exist on the inline store.
