# Predict Predeploy Open Items

Updated 2026-07-21. **The single source of truth for open work.** Anything that
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

### S-4: Production Block Scholes verifier must replace the development stub

**Severity:** Deploy gate.

The repository dependency is a development stub and is not the verifier intended
for deployment. Propbook's public BS write paths accept verifier-produced update
objects and rely on their constructor boundary for authenticity; source id,
timestamp, freshness, and Predict's pricing-safe envelope do not replace that
proof. Before a value-bearing deployment, replace the dependency with the
production verifier and confirm the scoped contracts still bind the authenticated
payload to the expected source.

## Contract Findings

### P-2: Near-expiry SVI freshness can overprice tails

**Severity:** Medium.

SVI total variance is consumed as variance-to-expiry, but the SVI freshness
window is much wider than the final seconds/minutes before expiry. A stale but
fresh-enough surface near expiry can materially overstate remaining uncertainty
and misprice mint/redeem flows. The SVI skew-adjusted digital term shares this
near-expiry sensitivity through its `1/sqrt(w)` denominator.

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

### P-10: current_nav's conservative liquidation band is absent from public risk disclosure

**Severity:** Low.

Liquidatable-but-still-active leveraged orders (live gross in
`(floor, floor/ltv]`) are marked at holder value (gross-floor) by
`liquidation_book::correction_value`'s min-cap, and `plp::value_expiry` runs no
pre-valuation liquidation pass, so `expiry_market::current_nav` understates
recoverable value by up to the LTV buffer. This contradicts the settled "exact
`current_nav`, no conservative band" framing (RP-1 reasoning) and dilutes
incumbent LPs on a same-flush supply (NAV reads low → the supplier mints too many
shares). P-13 tracks the opposite, rounding-only direction where aggregate
liability is one raw unit low.

**Action:** Decide whether to accept and disclose the conservative band in
`docs/risks.md` (reconciling the "exact NAV" framing), or run a
pre-valuation liquidation pass so the flush marks liquidatable orders at their
liquidated value.

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
closed (only P-10 and P-13 now describe live valuation gaps). Because the guard
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
P-11's non-monotone-surface netting failure and P-10's conservative low-NAV band.

**Action:** Decide whether live liability must reproduce per-order rounding. If
yes, preserve per-range rounded terms in the valuation representation. If not,
bound and accept the aggregation residual in the rounding policy, add a
regression covering both directions, and narrow every exact-NAV claim to the
accepted bound. (2026-07-17 clean-room gap audit)

### P-14: Per-order floor correction can overstate live liability

**Severity:** Low.

`current_nav` subtracts a boundary-aggregated linear value and a correction that is rounded independently for each active leveraged order. When several positions in the same range become liquidatable, each position can have zero recoverable value while the differently rounded aggregate retains a positive liability. The pinned production flow creates four such positions and observes NAV two raw DUSDC units below independently recoverable free cash. The residual can grow by less than one raw unit per active leveraged order, or less than 0.005 DUSDC at the 5,000-order cap, but its direction understates the LP supply mark and can dilute existing LPs.

**Known RED test:** `deepbook_predict::scope_flow__intent_rounding__current_nav_red_tests::liquidatable_orders_leave_positive_aggregate_live_liability`

**Action:** Compute the live floor correction at the same aggregation granularity as the boundary-linear term, or preserve per-order rounded liability through both terms. Keep the exact NAV invariant and its LP-favorable rounding direction when choosing the representation.

### P-15: The knock-out decision is taken on a point estimate, so pricing error can decide it

**Severity:** High.

`strike_exposure::under_liquidation_floor` liquidates a leveraged order when its computed gross value is at or below `floor(floor_amount * 1e9 / liquidation_ltv)`. The comparison treats the computed range probability as the position's value, but that probability is a fixed-point approximation of the pricing model, and the package's own reference data certifies the approximation error at up to 3,610 units at 1e9 scale. Scaled by position quantity, the error spans many whole DUSDC units, so a knock-out threshold can fall strictly between the computed gross and the true gross. When it does, the liquidation decision is determined by the sign of the approximation error rather than by whether the position is actually solvent.

The consequence is not proportional to the error. A knocked-out holder forfeits their entire equity above the floor, so an error of a few parts per hundred million can cost a position its whole remaining value. The pinned flow holds a 1e9-quantity contract on `(90, 110]` whose committed floor is 581,663,191, giving a knock-out threshold of 684,309,636. The computed gross on the reference surface is 684,309,632 — at or below the threshold, so the contract knocks the order out and pays zero — while the independently computed true gross is 684,309,642, above the threshold, leaving the holder solvent and owed 102,646,451 raw units, roughly ten percent of the position. The same band is reachable in the opposite direction, where the pool carries a position past its true knock-out point and absorbs the shortfall.

This is distinct from the rounding policy's dust concerns (R1, R2), which govern how money-moving expressions round. No policy currently governs how a *discrete* decision behaves when its inputs carry certified approximation error, and the decision has no directional bias: it is as likely to harm the holder as the pool.

**Known RED test:** `deepbook_predict::scope_flow__intent_rounding__knockout_decision_tests::knockout_threshold_inside_the_pricing_error_band_forfeits_real_equity`
The test grants the payout its full certified pricing error and the close fee before asserting, so it fails only on the classification, never on payout dust.

**Action:** Give the knock-out predicate an explicit direction under uncertainty rather than a point comparison — evaluate the threshold test against a bound on the price that makes the answer definite, so an order that might be above its threshold is never knocked out, and record the residual (the pool carries a possibly-liquidatable order for one valuation cycle) as the accepted side. The same treatment applies to every other discrete comparison over a computed price. If instead the point estimate is retained, the decision needs a registered response policy stating who bears the misclassification and why the exposure is acceptable at the certified error bound.

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

- Dedupe the byte-identical `update_expiry`/`insert_expiry_at` lane-table
  helpers (and shared guard preamble) across the BS forward/SVI/spot feeds into
  a generic `oracle_lane` helper.
- `fee_incentive_balance` DUSDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry DUSDC has one owner.

### H-5: Premium-budget mint omits probability and all-in-cost slippage caps

**Severity:** Low.

`expiry_market::mint_exact_amount` disables both slippage guards (`max_cost` and
`max_probability` are unbounded), unlike `mint_exact_quantity`. Decide whether
a premium-budget mint should also bound total fees/penalty and entry probability,
and add optional guards if so.

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
- **EWMA gas-price arithmetic has narrow protocol headroom.** The squared-deviation fold fits at gas price 135,818 and overflows at 135,819. A boundary test pins those adjacent arithmetic inputs; whether the overflow is reachable in a transaction depends on Sui's maximum admissible gas price. If that protocol limit reaches the boundary, every mint and live redeem can self-abort before the feature-enable flag is consulted because the EWMA state update always runs.
- **Settlement does not carry the valuation lock used by other market mutations.** `try_settle` can be called between per-market valuation commands in the same operator PTB even though the documented sequence describes settlement as a separate PTB step. No permissionless exploit is established because the lock is transaction-local and the flush operator is already trusted, but the code and sequencing contract should either enforce the same lock or explicitly permit this interleaving.
- **Expired-unsettled markets are outside the live-market cap but remain in the flush walk.** The creation cap counts only pre-expiry markets, while an expired market stays in the pool's active index until it settles and is swept. A settlement outage can therefore accumulate an expired backlog and still admit the full live-market allowance; once settlement resumes, the one-PTB flush can be asked to walk more markets than the cap names. The backlog is recoverable through permissionless per-market rebalance before the flush, but the cap is not a bound on the flush's complete active set.
