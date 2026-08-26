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

The AVL mint is flat: the O(log n) child descent is noise beside pricing math. The vector mint grows with the book because every mint re-serializes the whole market object, which carries all records inline (~46KB at 950 ticks at 48B/record — half of that is the snapshot shadows; a shadow-free record as in the #1269 prototype would roughly halve the slope). Net gas at 950 ticks (localnet RGP 1,000, net of rebates): AVL ~8.8M MIST, vector ~70.2M MIST; at an assumed mainnet RGP of 100 the gap is ~2x (~0.006 vs ~0.013 SUI). Capacity is unaffected (1.26% of the cap at the full book); this is a per-trade cost curve, not a wall.

## Flush at the 950-tick book (all staged legs combined)

| store | CU | % of 5M cap | net MIST @ RGP 1,000 |
| --- | --- | --- | --- |
| AVL | 1,183,730 | 23.67% | 1,184,223,696 |
| inline vector | 1,023,390 | 20.47% | 1,030,807,752 |

The figure sums the snapshot PTB, the `value_expiry` leg, and `finish_flush` for one market; the value leg dominates (the whole cycle measured 5,650 CU at a 25-tick book, so snapshot + finish overhead is small and the leg is upper-bounded by these totals). The vector walk is ~14% cheaper than the AVL's (no per-child access overhead). Both figures corroborate the independent ~25%-of-cap estimate for a ~1k-record NAV read and place the per-transaction compute wall for one market's valuation at roughly **4,500-4,900 records** — the full 960-record book fits one transaction with ~4-5x headroom.

## Conclusions

- **RP-30 cap sizing:** the inline walk at the 960 cap is MEASURED at ~20% of one transaction's compute. Raising the cap toward ~2,000 records is compute-safe on these numbers; the next binding surfaces past that are the mint serialization slope above and the 250KB object-size limit (~5k records with shadows). Any raise should re-run this scenario at the candidate cap first.
- **Store trade-off, stated precisely:** the vector removes the child-object wall and cheapens the flush, and is cheaper per mint below ~100 ticks (the small-book benchmark's -24%); above ~300 ticks the serialization tax inverts the mint comparison, reaching ~2x net at the full book at mainnet-like gas prices. For minute-cadence markets (small, short-lived books) the vector is strictly better; long-dated markets that accumulate hundreds of distinct strikes pay the slope. Mitigations if it ever matters: pack the record (ticks fit 30 bits), or bucket records into fixed-size pages (bounds per-mint serialization while keeping loads O(1) pages).
- The 2026-07-01 compute figures (15-54% for a ~1,000-node single-market walk, leveraged orders included) are superseded by these post-leverage numbers for the walk; the object-cache wall of `c1-object-cache-flush-2026-07-07.md` does not exist on the inline store.
