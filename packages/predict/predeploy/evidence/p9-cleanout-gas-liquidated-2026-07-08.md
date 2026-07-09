# P-9 · Cleanout gas-incentive for LIQUIDATED accounts (E1 follow-up)

**Item:** P-9 / RP-11 · **Instrument:** `cleanout-gas-liq` localnet harness strategy · **Date:**
2026-07-08 · **Audited SHA:** 79879740

Follow-up to `p9-cleanout-gas-2026-07-07.md` (E1), which measured the permissionless cleanout of
**surviving** positions and found it self-incentivized. This closes the gap E1 left open: the
archetypal loser is **liquidated**, and its cleanout takes a different code path
(`redeem_settled_internal:1181` → `redeem_liquidated_order`), so the E1 "self-incentivized"
conclusion was unproven for exactly the accounts most owed rebates.

## Hypothesis (the concern being tested)

A liquidated order frees its `strike_payout_tree` storage at **liquidation** time
(`clear_liquidated_order`, run by the keeper's liquidation pass), so its cleanout would free only
the account `Position` entry + a tombstone — *less* than a surviving position whose payout-tree node
is freed at cleanout (`close_settled_order`). If so, the per-liquidated-position storage rebate is
smaller, and the cleanout of a liquidated-loser account could be less incentivized — or net
positive (not incentivized).

## Method

`packages/predict/harness/ts/strategies/cleanoutGasLiq.ts`: park N high-leverage near-ATM positions
(leverage 0.95–0.99×cap, p≈0.5 → thin floor buffer → the keeper's liquidation pass knocks them out
on an adverse drift) in a fresh ~5m market, wait for settlement, then run the permissionless
cleanout. `ctx.cleanout` now splits the redeem events (`LiquidatedOrderRedeemed` vs
`SettledOrderRedeemed`) and records `nLiquidated` / `nSettled`, so the fit separates the
per-liquidated-position gas from the per-survivor gas. Two runs: single-direction (one pure-liq
sample) then mixed-direction (half UP / half DOWN → the adverse half liquidates every market,
guaranteeing liquidation data). Localnet, RGP 1000; both runs clean (0 fails/retries).

## Results

Cleanout net gas by redeem-path composition (MIST):

| source | N | nLiquidated | nSettled | storageRebate | **net** |
|---|---|---|---|---|---|
| liq run 1 | 2 | **2** | 0 | 34.25M | **−10.09M** |
| liq mixed | 4 | 2 | 2 | 45.81M | **−18.66M** |
| liq mixed | 10 | 5 | 5 | 68.72M | **−42.04M** |
| liq mixed | 20 | **20** | 0 | 116.86M | **−92.30M** |
| E1 (survived) | 20 | 0 | 20 | 94.77M | −66.03M |

Two-marginal least-squares over all points (E1 survived + both liq runs, 11 points):

```
net(nLiq, nSurv) = −3.02M + (−4.47M)·nLiq + (−3.19M)·nSurv   MIST   (R² = 0.9992)
```
- **per-liquidated-position net = −4.47M MIST (−0.00447 SUI)** — the cleaner is paid.
- per-survived-position net = −3.19M MIST (matches E1's −3.14M — cross-run consistency check).

## Conclusion — concern DISPROVEN and INVERTED

Both marginals are strongly negative, and **liquidated positions are *more* incentivized to clean
out than survivors** (−4.47M vs −3.19M net/position). At N=20, a fully-liquidated account frees
**116.9M** storage rebate vs a survivor's 94.8M. The hypothesis had the mechanism backwards: the
liquidation pass converts an active order into a **tombstone** (it does not fully free the storage),
so the cleanout still frees comparable-or-more storage — AND a liquidated redeem pays zero/floor, so
it creates **less** new storage (smaller payout deposit → lower `storageCost`). Both push net more
negative. So the permissionless cleanout is self-incentivized across the whole loser population,
**most strongly for the liquidated-loser accounts that are the primary rebate beneficiaries.**

**Effect on RP-11:** strengthens it. The "self-incentivized permissionless cleanout" conclusion now
holds for both surviving and liquidated accounts (MEASURED). No up-front fee is needed on either
path. Reopen conditions unchanged (settled/liquidated redeem storage footprint shrinks, or Sui
storage pricing drops enough to flip either marginal positive → re-run both sweeps).
