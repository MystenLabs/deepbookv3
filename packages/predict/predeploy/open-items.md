# Predict Predeploy Open Items

Updated 2026-07-08. **The single source of truth for open work.** Anything that
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
not compose into the 5M computation-unit wall. The NAV price memo removed the
single-market pre-cap OOG; the remaining deploy blocker is the pool-total case.
The missing bound is a joint sum across all active markets, not another
isolated per-market cap.

**Capacity model (measured, as of 2026-07-01):**

- The binding wall is the Sui per-transaction computation cap,
  `max_gas_computation_bucket = 5,000,000` units (5e9 MIST at reference gas
  price 1000; a protocol constant, so the OOG book size is
  network-independent). The flush is computation-bound — raising the gas
  budget does not bypass the wall.
- Single market, post-memo: a full 5,000-leveraged-order book values at
  ~47–54% of the wall (`evidence/c1-price-memo-2026-07-01.md`); the per-market
  order cap binds before NAV computation does. Pre-memo the flush OOG'd at
  ~4,580 orders (`evidence/c1-nav-stress-2026-06-30.md`) — historical evidence
  for why the pool total needs a joint budget.
- Pool-total: multi-market stress reached ~8,640 total leveraged orders across
  ~9 markets at ~92% of the wall, entangled with `expiry_cash::EInsufficientCash`
  (pool capital bound the book before gas did), so it is not the final gas-only
  cap — but enough to show the independent caps do not compose.
- Expired-unswept markets leave the active set only inside a successful
  `value_expiry`/sweep, so the flush's active tail is not bounded by the
  live-market creation cap.
- Cap-sizing shape:
  `sum_over_active_markets(nodes*c_node + orders*c_order + base) + drain_budget
  < safety_fraction (~60%) * 5,000,000 units`.

**Fix options:** a joint budget across active markets · caps tightened to a
measured single-PTB envelope · valuation resumable across PTBs · an
out-of-flush settled sweep/deactivate path (bounds the active tail) ·
documented operator throttling (an off-chain acceptance, not an on-chain
guarantee).

**Plan — runs that finish the number (decision rules pre-registered
2026-07-02):**

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
- Payout-tree probe (max nodes × max leveraged orders in one market): the
  1,000-node cap has never been benchmarked — prior runs reached only ~83
  boundaries — and supplies the `c_node` term.
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
