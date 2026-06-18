// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for every `strike_exposure_config` error code.
///
/// Setter-side: `EInvalidAskBound` (the relational min < max ask guard on the
/// template setters). Leaf math guard: `EInvalidFeeProbability` — unreachable
/// from the public mint surface because `pricing` quotes come from
/// `normal_cdf`, which is bounded to `[0, 1e9]`, so it is exercised by a
/// direct package-internal `trading_fee` call (rule 4). All remaining codes
/// are mint-admission/floor policy and are driven through the real
/// `expiry_market::mint` flow. The default fixture quotes saturate exactly:
/// the near-zero-variance SVI plus `normal_cdf`'s 8-sigma clamp give entry
/// probability exactly 0 (deep-OTM range), exactly 0.5 (range starting at the
/// live price), or exactly 1 (live price far above the range start), which the
/// tests below combine with adversarial leverage/quantity/template values.
///
/// The `mint_*` flow tests are disabled on the testnet-framework branch (they need an
/// AccumulatorRoot; see `tests/helper/accumulator_support.move`), which leaves their
/// dedicated consts + `setup_live_market_with_templates` unused here.
#[test_only]
#[allow(unused_const, unused_function)]
module deepbook_predict::strike_exposure_config_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    constants,
    flow_test_helpers::{Self as helpers, Fixture, Trader},
    protocol_config::{Self, ProtocolConfig},
    strike_exposure_config,
    test_constants
};
use fixed_math::math::float_scaling as float;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

// Leverage values in FLOAT_SCALING. The valid tier set {1, 1.5, 2, 2.5, 3}x
// lives as private policy constants in `strike_exposure_config`; the tests
// restate the tier values they drive adversarially.
const LEVERAGE_ONE_AND_HALF_X: u64 = 1_500_000_000;
const LEVERAGE_TWO_AND_HALF_X: u64 = 2_500_000_000;
const LEVERAGE_THREE_X: u64 = 3_000_000_000;
/// Not a member of the {1, 1.5, 2, 2.5, 3}x tier set.
const LEVERAGE_BETWEEN_TIERS: u64 = 1_250_000_000;

/// On-grid strike tick at 2x the default live price (tick 200 ↔ raw 200e9 under
/// the 1e9 tick size, vs the 100e9 live price): a [strike, +inf) range here
/// quotes entry probability exactly 0 (saturated CDF).
const DEEP_OTM_STRIKE_TICK: u64 = 200;

/// Live price at 2x the min strike (100e9): a [min_strike, +inf) range quotes
/// entry probability exactly 1.0 (saturated CDF).
const DEEP_ITM_LIVE_PRICE: u64 = 200_000_000_000;

/// Liquidation LTV one unit above the 2.5x floor-seed share (1 - 1/2.5 = 0.6),
/// chosen so mint admission passes by exactly one unit while the terminal
/// floor check fails (see `mint_terminal_floor_at_liquidation_ltv_aborts`).
const LTV_JUST_ABOVE_TWO_AND_HALF_X_FLOOR_SHARE: u64 = 600_000_001;

/// Quantity for the terminal-floor test. Must be even (so entry_value at p = 0.5
/// is exact), with entry_value divisible by 5 (so the 2.5x split is exact) and
/// below 1e9 (so `quantity * ltv / 1e9` floors away the LTV's +1 unit).
const TERMINAL_FLOOR_QUANTITY: u64 = 100_000_000;

/// Create a real shared `ProtocolConfig` (template values at defaults) and an
/// `AdminCap`, ready for admin setter calls in the next transaction.
fun new_shared_config(): (Scenario, AdminCap, ID) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id)
}

