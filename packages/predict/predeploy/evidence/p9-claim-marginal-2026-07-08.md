# P-9 · The rebate CLAIM's own gas economics (E1 / RP-11 follow-up)

**Item:** P-9 / RP-11 · **Instrument:** `claim-marginal` localnet harness strategy · **Date:**
2026-07-08 · **Audited SHA:** 79879740

Closes the second gap E1 left open. E1 proved the *bundle* (redeems + claim) is net-negative, but a
gas-maximizing searcher includes the claim only if its OWN contribution is a refund. If the claim
were a net cost, searchers would redeem accounts (profitable) but **skip the claim** — and the
reserve of **non-owed (winner) accounts**, whose owner has no rebate to self-claim, would never
resolve back to the pool.

## Hypothesis / question

Is the rebate claim's net gas ≤ 0 — (a) standalone (`claim_trading_loss_rebate_permissionless`
alone, on an account whose positions are already redeemed), and (b) as a marginal added to a redeem
PTB? If yes, searchers resolve it either way and RP-11 holds unqualified.

## Method

`packages/predict/harness/ts/strategies/claimMarginal.ts`: per settled account, run the N redeems
WITHOUT the claim (`redeemSettledAllTx` → leaves an unresolved summary, count == 0), then the claim
ALONE (`claimRebateOnlyTx`), tracing each tx's full gas breakdown. Standalone-claim net = the
`claimRebate` trace; in-bundle marginal = E1's full cleanout minus this run's `redeemAll` at matched
N. Low-leverage surviving positions; localnet RGP 1000; run clean (0 fails, analyze bug-oracle clean).

## Results (MIST)

| op | N | computationCost | storageCost | storageRebate | **net** |
|---|---|---|---|---|---|
| redeems-only (no claim) | 3 | 1,510,000 | 16,408,400 | 28,162,332 | −10,243,932 |
| redeems-only (no claim) | 10 | 1,780,000 | 19,266,000 | 53,743,932 | −32,697,932 |
| **claim-only (standalone)** | — | 1,490,000 | 22,693,600 | 25,130,160 | **−946,560** |
| **claim-only (standalone)** | — | 1,490,000 | 22,389,600 | 24,829,200 | **−949,600** |

Derived:
- **Standalone claim ≈ −0.95M MIST** (−0.00095 SUI) — the claim run *alone* pays the sender. It frees
  ~25.1M storage rebate (the `ExpiryTradingSummary` entry plus the `settle` / residual-return /
  rebate-reserve resolution freeing accumulator+balance storage) against ~24.2M cost.
- **In-bundle marginal** = E1 full cleanout − this run's redeems-only, at matched N:
  N=3: −12.75M − (−10.24M) = **−2.51M**; N=10: −35.26M − (−32.70M) = **−2.56M**. The claim added to a
  redeem PTB *refunds* an extra ~2.5M (more favorable than standalone, since the base tx is shared).

## Conclusion

**Both are net-negative.** The rebate claim is self-incentivized whether run **standalone** (−0.95M)
or **bundled** into a redeem PTB (marginal −2.5M). So a searcher resolves it in both regimes, and the
reserve of non-owed (winner) accounts — where no owner self-claim incentive exists — is released to
the pool by the same permissionless gas-arbitrage. **RP-11 holds with no bundle-dependence
qualification.** Reopen conditions unchanged (a storage-footprint or Sui-pricing change that flips
either net positive → re-run this split).
