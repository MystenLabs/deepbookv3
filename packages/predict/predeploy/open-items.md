# Predict Predeploy Open Items

Updated 2026-08-05. This is the live work register governed by the [predeploy lifecycle and update rules](./README.md#lifecycle).

## Deploy Gates

### S-7: Predict cannot resolve a mainnet publication graph

**Severity:** Deploy gate.

Neither `packages/predict/Move.toml` nor `packages/propbook/Move.toml` could
link a mainnet publish: of the external dependency identities a mainnet publish
needs, two do not exist anywhere. `[dep-replacements.mainnet]` now carries the
resolvable half — `pyth_lazer` and `wormhole`, verified on chain 2026-08-06 —
and `packages/token/Published.toml` already records a mainnet entry. The rest
is open, and none of it is a manifest fix:

- **`bs_oracle` and `bs_sid` are unpublished on mainnet.** The pinned upstream
  revision's publication metadata records testnet only. Closed by the provider
  publishing to mainnet and handing over the package identity, the same
  handover the signer-custody confirmation waits on.
- **`dusdc` is unpublished on mainnet.** `packages/dusdc/Published.toml` is
  testnet-only and records that its `UpgradeCap` is not held here, so it cannot be
  republished to make a mainnet graph resolve. Which asset is the mainnet
  quote/collateral is an open decision upstream of this gate.
- **The `pyth_lazer` source pin lags the deployed mainnet package.** The pinned
  revision predates mainnet version 2, which adds a `channel_v2` module the pin
  does not carry. Linking is upgrade-compatible, but the pin must be advanced
  and the bytecode reproduced before a mainnet publish is verified — and the
  same revision serves testnet, which is live, so advancing it is its own
  change with its own testnet re-verification.

**Action:** Do not attempt a mainnet publish while any identity above is
missing, and never resolve one with `--with-unpublished-dependencies`: that
republishes packages this repo does not own and changes their type identity.
Close this gate by recording each identity as it lands, then re-resolving both
manifests against a mainnet environment.

**Adjacent testnet observation, not part of this gate.** The linked testnet
`pyth_lazer` and the deployment Pyth currently documents are both version 1 of
*separate* lineages — Pyth republished rather than upgraded — so the linked
package is superseded though still live. Whether the relayer and the live
testnet deployment should move to the current lineage is an open question for
whoever owns the next testnet republish.

## Contract Findings

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

### C-1: Full-pool flush has no joint valuation budget

**Severity:** Medium / must be accepted or fixed before deployment.

The flush values every active market in one PTB. Current independent caps
(`24` live markets, `1000` payout nodes, `5000` leveraged orders per market) do
not compose into a single-PTB budget — and the binding limit is object-count,
not compute (corrected 2026-07-07; see the model below). The NAV price memo
removed the single-market pre-cap OOG; the remaining deploy blocker is the
pool-total case. The missing bound is a joint sum across all active markets, not
another isolated per-market cap.

**Capacity model (corrected 2026-07-07 — the binding wall is object-count, not compute):**

- The binding wall for the pool total is the Sui **object-runtime cached-objects
  limit: 1,000 dynamic-field child objects per transaction**
  (`object_runtime_max_num_cached_objects`; a protocol constant, taken as
  network-invariant). The flush loads each market's payout-tree nodes and
  liquidation-book pages as dynamic-field children, and the object-runtime cache
  **accumulates across every `value_expiry` command in the one PTB**. On overflow
  it aborts `MEMORY_LIMIT_EXCEEDED` inside `dynamic_field::borrow_child_object` —
  a framework error whose true cause is this limit. It binds at 16–50% of the 5M
  compute cap, so the pool flush is object-count-bound, not computation-bound
  (`evidence/c1-object-cache-flush-2026-07-07.md`).
- Driver = distinct payout-tree nodes: one `Table<tick,PayoutNode>` child per
  distinct strike tick, and `walk_linear` loads every node. Node count = distinct
  ticks, NOT order count (the tree aggregates by boundary) — which is why
  single-market runs at narrow strikes never reached it despite large books.
  Liquidation-book pages (`ceil(leveraged_orders / 64)`) are a minor contributor.
- Confirmed cumulative, not per-command: two 1× markets at 586 nodes each —
  neither near 1,000 — abort the flush at ~1,172 combined; a single 1× market
  crosses at ~982 nodes (`evidence/c1-object-cache-flush-2026-07-07.md`).
- Superseded conclusion: the 2026-07-01 model called the flush
  computation-bound. That holds for the SINGLE market (a full 5,000-order book
  values at ~47–54% of the compute cap, `evidence/c1-price-memo-2026-07-01.md`;
  pre-memo that single market OOG'd at ~4,580 orders,
  `evidence/c1-nav-stress-2026-06-30.md`) but not the pool total. Earlier
  pool-total runs hit
  `expiry_cash::EInsufficientCash` (capital) at ~92% compute before reaching the
  object wall; raising the allocation cap removed that mask and exposed the
  1,000-child limit.
- Skew-adjusted pricing re-measured the single-market compute cost on 2026-07-09:
  the per-order flush slope rose 2.2% (~480K → ~491K computation units) and a
  full 5,000-order book used 51% of the compute wall. This does not change the
  pool-total conclusion above: the object-cache limit binds first
  (`evidence/c1-skew-gas-2026-07-09.md`).
- Expired-unswept markets leave the active set only inside a successful
  `value_expiry`/sweep, so the flush's active tail is not bounded by the
  live-market creation cap.
- Capacity law:
  `sum_over_active_markets(distinct_ticks + ceil(leveraged_orders / 64) + base_children)
  < 1,000 dynamic-field children per flush PTB` — a joint sum across all active
  markets, dominated by distinct strike ticks.

**Fix options (reframed for the object-count wall):** shrink the per-market
NAV-walk child footprint (e.g. cache tree aggregates so `walk_linear` need not
load every node) · a joint active-market×node budget enforced at creation/roll ·
valuation resumable across PTBs (partial state instead of a hot potato) · an
out-of-flush settled sweep/deactivate path (bounds the active tail) · documented
operator throttling (an off-chain acceptance, not an on-chain guarantee).

**Plan — runs that finish the number (decision rules pre-registered
2026-07-02):**

The binding wall is now identified (object-cache, 2026-07-07 above); the compute
runs below are superseded for the pool total (compute is not the wall), and what
remains open is the FIX, not the measurement. Retained for context:

- Historical payout-tree probes — DONE 2026-07-07: filling one 1× market to the node cap
  and two markets to 586 each proved the pool-total wall is the object-runtime
  cached-objects limit, cumulative across the PTB, not compute
  (`evidence/c1-object-cache-flush-2026-07-07.md`). The `c_node`/compute terms are
  moot for the pool total — object count binds first.
- Historical worst-branch and pool-total compute probes are superseded by the object-count result above, and their one-off strategy files were retired. If a fix needs a fresh boundary measurement, extend the retained `packages/predict/harness/ts/strategies/capacity.ts` family rather than restoring the old probes.
- Any final cap change is followed by one run that reaches the new boundary
  and proves the flush stays under the safety target.

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

- The store tables have no pruning path: every expiry ever quoted leaves a
  permanent row in `values`/`svis`, and neither store can be unwrapped (`key`
  only). Reads stay O(1), so this is unreclaimable storage rather than a
  liveness risk, but it grows monotonically for the life of the deployment.
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
