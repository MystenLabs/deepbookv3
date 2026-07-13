# Predict Predeploy Open Items

Updated 2026-07-07. **The single source of truth for open work.** Anything that
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

**2026-07-07 extension — settlement lane, permanent brick.** The same
write-time normalizability gap reaches settlement, not just live reads. A
non-normalizable exact-expiry Pyth print (negative, normalizes-to-zero,
u64-overflow, or exponent-shift > 18 — `normalize_raw_spot` returns none,
pyth_feed.move:281-308) inserted at `key == expiry_ms` locks that key forever:
the exact-history lane is first-writer-wins with no overwrite/remove
(oracle_lane.move:130). `ensure_settled` (expiry_market.move:698-720) then
returns false permanently and post-expiry live pricing aborts
(`ELivePricingExpired`), so the market never settles and the pool-wide flush
stays bricked. This defeats RP-4's stated recovery (the permissionless exact-ms
insert followed by passive settlement) — the later valid insert is silently
dropped. Reachability is low for real major-asset feeds but the failure is
permanent.

**Action (extension):** Extend the proposed write-time nonzero/normalizable
guard to the exact-ms settlement insert (reject a raw that cannot produce a
positive normalized spot before it can claim the key), or add an authorized
overwrite/removal for a non-normalizable exact-expiry read; and extend RP-4 to
cover the permanent (not just transient) case. (audit 4d2a1e)

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

