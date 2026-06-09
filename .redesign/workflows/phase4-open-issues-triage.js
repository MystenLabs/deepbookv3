export const meta = {
  name: 'phase4-open-issues-triage',
  description: 'Verify each OPEN_ISSUES finding against HEAD and classify: unit-testable now / accepted-document / blocked',
  phases: [
    { title: 'Triage', detail: 'one read-only verifier per finding' },
  ],
}

const COMMON = `You are a READ-ONLY triage analyst for the Sui Move "predict" package in /Users/aslantashtanov/Desktop/Projects/deepbookv3 (branch strike-exposure-rewrite-state). Do NOT edit files, run builds/tests, or run mutating git commands.

Your job for ONE finding from .claude/predict-design/OPEN_ISSUES.md: (1) verify whether it still applies at current HEAD (cite file:line of the relevant code); (2) classify it:
- TESTABLE-NOW: a Move unit test can demonstrate the behavior with the existing fixtures (packages/predict/tests/helper/flow_test_helpers.move, oracle_fixture.move — read them to know the surface). Provide a concrete scenario script (steps + exact helper calls) and say whether the test would be GREEN (pins accepted-but-suboptimal documented behavior) or RED (demonstrates a real defect — would be ledgered as KNOWN-FAILING under .redesign/BUGS_FOUND.md discipline).
- ACCEPTED-DOCUMENT: a known accepted tradeoff/pending product decision where a test adds no information (say why), or the behavior is already disclosed in packages/predict/docs/risks.md (cite).
- BLOCKED: not unit-testable (say what blocks it: un-constructible types, gas bounds, needs deployment).
- FIXED/STALE: the finding no longer applies at HEAD (cite the code that fixed it).
Be precise and conservative: re-verify every claim against the actual source. If TESTABLE-NOW and RED, derive the expected-vs-actual discrepancy explicitly.`

