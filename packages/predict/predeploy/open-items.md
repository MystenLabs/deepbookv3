# Predict Predeploy Open Items

Updated 2026-07-02. This is the team-facing tracker for open Predict deploy
gates, audit findings, stress-test follow-ups, and required decisions.

Resolved items should be removed from this file. Historical raw audit output may
remain in ignored agent scratchpads, but this file is the tracked manifest.

## Deploy Gates

### S-4: Block Scholes updates are forgeable while the verifier is a stub

**Severity:** Deploy gate.

`block_scholes_oracle::update` currently constructs public stub updates. Propbook
BS feed writes are permissionless and gated by source id, timestamp monotonicity,
freshness, and Predict's pricing-safe envelope, not by a production signature
verifier. Do not deploy to a value-bearing environment until the real verifier
replaces the stub or the BS push surface is cap-gated.

## Contract Findings

### P-2: Near-expiry SVI freshness can overprice tails

**Severity:** Medium.

SVI total variance is consumed as variance-to-expiry, but the SVI freshness
window is much wider than the final seconds/minutes before expiry. A stale but
fresh-enough surface near expiry can materially overstate remaining uncertainty
and misprice mint/redeem flows.

**Action:** Add a minimum time-to-expiry live-pricing cutoff, scale SVI
freshness with remaining time, or otherwise document and bound the accepted
near-expiry pricing window.

### P-5: BS zero/non-normalizable updates can blank live reads

**Severity:** Low / adjacent to S-4.

The BS spot/forward read projections return `none` for zero values, but the write
path accepts and stores raw zero values. A bad push can blank the latest read and
transiently DoS priced flows until a valid push lands.

**Action:** Restore write-time nonzero/normalizable guards for BS spot and
forward updates, or document that the production verifier/source guarantees this.

### P-7: Async LP requests have no fill-price protection

**Severity:** Medium.

PLP supply and withdraw requests are queued and filled later at the next flush's
frozen PLP mark. If the pool has a small amount of PLP capital and at least one
live market, `current_nav` can be volatile. A large backlog of supply requests
could all be filled at an unfavorable transient PLP price, and withdraw requests
have the symmetric risk. Economically, queued supply/withdraw requests behave
like limit orders to buy or sell PLP, but the request objects currently carry no
per-request slippage bound.

**Action:** Add request-time limit fields: `min_plp_out` for supply requests and
`min_dusdc_out` for withdraw requests. `finish_flush` should fill only requests
whose frozen-mark output satisfies the limit; requests that miss their limit
should remain queued or be explicitly refundable/cancellable under a documented
policy. Add tests for both pass and miss cases, including a volatile low-capital
pool mark.

## Capacity and Liveness Findings

### C-1: Full-pool flush has no joint valuation budget

**Severity:** Medium / must be accepted or fixed before deployment.

The flush values every active market in one PTB. Current independent caps
(`24` live markets, `1000` payout nodes, `5000` leveraged orders per market) do
not compose into the 5M computation-unit wall. The NAV price memo removed the
single-market pre-cap OOG: one market at 5,000 leveraged orders has been measured
around 47-54% of the wall. The remaining deploy blocker is the pool-total case:
multi-market stress reached the wall around the current aggregate envelope, and
the 24-market cap is still far above the measured safe joint budget.

**Action:** Add a joint budget across all active markets, tighten caps to the
measured single-PTB envelope, or make valuation resumable across PTBs. See
`stress/capacity-and-gas-findings.md`.

### C-3: Large multi-command PTBs amplify trade cost

**Severity:** Medium for routers/keepers; normal one-op users unaffected.

Localnet experiments show batched leveraged mints/redeems cost far more per op
than standalone transactions because command cost scales with transaction
position / accumulated transaction state. A 100-mint PTB uses about 68% of the
computation cap; the ceiling is around 110-150 leveraged mints, data-dependent.

**Action:** Treat large atomic router PTBs as bounded; do not assume standalone
gas scales linearly inside a PTB. See
`stress/mint-batch-findings-2026-07-01.md`.

## Oracle Calibration

### O-1: Near-expiry oracle miscalibration is exploitable

**Severity:** High if near-expiry markets are enabled without recalibration.

Offline and on-chain tests found high-priced near-expiry binary contracts
systematically underpriced and low-priced contracts systematically overpriced.
See `oracle-calibration.md`.

**Action:** Recalibrate near-expiry volatility/time-to-expiry behavior or block
the affected near-expiry market shape until the reliability curve is verified.
