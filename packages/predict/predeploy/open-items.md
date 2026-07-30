# Predict Predeploy Open Items

Updated 2026-07-29. This is the live work register governed by the [predeploy lifecycle and update rules](./README.md#lifecycle).

## Deploy Gates

### S-5: A client-supplied series id commits to no Block Scholes instrument

**Severity:** Deploy gate.

`block_scholes_sid::encode` packs layout version, kind, Propbook underlying,
value scale, and expiry. It carries nothing about the instrument Block Scholes
resolved — exchange, asset, base/quote, model. The provider signs whatever
series the subscription names, under the id the client supplies, so a valid
signature proves "signed for Propbook underlying N", not "this is the asset
Propbook means by N". Sid-keyed storage closes misrouting of already-signed
data; it does not bind which instrument was signed in the first place.

Consequence: the claim that the relayer is untrusted holds for replay,
reordering, and cross-slot routing, but not for subscription configuration. If a
party able to obtain Block Scholes signatures can request an arbitrary
client-supplied sid, it can have the provider sign one asset's data under
another's slot id and land it as canonical — a path no on-chain check can see,
because the signature and the sid are both exactly what the store expects. The
sid's scale field makes a provider-side rescale a halt; there is no equivalent
for a provider-side instrument mismatch.

This is the accepted cost of client-supplied sids over provider-generated ones
(the alternative was rejected because it needs an on-chain sid→slot table and a
registration transaction per expiry on the market-roll path). It is recorded as
a gate rather than a design change because it is closed by a provider answer,
not by contract code.

**Action:** Before a value-bearing deployment, confirm with Block Scholes that
client-supplied sids are scoped per signing account — that no other subscriber
can request a sid this deployment derives — and record the answer. If they are
globally addressable, close it provider-side (have the signer re-derive the
expected sid from the resolved instrument config and refuse a mismatch) rather
than on-chain. Until answered, the residual trust set in `docs/risks.md` and the
`predict-audit` lens 08 trust boundary must name subscription configuration
alongside data quality, key custody, and pause discretion.

## Contract Findings

### P-23: The Pyth re-anchor can substitute a staler spot than the one it replaces

**Severity:** Medium; on the default pricing path.

`pricing::resolve_live_pricer` enters the re-anchoring branch on the Pyth spot's
own freshness alone and never compares it against
`block_scholes_spot_source_timestamp_ms`, the model time of the Block Scholes
spot it is displacing. The branch exists to carry the Block Scholes basis on a
*higher-frequency* spot, but nothing enforces that the substitute is actually
fresher: with `use_pyth_spot_for_forward` set (the default), a Pyth spot at the
edge of its window can re-anchor a forward whose Block Scholes spot is
sub-second old, and `forward = pyth_spot * bs_forward / bs_spot` then prices the
market at the older of the two clocks. The magnitude is the underlying's move
across the age gap, and the gap widened when the Pyth default moved from 2s to
10s alongside the model-clock cutover. Trade timing is caller-chosen, so this is
an adverse-selection surface rather than a liveness one.

**Action:** Gate the re-anchor on relative freshness — require the Pyth source
timestamp to be at least as recent as the Block Scholes spot model time (or
bound the skew) — or record why substituting a staler spot is acceptable and
what bounds the resulting error.

### P-24: BS spot/forward model-time staleness aborts the pool-wide flush, unregistered

**Severity:** Medium; liveness, unregistered response policy.

Freshness moving from the batch envelope to the per-series model time is the
correct economic reading, but it creates a halt mode the envelope clock did not
have: a series the provider retransmits unchanged keeps its original model time,
so it ages out even while transport is visibly alive. Past the window,
`load_live_pricer` aborts, `plp::value_expiry` aborts with it, and the flush is
one PTB over every active market — so a single un-refreshed series defers every
queued LP fill pool-wide.

RP-21 registers exactly this for SVI at its 60s window. The spot and forward
lane runs the same mechanism at `block_scholes_price_freshness_ms` — 10s by
default, six times tighter — and has no corresponding entry, so the blast-radius
classification for the tighter of the two lanes is undecided rather than
accepted. The flush requires every live market's spot, forward, *and* SVI to be
simultaneously inside their windows, so the exposure compounds across expiries
rather than being per-market.

The supporting measurement does not yet settle it. The harness updater counts
pinned retransmissions per series (`harness/ts/oracleService.ts`) and the first
live run observed 8 pinned forward and 8 pinned SVI retransmissions across 73
pushes, but a count is not the quantity that decides the question — the maximum
*consecutive* pinned age per series is. A 10s window is breached by one run of
pins, and pins cluster in quiet markets rather than arriving independently.

**Action:** Extend the harness probe to report max consecutive pinned age per
series, run it long enough to cover a quiet period, then either register the
spot/forward lane's abort in `response-policies.md` alongside RP-21 with that
measurement as its risk profile, or move the lane down the blast-radius ladder
(skip/carry the affected market rather than aborting the flush).

### P-25: Provider width overflow aborts a mandatory path with no named error

**Severity:** Low; diagnosability and unregistered response.

`pricing::narrow_price` and `narrow_svi` are checked `u128 -> u64` casts, and
they run *before* `assert_inputs_pricing_safe`. A provider value above `u64::MAX`
therefore aborts on the cast with a bare VM arithmetic error rather than the
named envelope code that covers every strictly narrower violation, in a path the
flush must complete. Not adding an assert is correct per the general rule
against wrapping primitive overflow; the gap is that a provider-controlled
variable can abort a mandatory path with an abort code no runbook can map and no
response policy classifies. No test exercises the claim that the narrowing is
the guard.

**Action:** Either return absence from the narrowing and treat an
unrepresentable observation as unavailable (reusing
`EBlockScholesPriceUnavailable`), or keep the cast and register the abort with
the rest of the provider-quality residuals so the operational response is
written down.

### P-26: An underlying's Block Scholes store pair can never be repointed

**Severity:** Low pre-deploy; one-way door after.

`registry::create_and_share_block_scholes_stores` is create-once per underlying
(`EBlockScholesStoresAlreadyExist`) with no admin replacement path, while the
Pyth lane carries `replace_pyth_binding_for_underlying` for exactly this
purpose. The stated reason — that a second pair would leave two stores each able
to claim the underlying with nothing to choose between them — does not hold: the
registry binding *is* what chooses, which is why the Pyth replacement is safe.
If a pair is ever created against the wrong underlying, or becomes unusable
under a future store shape, that underlying has no on-chain route to a working
pair and every market on it is stranded behind a package upgrade. Adding the
setter is free while pre-deploy and impossible to add compatibly later only in
the sense that the absence has to be lived with.

**Action:** Add an admin-gated replacement for an underlying's store pair
mirroring `replace_pyth_binding_for_underlying`, or record the decision that the
pair is deliberately permanent and what the recovery path is if one is wrong.

### P-5: BS zero/non-normalizable updates can blank live reads

**Severity:** Low.

The BS stores keep signed values verbatim, including zero: a signed zero spot or
forward prices as `EBlockScholesInputsInvalid` at the pricing envelope until a
newer batch replaces it. Only the registered Block Scholes signer can produce
such a value, so this is a provider-quality residual, not a relayer surface.

**Action:** Restore write-time nonzero guards for BS spot and forward
observations, or document that the provider guarantees this.

**2026-07-07 extension — settlement lane, permanent brick.** The same
write-time normalizability gap reaches settlement, not just live reads. A
non-normalizable exact-expiry Pyth print (negative, normalizes-to-zero,
u64-overflow, or exponent-shift > 18 — `pyth_feed::normalize_raw_spot` returns
none) inserted at `key == expiry_ms` locks that key forever: the exact-history
lane is first-writer-wins with no overwrite/remove (`oracle_lane::insert_at`).
`expiry_market::try_settle` then
returns false permanently and post-expiry live pricing aborts
(`ELivePricingExpired`), so the market never settles and the pool-wide flush
stays bricked. This defeats RP-4's stated recovery (the permissionless exact-ms
insert followed by `try_settle`) — the later valid insert is silently
dropped. Reachability is low for real major-asset feeds but the failure is
permanent.

