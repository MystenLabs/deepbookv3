# P-9 · Permissionless cleanout gas-incentive + min up-front fee (E1 + E3)

**Item:** P-9 (+ the rebate-sweep/keeper acceptance) · **Instrument:** `cleanout-gas` localnet
harness strategy · **Date:** 2026-07-07 · **Audited SHA:** 79879740

Pre-registered plan and result for the first of P-9's acceptance questions: **is the
permissionless account cleanout self-incentivized** — does deleting the settled position
entries + the trading-loss-rebate summary refund the cleaner more gas than the cleanout costs,
so a keeper/MEV bot is *paid* to sweep accounts (which is what lets us accept the
conservative-reserve + post-settlement-cleanup behavior instead of restructuring rebates)? If
NOT, E3 computes the minimum up-front storage that would have to be built in to make it so.

## Hypothesis

The maximally-incentivized cleanout PTB — `redeem_settled_permissionless` × N (full closes) then
`claim_trading_loss_rebate_permissionless`, in ONE transaction — has **net gas < 0** (a refund to
the sender) at realistic account sizes, because the storage rebate from deleting N `Position`
dynamic-field entries + 1 `ExpiryTradingSummary` entry exceeds the computation cost. Equivalently
the break-even position count `N*` (where net crosses 0) is small.

## Method (the `cleanout-gas` strategy)

`packages/predict/harness/ts/strategies/cleanoutGas.ts`, run on a real localnet:
`STRATEGY=cleanout-gas python3 -m harness up --traders 1 --seconds 800`.

For each `N ∈ {1, 3, 5, 10, 20}`: park N low-leverage (1.1×, never-liquidated) positions on one
account in a fresh near-expiry (1m) market via a batched mint; wait for the keeper to settle it
(`is_settled` devInspect); then submit the ONE permissionless cleanout PTB and record its full
`effects.gasUsed` breakdown. The permissionless entrypoints derive PredictApp app-auth internally
(authorized in harness setup, `oracle_setup.py:79`), so this is the exact on-chain keeper surface,
priced as-is. The harness already captures net gas; this run adds the isolated
`storageCost` / `storageRebate` / `nonRefundableStorageFee` terms (`trace.ts gasBreakdownOf`,
`runtime.ts gasSummaryFromEffects`) because the collapsed `gas` scalar can't be split back apart.

## Measurement

Per cleanout the trace row is
`{type:"cleanout", n, computationCost, storageCost, storageRebate, nonRefundableStorageFee, net}`
(all MIST; `net = comp + storage − rebate`). Fit `net(N) = a + b·N` across the sweep:
- **b** = per-position marginal = (per-position redeem compute) − (per-position storage rebate).
- **a** = fixed term = base tx + claim compute − summary storage rebate.
- **N\*** = −a / b (break-even), if b > 0.
Also report `storageRebate(N)` to back out the measured per-position and per-summary rebate, and
cross-check against the analytical bracket below.

## Decision rule (pre-registered)

- **net(N) < 0 for N ≥ 1** (or a small `N*` at/below the median settled-loser position count) →
  the cleanout is MEASURED self-incentivized: a keeper is paid to sweep, so "unclaimed reserve
  lingers / who calls the keeper" is closed by native incentive. **Accept** the sweep/keeper
  behavior; the conservative reserve stays (intrinsic, E-note below).
- **net(N) > 0 across the sweep** → not self-incentivized on its own; the acceptance then rests on
  the protocol running the cron regardless (residual = locked-cash duration, self-correcting), OR
  on the E3 up-front-fee construction. Report the shortfall and the min fee.

## Analytical model (sanity bracket — the run is ground truth)

Sui gas (source-verified, v1.52.3): storage cost `= bytes × 100 × 76 = bytes × 7,600` MIST;
sender storage rebate `= bytes × 7,600 × 0.99 = bytes × 7,524` MIST; ~1 % (76 MIST/byte) burned;
localnet RGP = 1000; net can go negative. On a cleanout **only the leaf dynamic-field entries are
deleted** — the `Account`, `PredictData`, and both `Table` objects are RETAINED
(`predict_account.move` never `destroy_empty`/`detach`/`delete`), so the rebate is bounded to the
N position entries + 1 summary entry.

Deleted-object gas-metered bytes are bracketed (two independent derivations disagree on whether
object-level metadata + the generic type-tag are counted — the run resolves it):
- `Field<PositionKey, Position>`: contents `id(32)+key(64)+value(40)=136` B → **144 B** (contents
  + 8 meta) at the low end, up to **~325 B** (adding the 80 B owner/digest/rebate metadata + the
  `Field<…>` type-tag) at the high end.
- `Field<ID, ExpiryTradingSummary>`: contents `32+32+32=96` B → **104 B** low, up to **~285 B** high.

So per-position storage rebate ≈ **1.08M–2.45M MIST**, summary rebate ≈ **0.78M–2.1M MIST**. The
per-position redeem_settled **compute** is the unknown the run supplies; the sign of
`b = compute − rebate` is the whole question, and it is genuinely close a priori.