**2026-07-07 extension — the cut is order-dependent, not just accrue-only.**
The protocol cut is realized against a single pool-wide, forward-only
`net_losses_to_fill` (pool_accounting.move:36): a loss grows it (:240) and only
a *later* profit shrinks it (:245,:249) — a loss never claws back a cut already
materialized from an earlier profit. Because cross-market materialization order
is permissionless (`rebalance_expiry_cash` → `sweep_settled_expiry` →
`materialize_expiry_profit`, plp.move:412), a profit-first ordering splits
`share × (gross profit recognized before losses)` into
`protocol_reserve_balance` (join-only, plp.move:814,929 — never split, matching
this item's accrue-only claim) instead of `share × net pool profit`. Lens split
this run: the lifecycle sim called it an LP leak (High), while the
invariants-lens 40k-scenario fuzz and one cross-model verifier found it
NAV-neutral under fair live marking (the cut is pre-reserved in
`lp_pool_value`'s exclusion, plp.move:713-737) — the excess only bites when the
offsetting loss market is *settled-but-unswept* at the profit-first instant, a
narrow ordering window. Panel severity: Medium.

**Action (extension):** Fold into the accrue-only deploy decision — take the
cut against NET realized pool profit (a pool-level net-profit high-water mark
realizing the incremental cut of the running net), or make `net_losses`
symmetrically reduce not-yet-realized/pending protocol profit before any cut is
split. Verify with a cross-market Move flow test: value/sweep a profitable
market before an offsetting lossy one and assert
`protocol_reserve == share × net` (expected to fail at HEAD). (audit db0506)

### P-10: current_nav carries an undocumented conservative band

**Severity:** Low.

Liquidatable-but-still-active leveraged orders (live gross in
`(floor, floor/ltv]`) are marked at holder value (gross-floor) by
`correction_value`'s min-cap (liquidation_book.move:85-99), and `value_expiry`
runs no pre-valuation liquidation pass (plp.move:244-279), so `current_nav`
(expiry_market.move:247-257) understates recoverable value by up to the LTV
buffer. This contradicts the settled "exact `current_nav`, no conservative
band" framing (RP-1 reasoning) and dilutes incumbent LPs on a same-flush supply
(NAV reads low → the supplier mints too many shares). Distinct from the ~1-ulp
aggregation-dust *over*-statement (walk_linear per-node end-term) also flagged
this run.

**Action:** Decide and document — either accept and disclose the conservative
band in `docs/risks.md` (reconciling the "exact NAV" framing), or run a
pre-valuation liquidation pass so the flush marks liquidatable orders at their
liquidated value. (2026-07-07 holistic audit)

### P-11: The pricing-safe envelope does not bound the value it is trusted to bound

**Severity:** Low (liveness hardening; enabled by S-4, adjacent to P-5).

RP-5 describes the surviving static envelope as guaranteeing "positive
spot/forward, bounded basis, bounded SVI inputs". That guarantee does not hold
for the number actually priced. `assert_inputs_pricing_safe`
(pricing/pricing.move:300-316) validates the **raw** `bs_spot`/`bs_forward` at
the call site on :267 — but when a fresh Pyth spot is present, `live_inputs`
then *recomputes* the forward as `math::mul(spot, math::div(bs_forward,
bs_spot))` (:287) and returns it with **no re-validation**. A `bs_forward` small
enough that the fixed-point `div` floors to zero yields `forward == 0`, which
the envelope swore was impossible, and pricing aborts downstream at
`EZeroForward` (:346).

The envelope is also one-sided on variance: `a` and `b` are bounded only from
above (:308-309) and the only floor is on `sigma` (:312-315), which never enters
`total_var`. So an in-envelope `a = 0, b = 0` gives `total_var = a + wing_var =
0` (:382) → `EZeroVariance` (:383).

Neither is a standalone exploit: the enabler is the S-4 stub (BS pushes are
permissionless while the verifier is a stub), and recovery is permissionless —
any strictly-newer valid push unbricks it. But `value_expiry` prices every live
market in one PTB with no per-market skip, so one degenerate market aborts the
whole pool flush. Distinct code path from P-5's zero-blanking.

Note the *ceiling* asymmetry here is deliberate and must not be "fixed": the
comment at :281-286 explains that re-bounding the re-anchored forward to
`max_pricing_spot` would abort legitimate high-contango reads (R1 liveness).
That reasoning addresses the upper bound only and never considered the lower
bound.

**Action:** Close the gap with a clamp, not an assert. RP-5's reasoning rules out
the obvious fix — a state-triggered abort over an externally-controlled variable
is exactly the guard class it removed, and a new abort on this shared/mandatory
path (every mint/redeem/NAV read) would need its own `response-policies.md`
entry. Floor the re-anchored forward to a minimum basis and `total_var` to a
positive minimum, so the `EZeroForward`/`EZeroVariance` asserts become genuinely
unreachable from in-envelope inputs as RP-5 already claims. Then either way,
correct RP-5's envelope description to match what the code enforces. Add
boundary tests for `a = b = 0` and for a `bs_forward`/`bs_spot` ratio that floors
the re-anchored forward. (audit 2026-07-02, re-verified at `7911100b`)

### P-12: BS forward re-anchor has no cross-feed observation coherence

**Severity:** Low; accept-and-disclose candidate under RP-5.

`live_inputs` reads the shared per-underlying `bs_spot` and the per-expiry
`bs_forward` from two independent feeds, each carrying only its own freshness
check (pricing/pricing.move:229-253), then reconstructs the basis from the pair
at :287 with no check that the two describe the same observation. The oracle
split turned what was a per-expiry structural coherence guarantee into an
operator-discipline requirement: an operator that advances `bs_spot` without
re-pushing an expiry's still-fresh `bs_forward` produces an incoherent basis and
a mispriced forward, with both feeds passing every check.

No trader can induce this, and an adversarial operator can already steer price
anywhere inside the envelope by construction (RP-5), so this adds no attack
surface — it is operator-trust residual only. A stronger "atomic (spot, forward)"
fund-loss framing was **refuted** during the audit: the `mul(spot, div(bs_forward,
bs_spot))` reconstruction predates the oracle split, so the split introduced no
new exploit.

**Action:** This is precisely the "cross-feed sanity band" RP-5 defers, so honor
its reopen condition rather than re-litigating it: revisit once the production
verifier lands (S-4), and if a check is then worth having, implement it as a
**skip, not an abort**. The abort-free alternative available today is to remove
the coherence question at the source — store the basis *ratio* atomically at push
time so `bs_spot` and `bs_forward` cannot disagree. Otherwise, accept and
document the operator's atomic-push requirement (a coherent `bs_spot` plus all
per-expiry forwards each cadence tick) as a register entry.
(audit 2026-07-02, re-verified at `7911100b`)

## Access and Governance

### G-1: Root admin caps have no on-chain revocation or rotation

**Severity:** Deploy decision.

The three root caps — predict `AdminCap` (admin.move:13), propbook
`RegistryAdminCap` (registry.move:67), and account `AccountAdminCap`
(account_registry.move:25) — have no on-chain revoke or rotate path (contrast
predict's `revoke_pause_cap` / `revoke_lifecycle_cap`, registry.move:86,111).
Coupled exposures:

- A leaked `AccountAdminCap` is an unrecoverable path to draining all user
  custody: it authorizes apps (`authorize_app`), and account app-auth is
  generic — any co-authorized app can call public `account::withdraw` on any
  predict user's wrapper (account.move:131-139). AGENTS.md:106 records the
  full-account app-auth as intentional, but the deploy-time authorization
  hygiene and the cap-compromise recovery are not an explicit item.
- The propbook `RegistryAdminCap` is a *separate* admin domain that can rebind
  an underlying's oracle (`replace_pyth_binding_for_underlying`,
  registry.move:365-377), instantly redirecting and stranding pricing AND
  settlement of all in-flight predict markets, with no timelock and no
  predict-side detection.

**Action:** Before a value-bearing deploy, decide the governance posture —
multisig custody of each root cap, an allowlist-revocation for authorized apps
(as the derived caps already have), and/or documented acceptance of the
cross-package admin trust coupling. (2026-07-07 holistic audit)

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

**2026-07-02 extension — the opposite (overflow) boundary is also uncovered.**
At a dust-but-nonzero mark (reachable via `lp_pool_value`'s zero-floor path), a
large-enough queued supply request makes
`supply_shares = mul_div_down(amount, total_supply, pool_value)` exceed u64 and
the flush dies on `math::mul_div_down`'s raw u64 cast — an untracked arithmetic
abort, not `EInvalidDrainMark`. A smaller request that fits mints ~1e18 shares;
`total_supply` only shrinks via withdrawals, so the inflated supply persists
after NAV recovers, permanently pinning PLP price at dust and progressively
widening the overflow band (one dust fill converts a micro-DUSDC fragile window
into a thousands-of-DUSDC one). The P-1 circuit breaker deleted in `cc67ed9f`
was incidentally the only u64-headroom bound on this math. See
`response-policies.md` RP-1/RP-2.

**Action:** Treat zero-value fills as skip/auto-cancel-and-refund instead of
aborting, and reserve `EInvalidDrainMark` for genuinely invalid marks (or split
the error codes and add an eviction path for degenerate head requests). The fix
must compute fills in u128 and classify "does not fit u64" the same as "rounds
to zero" (skip, never abort), add boundary tests on both sides of each
classification, and decide whether supply fills execute at all below an
executable mark price (ratchet prevention — never mint into a degenerate
ratio). Design this together with the P-7 limit-field policy, which already
needs a stay-queued/skip decision for missed limits. (audit 11767b; overflow
extension from the 2026-07-02 sweep)

**Plan — harness measurement (decision rules pre-registered 2026-07-02; both
blocked on the scripted-oracle harness extension — approach (a), designed
against `oracleService.ts`, keeps the one-stream updater invariant):**

- LP-adversary campaign (drives this item, RP-2/RP-3, and P-7's queued-request
  mark exposure): drive the NAV mark with a scripted trajectory (inflate → LPs
  withdraw idle → collapse → sticky exclusion exceeds gross → NAV=0) and
  observe the queues; the `EInvalidDrainMark` abort is the brick signal. If a
  degenerate flush sample is reachable with realistic oracle motion, RP-2's
  risk profile flips BEST-GUESS → MEASURED and this fix escalates; a clean
  campaign bounds (does not close) the organic-reachability estimate.
- Dust-mark-window campaign (drives the overflow extension): measure the
  fragile band's real width — how long `lp_pool_value` sits where a queued
  fill would overflow u64 or mint ratchet-scale shares, and what the cheapest
  (young, small-pool) entry looks like. If no sampled flush lands in the band
  at mature-pool scale and the young-pool entry cannot be produced organically,
  RP-2 keeps BEST-GUESS with a measured lower bound; if any flush samples
  inside the band, this fix becomes a deploy gate. The Move boundary tests
  (`lp_book_tests`) pin the exact edges; this measures reachability dynamics
  only.

## Oracle Calibration

### O-1: Near-expiry oracle miscalibration is exploitable

**Severity:** High if near-expiry markets are enabled without recalibration.

Offline and on-chain tests found high-priced near-expiry binary contracts
systematically underpriced and low-priced contracts systematically overpriced.
See `evidence/o1-oracle-calibration.md`.

**Action:** Recalibrate near-expiry volatility/time-to-expiry behavior or block
the affected near-expiry market shape until the reliability curve is verified.

## Maintainability and Pre-Deploy Hygiene

From the 2026-07-02 mini audit sweep (HEAD b34b0cd4). These are free to fix
pre-deploy and breaking (or permanent) after; none block correctness today.

### H-3: Smaller cleanup items

- Dedupe the byte-identical `update_expiry`/`insert_expiry_at` lane-table
  helpers (and shared guard preamble) across the BS forward/SVI/spot feeds into
  a generic `oracle_lane` helper. (audit 7af3ed)
- `fee_incentive_balance` DUSDC custody sits on `ExpiryMarket` outside the
  `ExpiryCash` solvency invariant — consider folding it into the custody
  component so per-expiry DUSDC has one owner. (audit 49108f)

### H-5: Careful trade-flow dedup batch (verify deeply before fixing)

**Severity:** Low, but all four sit on or near the mint/redeem path — not
hygiene-speed changes.

- Pyth canonical-binding check re-implemented in `expiry_market` (:776-783)
  instead of owned by `pricing` — re-home behind one owner. (audit 0622da)
- Same re-home question one altitude up: `market_manager::next_deployable_market`
  runs the four propbook feed-binding asserts itself
  (registry/market_manager.move:191-216). Ownership only — gas is *not* a motive
  here: the `else` branch returns immediately (:218), so the asserts evaluate at
  most once per call (an earlier loop-invariant-hoist framing was refuted).
  (audit 2026-07-02, re-verified at `7911100b`)
- `mint_exact_amount` prices and admission-validates the same range twice per
  call — verify the second validation is not a distinct fact, then dedupe.
  (audit fb3ec8)
- Four cascading asserts under one `ENetPremiumBudgetTooHigh` exist only to
  pre-empt +1 overflow — verify and collapse. (audit a68338)
- `EReferenceTickTimestampMismatch` re-checks that an exact-timestamp lane read
  returns its own key — decide trust-boundary vs redundant. (audit 914ecd)
- `mint_exact_amount` disables BOTH slippage guards (`max_cost` and
  `max_probability` hardcoded to `u64::max`, expiry_market.move:482-483),
  asymmetric with `mint_exact_quantity` — decide whether a premium-budget mint
  should be able to bound total fees/penalty and entry probability, and add the
  optional guards if so. (2026-07-07 holistic audit)

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
- Public `liquidate()` takes an unbounded caller budget — low-priority self-DoS
  probe; needs a raw liquidate builder (`ctx.submitLiquidate`) in the harness.
  (from the retired experiments backlog)

### H-7: Test-coverage gaps from the PR #1097 review

From the 2026-07-02 full-PR review (all Low; strengthenings, not blockers).

- **RP-3 clamp not directly pinned.** No flush test exercises the sticky-exclusion
  clamp's own trigger (held-out total > a positive-then-collapsed gross). Add a
  flush test that latches positive profit-basis credits (settle a profitable
  market), withdraws idle, then collapses the remaining active mark so
  `exclusion + pending > gross`, and asserts the flush still succeeds at NAV==0.
- **New cadence public-read surface unclassified + uncovered.** The
  `market_manager` cadence-config getters (registry.move:63 / market_manager.move
  public reads) are `public` with no in-repo caller and no consumer-class doc
  comment (violates the public-read classification policy this branch landed) and
  have zero test coverage — classify each per the policy (delete or document the
  consumer class), then cover the kept ones.
- **`pricing` forward-absence branch untested.** `EBlockScholesPriceUnavailable`
  is pinned for the spot-absence path but not the forward-absence path; add the
  missing `expected_failure`.
- **One-sided boundary/receiving-side assertions.** The drain rounds-to-zero
  boundaries are tested only on the aborting side; the all-in `max_cost` boundary
  pair (from the now-resolved H-2 fix) pins only a 2-of-4-component decomposition
  (zero builder fee / subsidy). Strengthen each to assert the passing boundary.
  (`unstake_deep` receiving-side assertion — that the account received the DEEP —
  added on PR #1106.)