**Action (extension):** Extend the proposed write-time nonzero/normalizable
guard to the exact-ms settlement insert (reject a raw that cannot produce a
positive normalized spot before it can claim the key), or add an authorized
overwrite/removal for a non-normalizable exact-expiry read; and extend RP-4 to
cover the permanent (not just transient) case.

### P-11: The coarse SVI envelope admits butterfly-arbitrage-able surfaces that break NAV netting

**Severity:** Open envelope-hardening item; non-blocking for the skew-pricing
correction. No sampled Block Scholes surface triggers it (`g(k) >= 0` over the
scanned band on 4,000 sampled surfaces), and observed `b` is roughly 3,000 times
below the constructed corner. The contract nevertheless accepts the corner
because it bounds each SVI parameter independently and does not enforce
butterfly freedom (`g(k) >= 0`).

**Condition and controller.** The fixed-point counterexample uses an admitted
surface with `a=1`, `b=max_svi_input`, `rho=-1`, `m=0`, and `sigma=min` at a
forward of `100e9`. The trusted surface source controls these inputs; a trader
cannot choose them. Exploitation additionally requires pre-existing offsetting
ranges, a pool flush while the surface is active, and queued LP withdrawals.
Under that surface the adjusted digital is non-monotone. `walk_linear` nets
signed boundary contributions tree-wide and floors once at the aggregate,
whereas `compute_range_price` floors each order at zero; without an active-book
monotonicity guard the tree can therefore net away real liability and make
`current_nav` overstate withdrawable value.

