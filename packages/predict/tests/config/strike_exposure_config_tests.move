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
#[test_only]
module deepbook_predict::strike_exposure_config_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    constants,
    flow_test_helpers::{Self as helpers, Fixture},
    predict_manager::PredictManager,
    protocol_config::{Self, ProtocolConfig},
    strike_exposure_config,
    test_constants
};
use predict_math::math::float_scaling as float;
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

/// On-grid strike at 2x the default live price (100e9): a [strike, +inf)
/// range here quotes entry probability exactly 0 (saturated CDF).
const DEEP_OTM_STRIKE: u64 = 200_000_000_000;

/// Live price at 2x the min strike (100e9): a [min_strike, +inf) range quotes
/// entry probability exactly 1.0 (saturated CDF).
const DEEP_ITM_LIVE_PRICE: u64 = 200_000_000_000;

/// Liquidation LTV one unit above the 2.5x floor-seed share (1 - 1/2.5 = 0.6),
/// chosen so mint admission passes by exactly one unit while the terminal
/// floor check fails (see `mint_terminal_floor_at_liquidation_ltv_aborts`).
const LTV_JUST_ABOVE_TWO_AND_HALF_X_FLOOR_SHARE: u64 = 600_000_001;

/// Quantity for the terminal-floor test. Must be even (so exposure at p = 0.5
/// is exact), with exposure divisible by 5 (so the 2.5x split is exact) and
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
): (Fixture, ID, ID, PredictManager) {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    min_ask_price.do!(|value| config.set_template_min_ask_price(&admin_cap, value));
    liquidation_ltv.do!(|value| config.set_template_liquidation_ltv(&admin_cap, value));
    terminal_floor_index.do!(|value| config.set_template_terminal_floor_index(&admin_cap, value));
    return_shared(config);
    destroy(admin_cap);

    let (expiry_id, oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);
    helpers::return_market(pyth, vault, market, oracle, config);
    fx.scenario_mut().next_tx(test_constants::admin());
    (fx, expiry_id, oracle_id, manager)
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

#[test, expected_failure(abort_code = strike_exposure_config::EAskPriceOutOfBounds)]
fun mint_all_in_price_above_max_ask_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        DEEP_ITM_LIVE_PRICE,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Entry probability saturates to 1.0; the fee floors at the default min
    // fee (0.005), so the all-in price 1.005 exceeds the default max ask 0.99.
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
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
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_templates(
        option::some(config_constants::default_min_ask_price!()),
        option::none(),
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Entry probability saturates to 0; the all-in price is just the min-fee
    // floor (0.005), below the restored min ask (0.01).
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        DEEP_OTM_STRIKE,
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

// === EInvalidLeverage (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidLeverage)]
fun mint_leverage_outside_tier_set_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
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
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Entry probability 0 (< the 0.1 one-x-only threshold) admits only 1x;
    // 1.5x is a valid tier value, so the tier policy is what aborts.
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        DEEP_OTM_STRIKE,
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        LEVERAGE_ONE_AND_HALF_X,
    );
    abort 999
}

// === EOrderPrincipalBelowMinimum (mint admission) ===

// At entry probability exactly 0.5 and 1x leverage, the user contribution is
// exposure = quantity / 2, so the principal boundary sits at quantity
// = 2 * min_order_principal. One position lot below it: contribution
// = (2_000_000 - 10_000) / 2 = 995_000 < 1_000_000.
#[test, expected_failure(abort_code = strike_exposure_config::EOrderPrincipalBelowMinimum)]
fun mint_principal_one_lot_below_minimum_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        2 * constants::min_order_principal!() - constants::position_lot_size!(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

#[test]
fun mint_principal_at_minimum_succeeds() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Just-inside boundary: contribution = 2_000_000 / 2 = exactly
    // min_order_principal.
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        2 * constants::min_order_principal!(),
        test_constants::leverage_one_x(),
    );
    assert_eq!(manager.expiry_position_count(expiry_id), 1);
    helpers::assert_market_backed(&market);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

// === EOrderBelowLiquidationThreshold (mint admission) ===

// Unreachable at the default 0.85 LTV (a 3x order's floor seed is 2/3 of
// exposure, and 2/3 / 0.85 < 1), so the template LTV is tuned to its 0.5
// envelope floor before market creation. At 3x: floor_seed = 2/3 * exposure,
// liquidation threshold = floor_seed / 0.5 = 4/3 * exposure > exposure, so
// the order opens below its own liquidation threshold and is rejected.
#[test, expected_failure(abort_code = strike_exposure_config::EOrderBelowLiquidationThreshold)]
fun mint_three_x_at_min_liquidation_ltv_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_templates(
        option::none(),
        option::some(config_constants::min_liquidation_ltv!()),
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
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
//   exposure          = 0.5 * 100_000_000               = 50_000_000
//   contribution      = 50_000_000 / 2.5                = 20_000_000
//   floor_seed        = 50_000_000 - 20_000_000         = 30_000_000
//   admission thresh  = 30_000_000 * 1e9 / 600_000_001  = 49_999_999 (floor)
//     -> exposure 50_000_000 > 49_999_999: admission passes by one unit.
//   open floor index  = 1.0 (mint is a full leverage-floor window pre-expiry)
//   floor_shares      = 30_000_000 / 1.0                = 30_000_000
//   terminal floor    = 30_000_000 * 2.0                = 60_000_000
//   max terminal      = 100_000_000 * 600_000_001 / 1e9 = 60_000_000 (floor)
//     -> terminal floor >= max terminal: floor terms abort.
#[test, expected_failure(abort_code = strike_exposure_config::ETerminalFloorExceedsLiquidationLtv)]
fun mint_terminal_floor_at_liquidation_ltv_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_templates(
        option::none(),
        option::some(LTV_JUST_ABOVE_TWO_AND_HALF_X_FLOOR_SHARE),
        option::some(config_constants::max_terminal_floor_index!()),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        TERMINAL_FLOOR_QUANTITY,
        LEVERAGE_TWO_AND_HALF_X,
    );
    abort 999
}