/// `setup_live_market`-equivalent bring-up that applies strike-exposure
/// template overrides BEFORE the expiry market is created, so the market's
/// config snapshot carries them. Each `Some` value is routed to the matching
/// template setter. The base fixture still floors `base_fee` to 1 and
/// `min_ask_price` to 0 (see `setup_market`).
fun setup_live_market_with_templates(
    min_ask_price: Option<u64>,
    liquidation_ltv: Option<u64>,
    terminal_floor_index: Option<u64>,
): (Fixture, ID, Trader) {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    min_ask_price.do!(|value| config.set_template_min_ask_price(&admin_cap, value));
    liquidation_ltv.do!(|value| config.set_template_liquidation_ltv(&admin_cap, value));
    terminal_floor_index.do!(|value| config.set_template_terminal_floor_index(&admin_cap, value));
    return_shared(config);
    destroy(admin_cap);

    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, test_constants::default_live_price());
    fx.seed_market_cash(&mut market, test_constants::default_seeded_expiry_cash());
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.scenario_mut().next_tx(test_constants::admin());
    (fx, expiry_id, trader)
}

// === EInvalidAskBound (template setter relational guard) ===

// A min ask equal to the current max ask is the tightest just-outside value
// (the setter requires min < max strictly); it is inside the
// `config_constants` envelope, so the relational guard is what fires.
#[test, expected_failure(abort_code = strike_exposure_config::EInvalidAskBound)]
fun template_min_ask_price_at_max_ask_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_ask_price(&admin_cap, config_constants::default_max_ask_price!());
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidAskBound)]
fun template_max_ask_price_at_min_ask_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_max_ask_price(&admin_cap, config_constants::default_min_ask_price!());
    abort 999
}