**Economic impact.** The replay uses two ranges with `1e9` raw DUSDC units of
quantity each, a $1,000 face value per range at six decimals. Per-order pricing
returns `0` for `(80e9, 90e9]` and `898,433,481` raw units ($898.433481, or
89.843% of face) for `(95e9, 105e9]`, so the contract's own per-order liability
is $898.433481. `walk_linear` nets the first signed contribution before flooring
and reports `255,159,574` raw units ($255.159574, or 25.516% of face): an
absolute liability understatement of `643,273,907` raw units ($643.273907, or
64.327% of face), which is 71.6% of the per-order liability. `current_nav`
overstates by the same absolute amount; its percentage error depends on the
market's free cash. This is an internal accounting discrepancy, not a claim that
a live contract quote is 64% inaccurate.

**Evidence grade.** The mechanism follows directly from `walk_linear`'s
tree-wide signed netting versus `compute_range_price`'s per-order zero floor;
the numbers above are reproduced by the fixed-point replay. They are a synthetic
accepted-envelope counterexample, not a live-pool measurement or a realistic
loss estimate.

**Action:** Measure a `b`-specific envelope against observed surface history and
evaluate a source-level butterfly/monotonicity admission check. The active-book
price-memo guard prevents the known NAV overstatement by aborting valuation on a
non-monotone active boundary set, so the completed-valuation-discrepancy risk is
closed (only P-13 now describes a live valuation gap). Because the guard
aborts rather than reprices, and the pool flush values every active market in one
transaction, an admitted non-monotone surface now stalls that flush until the
surface is replaced — the residual is a surface-quality admission gap plus this
flush-liveness cost, not a mispriced NAV. Surface quality remains a trusted input
for single-order prices until the stronger envelope lands. (2026-07-09 PR #1110
review; quantitative framing corrected 2026-07-11; active-book guard added by
DBU-548.)

### P-13: Boundary aggregation can understate positive liability by one raw unit

**Severity:** Low.

The payout tree prices and floors each signed boundary contribution before
netting the aggregate, while an individual order floors its range probability
before multiplying by quantity. Those operation orders are not bit-equivalent.
On a normal monotone constant-variance surface, two one-lot ranges sharing an
upper strike price individually at `463 + 410 = 873` raw DUSDC units, while
`strike_payout_tree::walk_linear` produces `9583 + 9530 - 18241 = 872`. The
aggregate live liability is therefore one raw unit below the sum of the two
order liabilities, and `current_nav` is one raw unit high. This is distinct from
P-11's non-monotone-surface netting failure.

