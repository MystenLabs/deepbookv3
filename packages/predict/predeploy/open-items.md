# Predict Predeploy Open Items

Updated 2026-07-06. **The single source of truth for open work.** Anything that
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
- **One-sided boundary/receiving-side assertions.** `unstake_deep` positive test
  never asserts the account received the DEEP; the drain rounds-to-zero
  boundaries are tested only on the aborting side; the all-in `max_cost` boundary
  pair (from the now-resolved H-2 fix) pins only a 2-of-4-component decomposition
  (zero builder fee / subsidy). Strengthen each to assert the received side / the
  passing boundary.