const FINDINGS = [
  { key: 'loss-netting-one-directional', text: 'Medium: Cross-expiry loss-netting is one-directional. net_losses_to_fill nets a future profit against a prior loss, but not a prior already-materialized profit against a future loss; a profitable expiry settling first takes its full protocol share, so a later loss-making expiry leaves the protocol over-taken (the reserve is join-only). Relevant: pool_accounting.move net_losses_to_fill / materialize_expiry_profit, plp.move protocol reserve split.' },
  { key: 're-bootstrap-incentive-capture', text: 'Medium: Re-bootstrap incentive capture. With no minimum/dead-share PLP supply, a full LP exit mid-incentive-stream drives total_supply to 0 and orphans the locked incentive; the next 1:1 bootstrap supplier captures it. (Pending decision 3: permanent base supply.) Relevant: plp.move supply/withdraw bootstrap path, incentive.move locked/released value.' },
  { key: 'stranded-rebate-reserve', text: 'Medium: Stranded rebate reserve. release_settled_pool_cash keeps rebate-reserve cash inside the settled expiry; it drains only through per-manager claim_trading_loss_rebate (no batch sweep / force-resolve), so reserve owed to inactive or zero-owed managers stays stranded and invisible to NAV. Relevant: expiry_market.move claim_trading_loss_rebate / release_settled_pool_cash, expiry_cash.move.' },
  { key: 'large-lp-withdraw-starvation', text: 'Medium: Large-LP withdraw starvation. Withdraw prices against full NAV (idle + active) but pays only from idle (clamped to free idle); a large, valid pro-rata claim that exceeds current idle reverts rather than partially filling. Relevant: plp.move withdraw + pool_accounting withdraw_idle / assert_active_allocations_backed.' },
  { key: 'pyth-staleness-forward-discontinuity', text: 'Low: Live forward switches discontinuously at the Pyth-spot staleness boundary (fresh: forward = mul(pyth.spot, basis); stale: falls back to BS forward) — externally observable, straddleable for a more favorable mint/redeem mark. Relevant: pricing.move live_inputs.' },
  { key: 'circuit-breaker-envelope-loose', text: 'Low: Circuit-breaker envelope is loose (basis up to 2.0x, 10%/step caps) — admin/operator can widen deviation/basis guards toward a near-no-op. Relevant: config_constants.move basis/deviation envelope bounds, market_oracle_config.move.' },
  { key: 'incentive-compound-zero-release', text: 'Low: incentive::compound (or the linear-release sync) advances last timestamp even when the release rounds to 0, deferring vesting until end (self-correcting, no loss). Verify the current sync_value/release code in incentive.move.' },
  { key: 'ewma-first-trade-poisoning', text: 'Low: EWMA congestion variance is poisonable by the first post-creation trade, suppressing the surcharge for everyone after. Relevant: ewma.move seeding/variance update.' },
  { key: 'strike-quantity-u64-overflow', text: 'Low: strike_nav_matrix strike_quantity (u64, = mul(qty, strike)) can overflow for a high-priced asset with large open interest, bricking valuation on a hot path (native abort, no named code). Relevant: strike_nav_matrix.move weighted_quantity/apply_boundary_delta. Derive the actual overflow threshold for a BTC-scale strike (100_000e9) and judge realism; a unit test inserting a large-qty range could demonstrate the abort.' },
  { key: 'rebate-claim-griefing', text: 'Low: Permissionless claim_trading_loss_rebate (no owner gate on the public wrapper) lets a griefer lock in a victim rebate at a lower active stake (stake-scaled rebate?). Verify how the rebate amount depends on caller vs owner state in expiry_market.move claim_trading_loss_rebate.' },
  { key: 'value-in-dusdc-overflow', text: 'Low: value_in_dusdc can abort on overflow for a high-decimal / high-price incentive asset, bricking that asset NAV/claim paths. Relevant: pyth_source.move value_in_dusdc. Derive the overflow envelope; testable at unit level?' },
  { key: 'ewma-gas-accumulator-overflow', text: 'Low: EWMA gas-price accumulator uses a native u64 multiply on the hot trade path (overflow would abort the trade; gas far below the bound — not attacker-controllable). Verify the bound math in ewma.move.' },
  { key: 'svi-no-arbitrage-validation', text: 'Low (VERIFY status): SVI no-arbitrage / monotonicity validation on update_svi — OPEN_ISSUES says verify whether this is covered by the SVI-validation fix or still open. Check market_oracle.move assert_valid_svi: does it enforce anything beyond rho magnitude <= 1 and sigma bounds (e.g. b >= 0 implicitly by u64, a + b*sigma*sqrt(1-rho^2) >= 0 Gatheral condition, butterfly arbitrage)? Report exactly what is and is not validated.' },
]

const SCHEMA = {
  type: 'object',
  required: ['key', 'still_applies', 'classification', 'evidence', 'scenario', 'red_or_green', 'notes'],
  properties: {
    key: { type: 'string' },
    still_applies: { type: 'boolean' },
    classification: { type: 'string', enum: ['TESTABLE-NOW', 'ACCEPTED-DOCUMENT', 'BLOCKED', 'FIXED-STALE'] },
    evidence: { type: 'string', description: 'file:line citations backing the verdict' },
    scenario: { type: 'array', items: { type: 'string' }, description: 'if TESTABLE-NOW: concrete test steps; else empty' },
    red_or_green: { type: 'string', enum: ['RED', 'GREEN', 'N/A'], description: 'RED = demonstrates a defect (ledger candidate); GREEN = pins accepted behavior' },
    notes: { type: 'string' },
  },
}

phase('Triage')
const verdicts = await parallel(
  FINDINGS.map((f) => () =>
    agent(`${COMMON}\n\nFINDING (${f.key}):\n${f.text}`, { label: `triage:${f.key}`, phase: 'Triage', schema: SCHEMA })
  ),
)
const out = verdicts.filter(Boolean)
log(`${out.length}/${FINDINGS.length} findings triaged`)
return out