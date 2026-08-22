# Admission-coordinate ladder — notebook specification

> **Status:** Specification for the experiment that decides whether the frozen-grid coordinate is worth building. [P-32](../../predeploy/open-items.md#p-32-implement-frozen-grid-inventory-impact) owns the decision. Follows [the value-ceiling experiment](inventory_impact_value_ceiling_spec.md), which established that concentration is worth addressing without saying what to compute.

## Question

> Which admission statistic earns its on-chain state, and does a cap remove the need for a fee?

## Two assumptions fixed before the run

- **A refused trader does not trade.** No relocation and no substitution to a neighbouring range, so refusal forgoes that trade's income permanently. This removes elasticity from every cap result.
- **A fee compensates rather than deters.** It must leave PLPs whole when the trader piles on anyway, so no result may depend on a trader responding to price.

## Level caps, not increment caps

Every rule is a cap on a statistic of the **resulting whole book**. A threshold on the per-trade increment is defeated by splitting one order into many, because a threshold is nonlinear in slice size. A level cap is indifferent to slicing.

The converse also holds and matters for the fee: a charge *linear* in marginal capital telescopes, so `Σ ΔK` over any slicing of the same final book equals `K_final − K_0`. Linear charges are split-resistant without needing a level formulation, and the notebook verifies this numerically rather than asserting it.

## The ladder

Candidates differ along three axes: centering, tail shape, and how regions are defined.

| Rung | Statistic | New on-chain state |
| --- | --- | --- |
| A | `mean(top 5 bucket maxima) − E[payout]` | 100-bucket grid, top-five scan, `E_frozen`, verified snapshot |
| B | `mean(top 5 bucket maxima)` | grid and scan, no `E_frozen` |
| C | `max(payout) − E[payout]` | two scalars |
| D | `max(payout)` | none — the shipped payout-liability cap |
| E | `max over equal-price-width regions of mean payout` | region sums; no probabilities, so nothing goes stale |

Rung D is the null hypothesis and must be taken seriously: `L` already rises roughly dollar-for-dollar on a same-range pile-on. Its known defect is that it also scores a *fully funded* book at full payout even though such a book carries no risk.

## Method requirements

- **The objective is never the statistic under test.** Grade every rung on true `K` over 2,000 equal-probability settlement cells. Grading a coordinate on itself is circular.
- **Equal cost, compare benefit.** Thresholds have different units across rungs, so calibrate each to refuse the same volume and then compare capital removed. Report achieved volume so comparability is checkable.
- **Calibrate by grid search, not bisection.** Accepting an earlier trade changes the book and can cause a later refusal a tighter cap would have avoided, so volume kept is not guaranteed monotone in the threshold.
- **Compare rungs as paired per-seed contrasts.** All rungs see identical markets, so differences must be tested pairwise with a standard error; comparing group means wastes most of the power and invites reading noise as signal.
- **Sweep the assumptions that can reverse the result**, not only those that scale it: cap tightness, clustering, book thickness, and the share of flow wide enough to fund the book.

## Exercising the null's known defect

Ordinary generated flow never builds a funded book, so `L`'s defect goes untested unless the notebook forces it. A `wide fraction` parameter mixes in ranges covering 40% to 80% of probability mass, raising the book's funded floor. Report mean payout as a share of peak alongside each result so the reader can see the regime rather than trust the label.

## Fee section

Requiring `(F+f)/(K+ΔK) ≥ F/K` gives `f ≥ (F/K)·ΔK`. The compensating charge is therefore a flat rate on marginal capital, and the rate is a return on capital — no scale, no curvature, no cap, no refunds. Only capital-unit coordinates can carry such a rate, so rungs B, D, and E are cap-only.

Report the delivered return on capital against the configured rate. It will exceed it, for two one-directional reasons that must both be stated: refusing rebates makes reversals additive, and every implementable coordinate overstates true capital. The rate is a floor, not a dial. Also report the charge as a multiple of base-fee income and the rate implied by a target surcharge, since that is the calibration question anyone will actually ask.

## Non-claims

- Generated flow, so the ranking is conditional on the flow model; the sweeps bound that exposure but do not remove it.
- Says nothing about frozen-versus-live staleness, adverse selection, or gas.
- Assumes a refused trader is lost entirely, which understates a cap if refused traders would have accepted a different range.
