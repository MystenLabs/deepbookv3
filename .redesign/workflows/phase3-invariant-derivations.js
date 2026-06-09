export const meta = {
  name: 'phase3-invariant-derivations',
  description: 'Independent expected-value derivations for Predict hot-flow invariant tests, adversarially verified',
  whenToUse: 'Before authoring Phase-3 invariant tests',
  phases: [
    { title: 'Derive', detail: 'one independent deriver per hot-flow scenario' },
    { title: 'Verify', detail: 'recompute-math + spec-consistency lenses per derivation' },
  ],
}

const COMMON = `You are a READ-ONLY derivation analyst for the Sui Move "predict" package in /Users/aslantashtanov/Desktop/Projects/deepbookv3 (branch strike-exposure-rewrite-state). Do NOT edit any file, do NOT run builds/tests, do NOT run mutating git commands. Your job: derive EXACT expected values for a test scenario INDEPENDENTLY of the implementation.

INDEPENDENCE RULES (cardinal):
- Primary sources: packages/predict/docs/concepts/*.md, docs/design/invariants.md, docs/design/architecture.md, and plain math. These are the spec.
- You may read source ONLY for: (a) public API shapes/signatures, (b) config DEFAULT values in config_constants.move (cite file:line), (c) the documented rounding direction of deepbook::math helpers (mul/div round down; mul_round_up/div_round_up round up). NEVER copy an implementation formula as your derivation — derive from the spec and flag any place where the spec is silent and you had to look at implementation logic (mark independence_risk: true for that value).
- All arithmetic is u64 fixed-point, FLOAT_SCALING = 1e9. State the rounding direction at every multiply/divide and compute exact integers.
- Prefer scenario designs whose expected values are EXACTLY derivable: at-the-money digital = Phi(0) = 0.5 exactly (when live forward == strike and the SVI wing contribution rounds to zero); boundary settlement payouts (full notional or zero); conservation identities (sum of flows); flat fee floors.

FIXTURE FACTS (tests/helper/flow_test_helpers.move + test_constants.move — already verified):
- setup_market_default(): creation spot 50_100e9, tick 1e9, initial PLP supply 300_000e6 (= 300_000_000_000 raw DUSDC); protocol_reserve_share = 0.4e9 (40%); template base_fee floored to 1, template min_ask_price 0. min_finite_strike = 100e9. expiry_cash_floor!() = 50_000e6 (verify in constants.move).
- setup_everything(): far expiry 31_536_100_000 ms (~1y; flat floor schedule, >1x admissible), live price 100e9 seeded as BOTH spot and forward (basis 1.0), manager deposit 30e9. setup_live_market(expiry_ms, live_price): same but parameterized, deposit 1e9.
- Default SVI: a=1, b=10_000, rho=+1.0, m=10e9 -> for default-grid strikes the wing contribution rounds to zero, so the ATM digital at forward==strike is exactly 0.5 (entry_probability = 500_000_000). The fee for the standard mint floors at min_fee = 5e6 (see lifecycle_tests.move header: POST_MINT_BALANCE derivation = deposit - floor(0.5*quantity) - 5e6).
- short_expiry_ms = 200_000 (now+100s; non-flat floor schedule — 2x orders carry a real floor), mint_quantity = 1e9, mint_deposit = 1e9, leverage_one_x = 1e9.
- Helper wrappers available to the test author: mint/redeem/redeem_settled/liquidate/liquidate_order/compact_storage/claim_trading_loss_rebate/supply/withdraw/sync_expiry/settle_oracle; assertion helpers check_manager(balance, fees_paid, position_count, active_stake, inactive_stake), check_market_cash(cash_balance, payout_liability, rebate_reserve), check_pool(idle_balance, total_supply, protocol_reserve_balance), assert_market_backed.
- settle_oracle(settlement_price) advances the clock past expiry and settles via the single-spot fallback.
- Existing coverage to NOT duplicate: lifecycle_tests (1x fund->mint->settle-ITM->redeem with full state sheets), strike_exposure_c1_tests (a mint->redeem->settle flow), plp_nav_haircut_tests (conservative-NAV haircut + withdraw fee), expiry_market_gate_tests (gates). Read them to build on, not repeat.

DELIVERABLE: a precise scenario script (numbered steps with exact helper calls + arguments) and, at named checkpoints, EXACT expected values for the named getters, each with its full derivation (show the arithmetic). Include the invariant being proven at each checkpoint. If an expected value cannot be made exact without implementation knowledge, either redesign the scenario to make it exact or mark independence_risk and explain.`

