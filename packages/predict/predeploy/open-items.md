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

### P-8: PoolVault.protocol_reserve_balance is accrue-only — no withdraw path

**Severity:** Medium / required decision before deploy.

Materialized protocol profit joins into `PoolVault.protocol_reserve_balance`
(plp.move:797, :912) but no split/withdraw/claim entrypoint exists in any of the
four packages (verified by grep at HEAD b34b0cd4; only a getter and an event
field read it). The protocol cut is excluded from LP value and can never leave
the vault without a package upgrade.

**Action:** Add an AdminCap-gated withdraw entrypoint (e.g.
`withdraw_protocol_reserve` splitting from the balance), or record deliberate
deferral to a post-deploy upgrade as the decision. (audit 412e9e)

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

### C-4: LP flush drain hard-aborts on a zero-value head request or a NAV==0 mark

**Severity:** Medium.

`lp_book::drain` asserts `shares > 0` / `payout > 0` per filled request and
`pool_value > 0` / `total_supply > 0` in the share-pricing helpers, all under a
single `EInvalidDrainMark`. A head request whose fill rounds to zero, or a
reachable NAV==0 mark (sticky profit-basis exclusion exceeding gross — see the
plp.move:735-740 comment), aborts the entire flush instead of skipping or
refunding the degenerate request. The only unblock is the request owner
voluntarily cancelling; a hostile or absent owner stalls the FIFO indefinitely,
freezing all supply/withdraw behind it.

**Action:** Treat zero-value fills as skip/auto-cancel-and-refund instead of
aborting, and reserve `EInvalidDrainMark` for genuinely invalid marks (or split
the error codes and add an eviction path for degenerate head requests). Design
this together with the P-7 limit-field policy, which already needs a
stay-queued/skip decision for missed limits. (audit 11767b)

## Oracle Calibration

### O-1: Near-expiry oracle miscalibration is exploitable

**Severity:** High if near-expiry markets are enabled without recalibration.

Offline and on-chain tests found high-priced near-expiry binary contracts
systematically underpriced and low-priced contracts systematically overpriced.
See `oracle-calibration.md`.

**Action:** Recalibrate near-expiry volatility/time-to-expiry behavior or block
the affected near-expiry market shape until the reliability curve is verified.

## Maintainability and Pre-Deploy Hygiene

From the 2026-07-02 mini audit sweep (HEAD b34b0cd4). These are free to fix
pre-deploy and breaking (or permanent) after; none block correctness today.

### H-2: Mint fee breakdown derived twice between the slippage assert and payment

**Severity:** Low (latent correctness risk under future edits).

`mint_prepared_exact_quantity` (expiry_market.move:849-851) and
`settle_mint_payment` (:1070-1073) independently derive the identical
builder-fee/subsidy/trader-fee decomposition; the `max_cost` bound and the
actual withdrawal stay equal only by hand-maintained sync. An edit to one copy
silently makes traders pay a total the slippage guard never checked.

**Action:** Compute the decomposition once (small summary struct or pass the
three amounts through) so both sites share one derivation. (audit 5de114)

### H-3: Smaller cleanup items

- Dedupe the byte-identical `update_expiry`/`insert_expiry_at` lane-table
  helpers (and shared guard preamble) across the BS forward/SVI/spot feeds into
  a generic `oracle_lane` helper. (audit 7af3ed)
- `fee_incentive_balance` DUSDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry DUSDC has one owner. (audit 49108f)

### H-4: Complete the public-read classify-or-delete pass

**Severity:** Low; `public` signatures freeze at deploy.

Remaining zero-caller `public` reads with no consumer class stated in their doc
comments, per the move.md public-read classification rule: the ~20 propbook
`raw_*` reader families (raw_spot/raw_spot_at/raw_price_magnitude/raw_forward_*/
raw_svi_* across the four feeds) and `pricing::Pricer.expiry_market_id`. For
each family: name the intended consumer class (PTB composition / devInspect /
provenance) in a doc comment, or delete before the deploy snapshot.
(audit 405de8, cb62a2, 88b7b8)

### H-5: Careful trade-flow dedup batch (verify deeply before fixing)

**Severity:** Low, but all four sit on or near the mint/redeem path — not
hygiene-speed changes.

- Pyth canonical-binding check re-implemented in `expiry_market` (:776-783)
  instead of owned by `pricing` — re-home behind one owner. (audit 0622da)
- `mint_exact_amount` prices and admission-validates the same range twice per
  call — verify the second validation is not a distinct fact, then dedupe.
  (audit fb3ec8)
- Four cascading asserts under one `ENetPremiumBudgetTooHigh` exist only to
  pre-empt +1 overflow — verify and collapse. (audit a68338)
- `EReferenceTickTimestampMismatch` re-checks that an exact-timestamp lane read
  returns its own key — decide trust-boundary vs redundant. (audit 914ecd)

### H-6: Maintainability backlog

- Thread the cadence value group (tick_size, admission_tick_size,
  max_expiry_allocation, initial_expiry_cash, window_size) as a named
  `CadenceParams` struct instead of a 5-long u64 run through
  registry → market_manager → event; reshapes the public
  `set_template_cadence_config` signature, so coordinate with the positional TS
  callers. (hygiene sweep)
- `expiry_market` god-module decomposition (trade sequencing / fee decomposition
  / payment settlement / lifecycle in one 1170-line module) — decide a seam or
  consciously accept before the codebase grows further. (audit c3edaa)

## Required Decisions

### G-1: Pause-gate scope for pool cash growth and capital lock

**Severity:** Decision; today's behavior may be intentional.

Two flows mutate pool risk posture without the gates the rule text implies:
`rebalance_expiry_cash`'s grow direction (`top_up_live_expiry_cash`) moves idle
cash INTO a live market while trading is paused (is topping up "new risk
creation"?), and `plp::lock_capital` mints genesis PLP without checking the
valuation lock. Decide whether each is intentionally exempt, then either add
the gate or record the exemption in the settled decisions.
(audit 20aafa, 0e81b3)