## E3 — minimum up-front fee (if not incentivized)

If the fit gives `b > 0` (each position costs more compute than its own rebate) and/or `a > 0`,
the cleanout can be made incentivized by building storage into the objects that are deleted, so
their rebate covers the shortfall. Two levers, priced from `rebate = pad_bytes × 7,524` MIST:
- **Per-position pad** `p_pos = ceil(b / 7,524)` bytes added to `Position` → drives the marginal
  `b` to ≤ 0, so the incentive scales with the work (N positions cleaned). Trader pre-pays
  `p_pos × 7,600` MIST storage per mint; ~1 % is burned on the round-trip.
- **Per-summary pad** `p_sum = ceil(a / 7,524)` bytes added to `ExpiryTradingSummary` → covers the
  fixed claim term once per (account, expiry).
Report both as bytes and as the equivalent up-front SUI the trader escrows. Recommendation waits
on the sign of a, b.

---

## RESULTS — localnet run (HEAD 79879740, localnet RGP 1000, clean sweep, 0 fails/retries; `analyze` bug oracle CLEAN, aggregate verdict clean, exit 0)

Permissionless cleanout PTB (`redeem_settled_permissionless` × N + `claim_trading_loss_rebate_permissionless`), all MIST:

| N | computationCost | storageCost | storageRebate | **net = c+s−r** | net (SUI) |
|---|---|---|---|---|---|
| 1 | 1,520,000 | 24,335,200 | 32,172,624 | **−6,317,424** | −0.0063 |
| 3 | 1,580,000 | 25,247,200 | 39,576,240 | **−12,749,040** | −0.0127 |
| 5 | 1,590,000 | 22,389,600 | 43,247,952 | **−19,268,352** | −0.0193 |
| 10 | 1,820,000 | 24,943,200 | 62,027,856 | **−35,264,656** | −0.0353 |
| 20 | 3,800,000 | 24,943,200 | 94,772,304 | **−66,029,104** | −0.0660 |

**Every N is net-negative — the cleaner is PAID.** Linear fit (R² ≈ 0.999):
`net(N) ≈ −3.43M − 3.14M·N` MIST. Both terms negative, so **N\* does not exist** (net never
crosses 0; it is negative from N=0). Backed-out per-item terms:
- **per-position storage rebate ≈ 3.29M MIST** (Δrebate/ΔN) — *higher* than the account-entry-only
  analytical bracket (1.08–2.45M), because `redeem_settled` also frees the order's
  `strike_payout_tree` / `liquidation_book` per-order storage, not just the account `Position` entry.
- **per-position compute ≈ 0.05–0.1M MIST** — negligible (localnet RGP 1000).
- **fixed per-cleanout storageCost ≈ 24M MIST**, roughly N-independent (the `settle` + payout
  deposits crediting the account) — already more than offset by the rebate at N=1.

## DECISION — ACCEPT (self-incentivized, MEASURED)

Pre-registered rule branch **"net(N) < 0 for N ≥ 1"** is met, decisively and at every measured
size. The permissionless cleanout is **self-incentivized by construction**: a keeper / MEV bot is
paid the storage rebate (net −0.006 SUI at N=1, scaling to −0.066 SUI at N=20) to redeem an
account's settled positions and resolve its rebate. So "unclaimed reserve lingers / who triggers
the cleanup" is closed by native incentive — **the sweep/keeper behavior and the post-settlement
cleanup are accepted as-is**, no reliance on protocol goodwill. Confirms and strengthens the plan
to bundle redeem-all + claim into ONE competitive PTB (that IS the measured tx). Risk profile:
**MEASURED**.

## E3 — minimum up-front fee: NOT NEEDED (would be 0)

The E3 branch triggers only if `b > 0` or `a > 0`. Measured `a ≈ −3.43M`, `b ≈ −3.14M` — both
already negative. So the required up-front pad is **`p_pos = ceil(max(0, b)/7,524) = 0` bytes** and
**`p_sum = ceil(max(0, a)/7,524) = 0` bytes**: no storage needs to be built into `Position` or
`ExpiryTradingSummary`, and the "pad the summary to raise the cleaner's bounty" idea is moot — the
natural rebate from freeing settled position storage already over-pays the cleaner. (Formula
retained above for the reopen case.)

**Reopen when:** the settled-redeem storage footprint shrinks materially (e.g. a compaction /
struct change that frees less per position), or Sui's storage price / rebate rate governance-drops
enough that per-position rebate (3.29M MIST at 76/9900) no longer covers per-position compute —
re-run this sweep and, if net turns positive, apply the E3 formula.

## E-note — the conservative reserve is NOT removed by any of this

Whatever the cleanout incentive, the during-market rebate reserve (`unresolved_trading_fees_paid ×
rate`, part of `required_cash`) is intrinsic to an aggregate-net-loss-only rebate: the outcome is
unknown until settlement, so the max payable (`rate × fees`) must be reserved. This experiment
targets the *cleanup* cost (keeper incentive), not the reserve; the reserve stays by design.