#[test]
fun template_ask_bounds_accept_adjacent_values() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // min one unit below the default max, then max one unit above that min:
    // the tightest just-inside pair for the relational guard.
    config.set_template_min_ask_price(&admin_cap, config_constants::default_max_ask_price!() - 1);
    config.set_template_max_ask_price(&admin_cap, config_constants::default_max_ask_price!());

    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(snapshot.min_ask_price(), config_constants::default_max_ask_price!() - 1);
    assert_eq!(snapshot.max_ask_price(), config_constants::default_max_ask_price!());
    destroy(snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

// === EInvalidFeeProbability (leaf math guard, direct call) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidFeeProbability)]
fun trading_fee_probability_above_one_aborts() {
    let config = strike_exposure_config::new();
    config.trading_fee(
        test_constants::default_expiry_ms(),
        float!() + 1,
        test_constants::mint_quantity(),
        test_constants::now_ms(),
    );
    abort 999
}

#[test]
fun trading_fee_at_probability_one_floors_at_min_fee() {
    let config = strike_exposure_config::new();
    // Just-inside boundary: p = 1.0 is accepted. Bernoulli variance at p = 1
    // is 0, so the raw fee is 0 and the per-unit rate floors at the default
    // min fee; far from expiry the ramp multiplier is 1x, and quantity 1.0
    // (1e9) makes the total fee equal the per-unit floor exactly.
    assert_eq!(
        config.trading_fee(
            test_constants::default_expiry_ms(),
            float!(),
            float!(),
            test_constants::now_ms(),
        ),
        config_constants::default_min_fee!(),
    );
    destroy(config);
}

// === EAskPriceOutOfBounds (mint admission) ===

/* DISABLED(testnet-fw): needs AccumulatorRoot — nightly create_for_testing is absent on testnet; see accumulator_support.move. Restore the file/test when stable Sui ships it.
#[test, expected_failure(abort_code = strike_exposure_config::EAskPriceOutOfBounds)]
fun mint_all_in_price_above_max_ask_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        DEEP_ITM_LIVE_PRICE,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Entry probability saturates to 1.0; the fee floors at the default min
    // fee (0.005), so the all-in price 1.005 exceeds the default max ask 0.99.
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EAskPriceOutOfBounds)]
fun mint_all_in_price_below_min_ask_aborts() {
    // The base fixture floors the min-ask template to 0, which makes the low
    // bound unreachable; restore the production default (0.01) before the
    // market snapshots its config.
    let (mut fx, expiry_id, trader) = setup_live_market_with_templates(
        option::some(config_constants::default_min_ask_price!()),
        option::none(),
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Entry probability saturates to 0; the all-in price is just the min-fee
    // floor (0.005), below the restored min ask (0.01).
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        DEEP_OTM_STRIKE_TICK,
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

// === EInvalidLeverage (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidLeverage)]
fun mint_leverage_outside_tier_set_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_BETWEEN_TIERS,
    );
    abort 999
}

// === EInvalidLeverageTier (mint admission) ===

// Covers the 1x-only zone (entry probability < 0.1). The middle zone
// (probability in [0.1, 0.2), max 2x) shares this abort code but is not
// separately reachable with the near-zero-variance fixture, whose realizable
// quotes saturate to exactly {0, 0.5, 1} — none of which land in [0.1, 0.2).
#[test, expected_failure(abort_code = strike_exposure_config::EInvalidLeverageTier)]
fun mint_low_probability_above_one_x_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Entry probability 0 (< the 0.1 one-x-only threshold) admits only 1x;
    // 1.5x is a valid tier value, so the tier policy is what aborts.
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        DEEP_OTM_STRIKE_TICK,
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_AND_HALF_X,
    );
    abort 999
}

// === ENetPremiumBelowMinimum (mint admission) ===

// At entry probability exactly 0.5 and 1x leverage, the net premium is
// entry_value = quantity / 2, so the minimum-premium boundary sits at quantity
// = 2 * min_net_premium. One position lot below it: net_premium
// = (2_000_000 - 10_000) / 2 = 995_000 < 1_000_000.
#[test, expected_failure(abort_code = strike_exposure_config::ENetPremiumBelowMinimum)]
fun mint_net_premium_one_lot_below_minimum_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        2 * constants::min_net_premium!() - constants::position_lot_size!(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

#[test]
fun mint_net_premium_at_minimum_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Just-inside boundary: net_premium = 2_000_000 / 2 = exactly
    // min_net_premium.
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        2 * constants::min_net_premium!(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(helpers::position_count(&wrapper, expiry_id), 1);
    helpers::assert_market_backed(&market);

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

// === EOrderBelowLiquidationThreshold (mint admission) ===

// Unreachable at the default 0.85 LTV (a 3x order's floor seed is 2/3 of
// entry_value, and 2/3 / 0.85 < 1), so the template LTV is tuned to its 0.5
// envelope floor before market creation. At 3x: financed_amount = 2/3 * entry_value,
// liquidation threshold = financed_amount / 0.5 = 4/3 * entry_value > entry_value, so
// the order opens below its own liquidation threshold and is rejected.
#[test, expected_failure(abort_code = strike_exposure_config::EOrderBelowLiquidationThreshold)]
fun mint_three_x_at_min_liquidation_ltv_aborts() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_templates(
        option::none(),
        option::some(config_constants::min_liquidation_ltv!()),
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_THREE_X,
    );
    abort 999
}

// === ETerminalFloorExceedsLiquidationLtv (mint floor terms) ===

// Unreachable at default templates (max terminal floor share is
// 1.2 * 2/3 * p <= 0.8 < 0.85 LTV), so the terminal floor index is raised to
// its 2.0 envelope ceiling and the LTV is set one unit above the 2.5x
// floor-seed share. Exact integer trace at entry probability 0.5,
// quantity = 100_000_000:
//   entry_value          = 0.5 * 100_000_000               = 50_000_000
//   net_premium      = 50_000_000 / 2.5                = 20_000_000
//   financed_amount        = 50_000_000 - 20_000_000         = 30_000_000
//   admission thresh  = 30_000_000 * 1e9 / 600_000_001  = 49_999_999 (floor)
//     -> entry_value 50_000_000 > 49_999_999: admission passes by one unit.
//   open floor index  = 1.0 (mint is a full leverage-floor window pre-expiry)
//   floor_shares      = 30_000_000 / 1.0                = 30_000_000
//   terminal floor    = 30_000_000 * 2.0                = 60_000_000
//   max terminal      = 100_000_000 * 600_000_001 / 1e9 = 60_000_000 (floor)
//     -> terminal floor >= max terminal: floor terms abort.
#[test, expected_failure(abort_code = strike_exposure_config::ETerminalFloorExceedsLiquidationLtv)]
fun mint_terminal_floor_at_liquidation_ltv_aborts() {
    let (mut fx, expiry_id, trader) = setup_live_market_with_templates(
        option::none(),
        option::some(LTV_JUST_ABOVE_TWO_AND_HALF_X_FLOOR_SHARE),
        option::some(config_constants::max_terminal_floor_index!()),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        TERMINAL_FLOOR_QUANTITY,
        LEVERAGE_TWO_AND_HALF_X,
    );
    abort 999
}
*/

// === Canonical index-term evaluation ===

// Evaluator atoms reused from the C1 regression's hand-derived survivor:
// floor(124_998_049 * 1.2) = 149_997_658.
const EVAL_QUANTITY: u64 = 599_990_000;
const EVAL_FLOOR_SHARES: u64 = 124_998_049;
/// 599_990_000 - 149_997_658.
const EVAL_TERMINAL_PAYOUT: u64 = 449_992_342;
/// At open floor index 1.0: 599_990_000 - 124_998_049.
const EVAL_LIVE_BACKING_AT_BASE: u64 = 474_991_951;
/// At open floor index 1.05 (half-window phase, premium 0.2 * 0.5^2):
/// 599_990_000 - floor(124_998_049 * 1.05) = 599_990_000 - 131_247_951.
const EVAL_LIVE_BACKING_MID_WINDOW: u64 = 468_742_049;

#[test]
fun terminal_payout_rounds_terminal_floor_down() {
    let config = strike_exposure_config::new();
    assert_eq!(config.terminal_payout(EVAL_QUANTITY, EVAL_FLOOR_SHARES), EVAL_TERMINAL_PAYOUT);
    destroy(config);
}

#[test]
fun index_terms_at_base_floor_index_nets_floor_shares() {
    let config = strike_exposure_config::new();
    let window = constants::leverage_floor_window_ms!();
    // Opened a full window before expiry: open floor index = 1.0, so live
    // backing nets exactly floor_shares.
    let (terminal_payout, live_backing_payout) = config.index_terms(
        2 * window,
        0,
        EVAL_QUANTITY,
        EVAL_FLOOR_SHARES,
    );
    assert_eq!(terminal_payout, EVAL_TERMINAL_PAYOUT);
    assert_eq!(live_backing_payout, EVAL_LIVE_BACKING_AT_BASE);
    destroy(config);
}

#[test]
fun index_terms_mid_window_applies_phase_squared_premium() {
    let config = strike_exposure_config::new();
    let window = constants::leverage_floor_window_ms!();
    let expiry_ms = 2 * window;
    let (terminal_payout, live_backing_payout) = config.index_terms(
        expiry_ms,
        expiry_ms - window / 2,
        EVAL_QUANTITY,
        EVAL_FLOOR_SHARES,
    );
    assert_eq!(terminal_payout, EVAL_TERMINAL_PAYOUT);
    assert_eq!(live_backing_payout, EVAL_LIVE_BACKING_MID_WINDOW);
    destroy(config);
}

#[test]
fun index_terms_opened_at_expiry_equals_terminal_payout() {
    let config = strike_exposure_config::new();
    let expiry_ms = constants::leverage_floor_window_ms!();
    // Open floor index has reached the terminal index, so live backing and
    // terminal payout coincide.
    let (terminal_payout, live_backing_payout) = config.index_terms(
        expiry_ms,
        expiry_ms,
        EVAL_QUANTITY,
        EVAL_FLOOR_SHARES,
    );
    assert_eq!(terminal_payout, EVAL_TERMINAL_PAYOUT);
    assert_eq!(live_backing_payout, EVAL_TERMINAL_PAYOUT);
    destroy(config);
}