**Action:** Decide whether live liability must reproduce per-order rounding. If
yes, preserve per-range rounded terms in the valuation representation. If not,
bound and accept the aggregation residual in the rounding policy, add a
regression covering both directions, and narrow every exact-NAV claim to the
accepted bound. (2026-07-17 clean-room gap audit)

### P-16: The pricing reference does not cover the deployed variance range

**Severity:** Medium.

The ratified price-deviation bound (`response-policies.md § Pricing and valuation
deviation bounds`) is enforced by the generated pricing reference, so it is only
enforced where that dataset has scenarios. The committed scenario corpus is a
single real market whose total variance bottoms out near `w ≈ 4e-7`, while
deployed one-minute and five-minute cadences reach `w ≈ 1e-8` — the regime where
`1/sqrt(w)` conditioning makes the bound tightest and where an evaluation defect
is least likely to show up anywhere else.

This is what let P-14 (short-dated `up_price` biased by the 1e9 variance
truncation, resolved by the u128/1e18 variance path) reach a release candidate:
every scenario the reference could check sat five orders of magnitude above the
regime that was wrong. The generator now carries one short-dated scenario at the
corpus minimum, which demonstrates the fix but is not coverage — it is one point,
and it does not reach `1e-8`.

**Action:** extend the scenario corpus to span the deployed variance range,
including one-minute and five-minute surfaces, so the deviation bound is checked
where it binds. This needs source rows at those cadences; the current CSV does
not contain them, so it is a data-collection task before it is a generator task.

### P-17: A negligible-tail finite boundary mints a payout-tree node for free

**Severity:** Low / fix before deployment, sequenced after C-4.

`max_payout_tree_nodes` is per-market and shared across all users, so filling it
denies new strike ranges to everyone in that market until positions close or the
market expires. The denial is renewable: an actor can hold to expiry and re-apply
on the next market.

What makes it cheap is a degenerate range shape, not the cap itself. Fixing one
near-money lower boundary `L` and varying only the upper across arbitrary
deep-out-of-the-money ticks mints exactly one new node per order, because
`insert_range` counts only boundaries not already present. Every such range prices
at ≈ `P(S > L)`, so each order is a near-certain position carrying no real
directional risk. At the compiled floors (`min_net_premium` 1 DUSDC, entry band
[1%, 99%], `min_fee` 0.5% on quantity) ~999 nodes cost ~1,000 DUSDC of premium that
is ~99% likely to be repaid plus ~5 DUSDC of fees.

Neither guard that looks like it should stop this does. `assert_admitted_mint_ticks`
already forces both boundaries onto the admission grid, but the tick domain is 30
bits, so the grid still admits far more than 1,000 points; admissibility is bounded
economically (the range must price within [1%, 99%]), not combinatorially. A
per-account reservation is sybil-trivial and would need new refcounted per-account
boundary ownership, since the tree keys nodes by tick with no notion of who created
one.

**Direction:** reject a finite boundary whose tail probability is negligible and
require the sentinel instead. A range whose upper boundary carries no meaningful
mass is economically identical to `(lower, +inf]`, and `pos_inf_tick` stores no
node; symmetrically a negligible `P(S <= lower_tick)` must use tick 0, which folds
into `base` and also stores no node. That collapses the cheap shape onto the free
sentinels rather than rate-limiting it, and leaves near-money boundaries, which are
bounded by the probability band and cost real directional risk. The threshold wants
to be derived rather than picked — plausibly tied to `min_entry_probability`, so a
boundary must carry at least as much tail as the smallest admissible range.

**Sequencing:** after C-4. That item sets `max_payout_tree_nodes`, and the two move
in opposite directions — if C-4 forces the cap down to fit one transaction, the tree
fills sooner and this gets cheaper to trigger, while this fix cuts how many nodes
honest books generate and buys the cap headroom back. Sizing the threshold before
the cap is known means picking it twice.

**Provenance:** reported externally as issue 45 (closed as acknowledged and tracked
2026-07-30, with this direction stated to the reporter); the cost model and the
`assert_admitted_mint_ticks` analysis were established while triaging it. Not
reachable on the deployed anchor, which carries no node cap at all — it applies to
`main` and the next deployment.

