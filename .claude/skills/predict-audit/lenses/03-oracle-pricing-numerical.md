# Lens 03 — Oracle, Pricing & Numerical Integrity

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Oracle, pricing & numerical integrity — the numerically-literate pass. Two equally-weighted jobs: (1) the
**price-trust surface** — every place an externally-supplied price/parameter is ingested and trusted, now
spread across `propbook` + `block_scholes_oracle` + the consumer boundary in `predict::pricing`; (2) the
**fixed-point math** that turns those inputs into DUSDC. A wrong number here is wrong money everywhere
downstream (mint admission, redeem, liquidation trigger, settlement payout, LP NAV) — trace each price to the
DUSDC it moves.

### Part 1 — price ingestion & trust boundaries
For every external input document: who supplies it, what the code verifies vs trusts, freshness/monotonicity
gating, and what a worst-case-but-in-bounds supplier achieves.
- **Pyth Lazer** (`propbook::pyth_feed`): normalization (exponent/decimals/scaling), stale/future/zero gating,
  us→ms conversion, strict-monotonic source-timestamp rule, the exact-timestamp minute history used for
  **settlement**, and what is cryptographically verified upstream vs assumed here.
- **Block-Scholes operator path** (`block_scholes_oracle::update` → `propbook::block_scholes_{spot,forward,svi}_feed`):
  the BS-feed split now lets spot, forward, and SVI arrive at **different update times** with different freshness
  thresholds — trace how the basis (forward/spot) and the SVI surface combine, and whether a skew between them
  is exploitable. `block_scholes_oracle::update` is a **stub** (values operator-supplied, not signature-verified)
  — confirm exactly what gates a push and that nothing outside the trusted operator can reach it.
- **The consumer envelope** (`predict::pricing::load_live_pricer`): the pricing-safe surface check (forward>0,
  basis bounds, |rho|<=1, sigma band, feed freshness, pre-expiry live-pricing gate) is enforced HERE, not in
  propbook. Verify predict enforces **all** of it on **every** priced path; a missing or bypassed check means
  trusting raw operator data. (On-chain basis/deviation drift guards were removed by design — D031 — so do not
  re-flag their absence; do find anything the envelope fails to bound that the removed guards used to.)
- **Settlement**: terminal price = the exact post-expiry Pyth print from propbook minute history; passive,
  first-writer-wins, no operator settle entrypoint. Confirm one trust path cannot pre-empt a stronger one and
  that an off-grid/absent expiry print fails closed (stays unsettled).
- **Binding correctness**: market ↔ underlying ↔ propbook feed (spot/forward/svi) ↔ expiry consistency, and
  where it is (or isn't) enforced.

### Part 2 — fixed-point math correctness (`fixed_math`, `pricing`, `strike_payout_tree`)
- **Rounding DIRECTION audit:** for every mul/div/mul_div/ceil_div on a value path, determine the SAFE
  direction given who it credits/debits (protocol liability vs user entitlement vs collateral). Flag any that
  favors the wrong party; note where dust accrues (ROUNDING_POLICY R2: dust to protocol).
- **Approximation accuracy:** ln/exp/sqrt/normal_cdf — are the documented error bounds sufficient for the price
  ranges used, and do errors compound across SVI → total-variance → CDF → range-price? (See the known
  near-expiry `live_range_probability` conditioning note.)
- **Overflow/truncation:** `i64` magnitude is u64 with u128 intermediates cast back — find extreme
  strike/forward ratios, large quantities, near-sentinel ticks where an intermediate overflows or truncates.
  Distinguish "aborts safely" from "silently wrong."
- **SENTINEL handling:** `pos_inf_tick` (= u64::MAX domain) / `neg_inf` must be intercepted before any finite
  arithmetic; confirm the half-open boundary convention is consistent across pricing, the payout tree, and
  settlement classification (`range_codec`).
- **Degenerate inputs:** zero variance, zero spot, rho/sigma at bounds, basis at bound, tick edges, snap-to-tick.

## Empirical mandate
Use Python (subagent-safe) to: sweep rounding direction across the mul_div call sites with adversarial inputs;
check normal_cdf / SVI-variance accuracy at the extreme price ranges and show the numeric discrepancy; and
fuzz freshness-skew between spot/forward/svi feeds. Localnet only via the main loop.

## Output
Deliver a per-input trust table (input | supplier | verified | trusted | gating | worst-case error) and a
per-operation rounding/overflow table; show concrete inputs + the numeric discrepancy for any math finding.
Separate "manipulable within configured bounds / trusted operator" (a trust note) from "wrong even with honest
inputs" (a code bug). Emit in the primer's report format; end with which inputs/functions you traced to a DUSDC
movement and Top 3. Return structured findings to the orchestrator or write the solo report. Never modify source.