const SCENARIOS = [
  {
    key: 'settled-solvency-boundary',
    prompt: `SCENARIO S3/L1 — settled solvency through partial close + boundary settlement (the R1 invariant).
Design: short-expiry market (setup_live_market(short_expiry_ms, live_price chosen so the order is exactly ATM)). Mint a 1x order on a FINITE range (lower, higher] (both finite, e.g. (min_strike, min_strike+K ticks]); partially close half of it live (redeem with close_quantity = quantity/2); settle at the EXACT boundary settlement == higher (per docs the (lower, higher] range INCLUDES higher => pays full); redeem_settled the survivor. Checkpoints: after settle and after each settled redeem, expected market payout_liability (must reach EXACTLY 0 after the last redeem — no residual, no underflow), expected manager balance deltas (= full notional per surviving quantity), cash backing >= liability at every step. ALSO design the mirror case settlement == lower (range excludes lower => pays 0) and settlement > higher (pays 0). Derive the live partial-close redeem value if exactly derivable (ATM 0.5 => redeem_amount = floor(0.5 * close_quantity) minus fee considerations — check how the redeem fee applies per docs/fees-and-rebates.md and the fixture's base_fee=1/min_fee floor). If the live-close value cannot be exact, redesign (e.g. partial close at the same ATM mark) or flag.`,
  },
  {
    key: 'cash-backing-per-flow',
    prompt: `SCENARIO S1/S2 — exact expiry-cash sheet after every cash-mutating op.
Design: far-expiry market (setup_everything). Sequence: (1) mint 1x ATM [min_strike, +inf) order; (2) mint a second 1x order different range; (3) partial redeem of order 1; (4) settle ITM for order 1's range; (5) redeem_settled both orders. After EACH step give the EXACT expected (cash_balance, payout_liability, rebate_reserve) triple for check_market_cash. You must derive: how mint principal+fee lands in expiry cash (principal joins cash; fee joins cash AND increments unresolved_trading_fees basis -> rebate_reserve = rebate_rate * fees, read default rebate rate from config_constants), payout_liability for 1x orders (= quantity for [min_strike,+inf)? — derive from docs/concepts/leverage-and-floor.md: live backing for a 1x order; for finite vs semi-infinite ranges), how the pre-trade sync rebalance tops cash to the floor (expiry_cash_floor), redeem payout effects. Make every checkpoint value an exact integer. If rebate_rate default is R (cite config_constants line), rebate_reserve after fees F is exactly the documented function of F and R (state rounding).`,
  },
  {
    key: 'multi-expiry-sync-nav',
    prompt: `SCENARIO S4/A2 — multi-expiry sync NAV conservation + ledger flow watermarks.
Design: default market + TWO expiries (create_expiry twice; note add_idle_supply_before_expiries if allocation headroom is needed — check expiry_cash_floor vs initial supply 300_000e6 for two expiries). Trades: one trader mints in expiry A (LP gains fees), nothing in expiry B. Then full sync (start_pool_sync -> sync_expiry for BOTH -> finish_pool_sync). Checkpoints: (1) finish_pool_sync's returned pool value: derive its exact expected composition = idle + sum(active expiry NAV) per docs/concepts/liquidity-and-nav.md (conservative NAV: what marks does a 1x-only book produce? plp_nav_haircut_tests says 1x-only keeps optimistic NAV); (2) vault.expiry_flow_amounts(A) and (B): exact (sent, received) pairs (A2: each delta counted once — derive what was sent at registration/rebalance: expiry_cash_floor each, plus what mint cash adds); (3) NAV-directional: supply at the synced mark then immediately withdraw the SAME shares — assert withdraw proceeds <= supply payment (no free round-trip; withdraw_NAV <= supply_NAV) — derive the exact withdraw fee from the withdraw-fee design (read docs + config_constants default_withdraw_fee_alpha if it determines an exact fee at zero-uncertainty 1x-only state; plp_nav_haircut_tests withdraw test may pin the exact mechanics — build on it without duplicating).`,
  },
  {
    key: 'no-double-pay-liquidation',
    prompt: `SCENARIO L2 — liquidated order pays zero on redeem; no double-pay; tombstone lifecycle at the flow level.
Design: SHORT-expiry market (short_expiry_ms — non-flat floor schedule) with a LEVERAGED order (2x — check admissible leverage values + tiers in config_constants/strike_exposure_config defaults; the fixture's min_ask=0/base_fee=1 nudges; pick range/price so the mint is admissible — semi-infinite range required for leveraged orders: lower==0-index i.e. (neg_inf? no — leveraged shape: lower boundary index 0 OR higher == max; so use [min_strike-ish, +inf) style (k, +inf) ranges). Drive the price DOWN via prepare_live_oracle/update_block_scholes_prices + set_pyth_price_for_testing so the order's live value falls under its floor (derive the floor schedule at the new clock time from docs/concepts/leverage-and-floor.md + liquidation_ltv default), then: (a) liquidate_order returns true; (b) the holder's redeem of the tombstoned order pays EXACTLY zero (manager balance unchanged) and clears the position; (c) a second liquidate_order on the same id returns false or aborts — determine which from the public API docs and design the assert. Checkpoints with exact values where derivable: the floor_shares of the 2x order at mint (= derive from leverage and entry probability: floor schedule formula in the docs), liquidation threshold (gross value <= floor/liquidation_ltv — derive the exact threshold price), manager balance before/after the zero-pay redeem (exact equality), payout_liability before/after (drops by the order's backing exactly). Flag independence_risk wherever the doc formula is ambiguous.`,
  },
  {
    key: 'rebate-claim-accounting',
    prompt: `SCENARIO A2/A3 — trading-loss rebate accounting conservation.
Design: short-expiry market; trader mints a 1x order that SETTLES WORTHLESS (settlement <= lower, e.g. range (k, +inf) with settlement below k — wait, semi-infinite (k,+inf) pays when settlement > k, so settle at exactly k => pays 0). Trader pays fee F at mint (exactly min_fee = 5e6 if the standard mint). After settle + redeem_settled (zero payout): claim_trading_loss_rebate for the manager. Derive EXACTLY per docs/concepts/fees-and-rebates.md: the rebate owed = rebate_rate * trading_fees_paid for a net-loss trader (read default trading_loss_rebate_rate from config_constants — cite), capped how? The manager balance delta after claim == that exact rebate. Then assert the expiry's rebate_reserve resolves to 0 and residual cash returns to the pool (vault.expiry_flow_amounts received increases by the residual — derive exact residual = fees - rebate +/- rounding per documented direction). Also derive the manager-summary conservation (A3): trading_fees_paid getter == F throughout; position count 0 after redeem. Every checkpoint exact.`,
  },
  {
    key: 'supply-withdraw-rounding',
    prompt: `SCENARIO A1 — PLP supply/withdraw rounding favors the pool / remaining holders.
Design: default market (no expiries needed beyond the bootstrap, or zero expiries — supply/withdraw work against idle-only NAV; check whether a fixture without create_expiry can sync trivially: start_pool_sync with zero active expiries -> finish immediately). Bootstrap state: total_supply == initial supply S0 = 300_000e6 shares at 1:1 (verify bootstrap mints exactly payment shares). Steps with EXACT derivations per docs/concepts/liquidity-and-nav.md + the rounding table (shares = floor(payment * total_supply / pool_value); withdraw dusdc = floor(lp * pool_value / total_supply) minus the withdraw fee — derive the fee exactly for the idle-only state from default_withdraw_fee_alpha (cite config_constants); both directions round AGAINST the user): (1) supply P1 that divides evenly -> exact share count; (2) supply P2 that does NOT divide evenly -> floor() loses dust to the pool — exact share count + exact post-state pool value per share strictly >= pre; (3) withdraw W shares -> exact DUSDC out (incl. fee), pool per-share value for remaining holders strictly >= before; (4) round-trip: supply X then withdraw the received shares -> proceeds <= X exactly quantified. Give exact expected (idle_balance, total_supply, protocol_reserve_balance) for check_pool at each checkpoint.`,
  },
  {
    key: 'liquidation-boundary',
    prompt: `SCENARIO P0-7 — liquidation threshold boundary at the flow level.
Design: short-expiry market, 2x leveraged order (same admissibility care as the no-double-pay scenario — read config_constants/strike_exposure_config defaults for leverage tiers/min principal and the floor schedule docs). Derive the EXACT threshold: order is liquidatable iff gross live value <= floor / liquidation_ltv (read default liquidation_ltv; floor at time t from the schedule). Then: (a) set live price to the JUST-ABOVE-threshold price (derive it: the smallest 1e9-scaled price where the order is NOT liquidatable) -> liquidate_order returns false, order remains active and closable (liveness L1: redeem still works); (b) set price one tick/probability-unit below -> liquidate_order returns true; (c) liquidate (budgeted pass) with budget=0 -> returns 0, no state change (exact payout_liability unchanged). The threshold derivation must come from the docs formula; mark independence_risk if the docs leave the exact rounding of the threshold comparison unspecified (then design (a)/(b) with a SAFE GAP: clearly-above and clearly-below prices, plus a documented note that the exact boundary unit is implementation-defined).`,
  },
  {
    key: 'compaction-parity',
    prompt: `SCENARIO P0-8 — compaction parity (METAMORPHIC: explicitly exempt from the independent-expected-value rule; neither side is the test's oracle).
Design: two IDENTICAL short-expiry scenarios (same mints: a couple of 1x + leveraged orders, same settle price). Path A: settle -> redeem_settled all orders WITHOUT compaction. Path B: settle -> compact_storage (cap-gated; materializes settled liability + destroys live indexes) -> redeem_settled all orders. Assert BIT-EQUAL: per-order payouts (manager balance deltas), final payout_liability == 0 on both, final market cash equal, vault received amounts equal. Also: post-compaction expiry is payout+rebate escrow only (per move.md economics rules: allocated_capital -> 0, expiry unregistered from active index — check which getters expose this: vault.active_expiry_markets contains/not). Scenario script must spell out both paths step-for-step so the test author can write a parameterized worker run(compact: bool) -> (payouts vector, final sheets) and one assert_eq! between the two runs. List the exact getters to snapshot. Note: design mints so at least one settled order pays nonzero and one pays zero (boundary). No numeric derivations needed beyond choosing admissible mints — but DO verify the compact_storage call sequence preconditions (settled oracle required? cap? what aborts if live) from the public API and docs.`,
  },
]