### P-27: The PLP exit fee ships at 20 bps on a partly-unmeasured basis

**Severity:** Undecided policy. Not a correctness bug — the mechanism is
tested; the open question is whether the rate is right, and whether the leak it
prices is real at all.

A fill at an exact mark is provably value-neutral to incumbents: supplying `D`
into pool value `V` over `S` shares mints `D·S/V`, leaving `V/S` unchanged.
Extraction therefore requires the mark to differ from true recoverable value.
Two facts make that gap non-zero: the certified NAV error is bounded near 1% in
the worst case, and incumbents are involuntary counterparties who cannot
decline a fill or requote it. Whoever chooses when to transact selects against
that error one-directionally.

The counter-argument is that this is ordinary trading, not extraction, and that
a fee only shifts the thresholds a timer needs. That is correct in the limit
where the mark is exact; it is exactly the limit that is not established.

Predict is forward-priced — requests queue before the mark exists — which is
the standard mitigation for the *stale-NAV* form of this problem, so the
residual exposure is mark **error**, not mark **staleness**. That distinction
decides the calibration: the yardstick is the certified error, not the variance
of the share price between flushes.

Shipped state: two independent rates, `plp_supply_fee_rate` (default **0**) and
`plp_withdraw_fee_rate` (default **20 bps**), each in a `0..5%` envelope, charged
on the DUSDC leg of executed fills only and retained by the pool. Both are
admin-tunable to zero without a package upgrade, so shipping enabled is
reversible; widening past 5% is not.

**The basis splits in two, and only one half needs calibrating.**

*Utilization on exit* — the pool's written liabilities do not shrink when an LP
leaves, so the same risk sits on a smaller base and risk per dollar rises for
whoever stays. This needs no adversary and no cleverness, and it is why the
charge belongs on the exit alone: a deposit moves risk the other way. It
justifies a non-zero exit fee on its own, without a measurement.

*Model estimation error* — NAV is cash less what the pool owes, and what it owes
comes from a formula over vendor vol with known mispricing. An active LP can
capture that error at the expense of the LPs who stay. **This is the half that
needs calibrating, and it is what the experiment below is for.** Sizing against
the ~1% certified *arithmetic* bound is the wrong yardstick for it: that bound
is the numerical envelope of the pricer, not the vendor's model error.

The 20 bps default is therefore justified as a floor by the first mechanism and
unvalidated as a ceiling against the second.

**A withdrawer partly refunds their own fee, and the deviation is largest for
the smallest exits.** The charge is retained by the pool, so a withdrawer who is
not fully exiting still owns a share of what they just paid. For a holder of `s`
of `S` shares withdrawing `w` at fee `F`, the net charge is
`F * (1 - post_withdrawal_share)` where the share is `(s - w) / (S - w)`. At
`w = s` the recapture term is exactly zero, so a **full exit pays `F` in full**;
the deviation grows as the exit shrinks relative to what the holder keeps, and
is largest for a holder who still owns much of the pool afterwards. That is the
right direction — the charge bites hardest on the exit that concentrates the most
risk, least on the LP who stays exposed — but any calibration below must target
the *effective* rate at the sizes it is meant to deter, not the nominal one.

The same identity holds on the supply leg, which is one more reason entry ships
at zero: a supplier is a holder the instant the fill lands. Illustrated on that
now-dormant leg, at a 1.0 mark with a 10 DUSDC pool and a 10 DUSDC supply at
20 bps: fee 20_000, shares 9_980_000, post-fill price 20e6/19.98e6, so the new
holding is worth 9_989_989 and the net charge is 10_011 — just over half. In
closed form that is `F * V / (V + n - F)` for a deposit `n` into a pool worth
`V`, equivalently `F * (1 - post_fill_share)`.

