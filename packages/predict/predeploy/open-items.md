# Predict Predeploy Open Items

Updated 2026-07-29. **The single source of truth for open work.** Anything that
needs conscious attention — a bug, a suspicion, an undecided question, an audit
finding — lands here first; if it is not on this list, it does not need
addressing. An item that needs measurement carries its experiment plan inline
(question, harness strategy, decision rule written before the run); run results
land as immutable dated records in `evidence/`. An item exits only by deletion
in the PR that resolves it; if the resolution embodied a judgment call, the
decision graduates to `response-policies.md`. There is no third destination.
Raw audit output stays in ignored agent scratchpads; this file is the tracked
manifest.

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

- Payout-tree probe — DONE 2026-07-07 (`ts/strategies/treeNodeSweep.ts`,
  `ts/strategies/treeNodeCumulative.ts`): filling one 1× market to the node cap
  and two markets to 586 each proved the pool-total wall is the object-runtime
  cached-objects limit, cumulative across the PTB, not compute
  (`evidence/c1-object-cache-flush-2026-07-07.md`). The `c_node`/compute terms are
  moot for the pool total — object count binds first.
- Worst-branch per-order cost (`ts/strategies/navStressAtm.ts`): the measured
  expensive-branch (`exp_series`, moderate moneyness) cost replaces the
  fuzz-derived ~3,644 units/order in the cap sizing; if the joint budget at
  current caps exceeds ~60% of the wall, cap tightening becomes a deploy
  blocker. Verify the branch was reached via the gas-by-moneyness buckets.
- Pool-total confirmation (`ts/strategies/navStressMulti.ts` or the faster
  `ts/strategies/batchMaxMarkets.ts`): confirms the binding constraint is the
  sum over markets under one wall and measures the per-market base. Size LP
  capital first so `EInsufficientCash` does not bound the book before flush
  gas does.
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