const DERIVATION_SCHEMA = {
  type: 'object',
  required: ['scenario_key', 'feasible', 'scenario_script', 'checkpoints', 'notes'],
  properties: {
    scenario_key: { type: 'string' },
    feasible: { type: 'boolean', description: 'false if the scenario cannot be made production-valid/exact — explain in notes' },
    scenario_script: { type: 'array', items: { type: 'string' }, description: 'numbered concrete steps with exact helper calls + integer arguments' },
    checkpoints: {
      type: 'array',
      items: {
        type: 'object',
        required: ['after_step', 'invariant', 'expected_values'],
        properties: {
          after_step: { type: 'string' },
          invariant: { type: 'string', description: 'which invariant (S1..S5/L1..L4/A1..A3) this checkpoint proves' },
          expected_values: {
            type: 'array',
            items: {
              type: 'object',
              required: ['getter', 'value', 'derivation', 'independence_risk'],
              properties: {
                getter: { type: 'string', description: 'e.g. market.payout_liability()' },
                value: { type: 'string', description: 'exact integer, or an exact relation like "== balance_before" / "<= supply_payment"' },
                derivation: { type: 'string', description: 'the shown arithmetic / spec citation' },
                independence_risk: { type: 'boolean' },
              },
            },
          },
        },
      },
    },
    notes: { type: 'string', description: 'config defaults cited (file:line), ambiguities, redesigns made, anything the author must double-check' },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['sound', 'errors', 'comments'],
  properties: {
    sound: { type: 'boolean' },
    errors: { type: 'array', items: { type: 'string' }, description: 'specific wrong values/steps with the corrected value and why' },
    comments: { type: 'string' },
  },
}

const LENSES = [
  {
    key: 'recompute',
    instr: 'RECOMPUTE-MATH lens: independently redo every numeric derivation in the derivation below (do NOT trust its arithmetic). Check fixed-point rounding directions, integer exactness, fee floors, and that each expected value follows from the cited spec. Report every discrepancy with the corrected number.',
  },
  {
    key: 'spec',
    instr: 'SPEC-CONSISTENCY lens: check every claim in the derivation against the actual docs (packages/predict/docs/**) and the public API surface (read the cited files). Flag: claims the docs do not support, missing preconditions (gates, sync ordering, take/return discipline, admissibility rules for leveraged mints), steps that would abort before reaching the checkpoint, and any expected value that is actually implementation-derived (circular) rather than spec-derived.',
  },
]

phase('Derive')
const results = await pipeline(
  SCENARIOS,
  (s) => agent(`${COMMON}\n\n${s.prompt}`, { label: `derive:${s.key}`, phase: 'Derive', schema: DERIVATION_SCHEMA }),
  (deriv, s) => {
    if (!deriv) return null
    return parallel(
      LENSES.map((l) => () =>
        agent(
          `You are a READ-ONLY adversarial verifier in /Users/aslantashtanov/Desktop/Projects/deepbookv3. No edits, no builds, no mutating git. ${l.instr}\n\nDERIVATION UNDER REVIEW:\n${JSON.stringify(deriv, null, 2)}`,
          { label: `verify:${s.key}:${l.key}`, phase: 'Verify', schema: VERDICT_SCHEMA },
        )
      ),
    ).then((vs) => ({ key: s.key, derivation: deriv, verdicts: vs.filter(Boolean) }))
  },
)

const out = results.filter(Boolean)
log(`${out.length}/${SCENARIOS.length} scenarios derived and verified`)
return out