**The split roughly halves the shipped cost of the strategy this item exists to
measure.** A round trip costs `F_in * (1 - share) + F_out`; with `F_in = 0` as
shipped that is now just `F_out`, so the timing loop pays a flat 20 bps rather
than the ~40 bps a symmetric 20 bps would have charged a small LP. A pure
outside timer — deposit, wait a flush, exit fully — recaptures nothing on either
leg and pays exactly the nominal exit rate. The measurement below must be read
against that figure, not against the symmetric one the item was first written
for.

**Experiment plan** (decision rule written before the run):

- **Question:** does the realized fill mark deviate from a higher-precision
  reference NAV at fill time, in a direction a submitter can predict at
  *submit* time?
- **Strategy:** drive supply/withdraw against a live book while recording, per
  flush, the realized mark, the reference NAV, and the information available
  one flush earlier. Measure realized round-trip PnL of a timing strategy at
  both LP fee rates at 0, net of gas and a flush of escrow lockup.
- **Blocked on:** the Python parity oracle still models scalar NAV, so there is
  no independent reference to difference the realized mark against. Closing
  that gap is the first step, not the experiment. It also does not model this
  fee at all (`simulations/python_replay.py`, marked in-file), so parity runs
  must stage both LP fee rates at 0 until someone derives the fee independently
  there — copying the Move formula across would make the oracle a mirror of the
  code it is supposed to check.
- **Decision rule:** if zero-fee round-trip PnL is not distinguishable from
  zero at the observed flush cadence, set the default to 0 and keep the knob.
  If it is positive, set the rate above the measured per-lap edge and record
  the measurement as the basis. Either outcome graduates to
  `response-policies.md`; "it feels safer with a fee" does not.

**Note:** the measurement depends on the flush cadence, which is itself
unsettled — the keeper default and this repo's design record disagree, and
every per-day figure in the discussion moves with it. Settle the cadence before
running, or the result is not interpretable.

## Access and Governance

### G-1: Root admin caps have no on-chain revocation or rotation

**Severity:** Deploy decision.

