# P-32 user-path mint computation with inventory-impact rate on, 2026-08-21

**Item:** P-32

**Revision:** `73a24e3a596a6b8b5815234e8093ceaa38525086` plus the uncommitted harness A/B (`capacity-user-off` / `capacity-user-on`) and the template-rate setter used to snapshot 2% onto the treatment markets.

**Instrument:** one campaign of `capacity-user-off` and `capacity-user-on` in parallel, retained instances `capacity-user-off-aug21-105246-22262` and `capacity-user-on-aug21-105246-22262`, `--timeout 300`, real-data oracle stream, prod cadence set (1m/5m/1h, window 3). Each arm submitted 40 single-leg mint PTBs on one far market. The treatment keeper cut a grid and snapshotted `inventory_impact_max_rate = 20_000_000` (2%) before the first roll.

## Question

[`p32-cell-array-gas-2026-08-21.md`](p32-cell-array-gas-2026-08-21.md) priced initialize, refresh, and mint at the default-zero rate, so quotes skipped the capital walk. This run asks what a user mint actually costs when the rate is on: two 100-bucket `capital()` / `span_max` scans at quote plus the cell-array write at commit, compared to the same single-leg mint with no grid.

## Method

Both arms use the same ATM-ish probability band `[0.45, 0.6]`, the same $5–10 spend, the same 1.5s tick, and `max_cost` large enough that a growing charge cannot abort the measurement. `user-off` advertises funded markets with no grid and rate 0. `user-on` advertises only after `gridInit` and markets snapshot the 2% template. Analyzer `compGas` is `effects.gasUsed.computationCost` on each one-call PTB.

## Result: turning the rate on adds ~21M computation per mint (0.42% of the cap)

Forty single-leg mints on each arm. Off: mean 1,559,750 MIST (min 1,530,000, max 1,580,000). On: mean 22,427,500 MIST (min 19,500,000, max 25,300,000). Increment 20,867,750 MIST, 0.42% of the 5,000,000,000 computation cap, about 14× the ordinary mint. The on-path cost is noisy but not a steep function of book size across these 40 orders (first mint 21.5M, last 22.4M), which matches a quote that always walks 100 buckets. Keeper work on the treatment arm is separate: `gridInit` 40,700,000 on an empty book; five refreshes 75.6M → 105M as the book grew. No mint aborted. Campaign verdict clean.

## Reading

A live mint with the illustrative 2% rate stays far inside the per-tx computation cap. The user increment is the quote walk plus the cell write, not keeper refresh. This does not calibrate `r_K` or decide whether a nonzero rate should ship.

## Limits

One campaign, 40 mints per arm, books of 40 ATM-width orders. Close, multi-leg PTBs, and a 1,000-node wing-filled book are unmeasured. Charge cash amounts were not scored; only computation was.