The three root caps — predict `AdminCap`, propbook `RegistryAdminCap`, and
account `AccountAdminCap` — have no on-chain revoke or rotate path (contrast
predict's `registry::revoke_pause_cap` / `revoke_lifecycle_cap`).
Coupled exposures:

- A leaked `AccountAdminCap` is an unrecoverable path to draining all user
  custody: it authorizes apps (`authorize_app`), and account app-auth is
  generic — any co-authorized app can call public `account::withdraw` on any
  predict user's wrapper. `account::load_account_mut` intentionally grants a
  valid `Auth` unrestricted mutable account access, but the deploy-time
  authorization hygiene and the cap-compromise recovery are not an explicit
  item.
- The propbook `RegistryAdminCap` is a *separate* admin domain that can rebind
  an underlying's oracle (`registry::replace_pyth_binding_for_underlying`),
  instantly redirecting and stranding pricing AND
  settlement of all in-flight predict markets, with no timelock and no
  predict-side detection.

**Action:** Before a value-bearing deploy, choose root-cap custody and recovery:
multisig custody plus a rotation/replacement mechanism for each non-rotatable
root cap, or documented acceptance of the cap-compromise and cross-package admin
trust coupling.

## Capacity and Liveness Findings

### C-4: Per-market `value_expiry` node budget is unsized against one transaction

**Severity:** Medium / must be sized or accepted before deployment.

RP-25 removed the *joint* flush budget: valuation is resumable, so each
`value_expiry` carries one market's dynamic-field children instead of the pool's.
The *per-market* budget is now well-posed and unverified. One market's caps do not
obviously fit one transaction's 1,000-child limit: `max_payout_tree_nodes` alone is
1,000, before `ceil(max_active_leveraged_orders / 64)` = 79 liquidation-book pages
and the market's base children. Under the old single-PTB flush one market at 982
nodes already aborted (`evidence/c1-object-cache-flush-2026-07-07.md`), though that
run also carried the rest of the flush's commands, so it bounds the per-market
figure loosely from above and cannot be read as the answer.

**Plan (decision rule pre-registered):** re-run `ts/strategies/treeNodeSweep.ts`
against the resumable flush, filling ONE market and valuing it in its own
transaction, to find the node count at which a single `value_expiry` aborts. If the
measured ceiling is below `max_payout_tree_nodes` + pages + base, lower
`max_payout_tree_nodes` to leave the measured base-child headroom and follow with
one run that reaches the new boundary. If it is above, record the headroom and
close this item with a register entry.

**Note:** the cap is also what deepbookv3 issue #45 reports as a mint-side denial
of new strike ranges; it is a deliberate bound, and whatever number this item
settles on is the one that answer should quote.


## Oracle Calibration

### O-1: Near-expiry oracle miscalibration is exploitable

**Severity:** High if near-expiry markets are enabled without recalibration.

Offline and on-chain tests found high-priced near-expiry binary contracts
systematically underpriced and low-priced contracts systematically overpriced.
See `evidence/o1-oracle-calibration.md`.

**Action:** Recalibrate near-expiry volatility/time-to-expiry behavior or block
the affected near-expiry market shape until the reliability curve is verified.

## Maintainability and Pre-Deploy Hygiene

These are free to fix pre-deploy and breaking (or permanent) after; none block
correctness today.

### H-3: Smaller cleanup items

- `block_scholes_store::belongs` matches only the sid's underlying field, so an
  observation whose layout version, kind, or value scale differs from this
  package's is accepted into the table and then never read — reads derive whole
  ids. A provider-side layout or scale change therefore accumulates unreadable
  rows the writer pays for instead of failing visibly. Matching version and
  scale as well would make it a clean ingestion refusal, which is the halt the
  sid design already intends for a rescale.
- The store tables have no pruning path: every expiry ever quoted leaves a
  permanent row in `values`/`svis`, and neither store can be unwrapped (`key`
  only). Reads stay O(1), so this is unreclaimable storage rather than a
  liveness risk, but it grows monotonically for the life of the deployment.
- `apply_value_batch`/`apply_svi_batch` assert the store version, then
  `apply_value`/`apply_svi` assert it again once per update inside the loop —
  a defensive duplicate and a per-iteration re-check of a loop invariant.
- `fee_incentive_balance` DUSDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry DUSDC has one owner.

### H-6: Maintainability backlog

- Thread the cadence value group (tick_size, admission_tick_size,
  max_expiry_allocation, initial_expiry_cash, window_size) as a named
  `CadenceParams` struct instead of a 5-long u64 run through
  registry → market_manager → event; reshapes the public
  `set_template_cadence_config` signature, so coordinate with the positional TS
  callers.
- `expiry_market` god-module decomposition (trade sequencing / fee decomposition
  / payment settlement / lifecycle in one 1170-line module) — decide a seam or
  consciously accept before the codebase grows further.
- Public `liquidate()` takes an unbounded caller budget — low-priority self-DoS
  probe; needs a raw liquidate builder (`ctx.submitLiquidate`) in the harness.

### H-7: Test-coverage gaps from the PR #1097 review

From the 2026-07-02 full-PR review (all Low; strengthenings, not blockers).

- **RP-3 clamp not directly pinned.** No flush test exercises the sticky-exclusion
  clamp's own trigger (held-out total > a positive-then-collapsed gross). Add a
  flush test that latches positive profit-basis credits (settle a profitable
  market), withdraws idle, then collapses the remaining active mark so
  `exclusion + pending > gross`, and asserts the flush still succeeds at NAV==0.
- **Cadence public-read surface uncovered.** The `market_manager` cadence-config
  getters are retained for SDK and dev-inspect consumers but have zero direct
  test coverage; cover the external values and the enabled/disabled projection.
- **`pricing` forward-absence branch untested.** `EBlockScholesPriceUnavailable`
  is pinned for the spot-absence path but not the forward-absence path; add the
  missing `expected_failure`.
- **One-sided boundary/receiving-side assertions.** The drain rounds-to-zero
  boundaries are tested only on the aborting side; the all-in `max_cost` boundary
  pair (from the now-resolved H-2 fix) pins only a 2-of-4-component decomposition
  (zero builder fee / subsidy). Strengthen each to assert the passing boundary.
  (`unstake_deep` receiving-side assertion — that the account received the DEEP —
  added on PR #1106.)
