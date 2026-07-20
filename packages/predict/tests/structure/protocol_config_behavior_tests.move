// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural coverage for ProtocolConfig's live admin projection surface.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__protocol_config_tests;

use deepbook_predict::{
    config_constants,
    ewma_config,
    expiry_cash_config,
    pricing_config,
    stake_config,
    strike_exposure_config,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const BASE_FEE: u64 = 31_000_000;
const MIN_FEE: u64 = 7_000_000;
const MIN_ENTRY_PROBABILITY: u64 = 20_000_000;
const MAX_ENTRY_PROBABILITY: u64 = 980_000_000;
const EXPIRY_FEE_WINDOW_MS: u64 = 300_000;
const EXPIRY_FEE_MULTIPLIER: u64 = 2_000_000_000;
const NO_LEVERAGE_WINDOW_MS: u64 = 60_000;
const LIQUIDATION_LTV: u64 = 800_000_000;
const MAX_LEVERAGE: u64 = 2_000_000_000;
const BACKING_LAMBDA: u64 = 300_000_000;
const REBATE_RATE: u64 = 250_000_000;
const PYTH_FRESHNESS_MS: u64 = 1_111;
const BS_PRICE_FRESHNESS_MS: u64 = 2_222;
const BS_SVI_FRESHNESS_MS: u64 = 3_333;
const RESERVE_PROFIT_SHARE: u64 = 250_000_000;
const LIQUIDATION_BUDGET: u64 = 48;
const EWMA_ALPHA: u64 = 25_000_000;
const EWMA_Z_SCORE: u64 = 2_000_000_000;
const EWMA_PENALTY_RATE: u64 = 1_500_000;

#[test]
fun admin_setters_project_each_live_configuration_value() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_template_base_fee(&admin_cap, BASE_FEE);
    config.set_template_min_fee(&admin_cap, MIN_FEE);
    config.set_template_min_entry_probability(&admin_cap, MIN_ENTRY_PROBABILITY);
    config.set_template_max_entry_probability(&admin_cap, MAX_ENTRY_PROBABILITY);
    config.set_template_expiry_fee_window_ms(&admin_cap, EXPIRY_FEE_WINDOW_MS);
    config.set_template_expiry_fee_max_multiplier(&admin_cap, EXPIRY_FEE_MULTIPLIER);
    config.set_template_no_leverage_window_ms(&admin_cap, NO_LEVERAGE_WINDOW_MS);
    config.set_template_liquidation_ltv(&admin_cap, LIQUIDATION_LTV);
    config.set_template_max_admission_leverage(&admin_cap, MAX_LEVERAGE);
    config.set_template_backing_buffer_lambda(&admin_cap, BACKING_LAMBDA);
    config.set_template_trading_loss_rebate_rate(&admin_cap, REBATE_RATE);
    config.set_pyth_spot_freshness_ms(&admin_cap, PYTH_FRESHNESS_MS);
    config.set_block_scholes_price_freshness_ms(&admin_cap, BS_PRICE_FRESHNESS_MS);
    config.set_block_scholes_svi_freshness_ms(&admin_cap, BS_SVI_FRESHNESS_MS);
    config.set_protocol_reserve_profit_share(&admin_cap, RESERVE_PROFIT_SHARE);
    config.set_trade_liquidation_budget(&admin_cap, LIQUIDATION_BUDGET);
    config.set_ewma_params(&admin_cap, EWMA_ALPHA, EWMA_Z_SCORE, EWMA_PENALTY_RATE);
    config.set_ewma_enabled(&admin_cap, true);
    config.set_benefit_powers(
        &admin_cap,
        config_constants::min_lower_benefit_power!(),
        config_constants::min_upper_benefit_power!(),
    );

    let strike = config.strike_exposure_template_config();
    assert_eq!(strike_exposure_config::base_fee(strike), BASE_FEE);
    assert_eq!(strike_exposure_config::min_fee(strike), MIN_FEE);
    assert_eq!(strike_exposure_config::min_entry_probability(strike), MIN_ENTRY_PROBABILITY);
    assert_eq!(strike_exposure_config::max_entry_probability(strike), MAX_ENTRY_PROBABILITY);
    assert_eq!(strike_exposure_config::expiry_fee_window_ms(strike), EXPIRY_FEE_WINDOW_MS);
    assert_eq!(strike_exposure_config::expiry_fee_max_multiplier(strike), EXPIRY_FEE_MULTIPLIER);
    assert_eq!(strike_exposure_config::no_leverage_window_ms(strike), NO_LEVERAGE_WINDOW_MS);
    assert_eq!(strike_exposure_config::liquidation_ltv(strike), LIQUIDATION_LTV);
    assert_eq!(strike_exposure_config::max_admission_leverage(strike), MAX_LEVERAGE);
    assert_eq!(strike_exposure_config::backing_buffer_lambda(strike), BACKING_LAMBDA);
    assert_eq!(
        expiry_cash_config::trading_loss_rebate_rate(config.expiry_cash_template_config()),
        REBATE_RATE,
    );
    let pricing = config.pricing_config();
    assert_eq!(pricing_config::pyth_spot_freshness_ms(pricing), PYTH_FRESHNESS_MS);
    assert_eq!(pricing_config::block_scholes_price_freshness_ms(pricing), BS_PRICE_FRESHNESS_MS);
    assert_eq!(pricing_config::block_scholes_svi_freshness_ms(pricing), BS_SVI_FRESHNESS_MS);
    assert_eq!(config.protocol_reserve_profit_share(), RESERVE_PROFIT_SHARE);
    assert_eq!(config.trade_liquidation_budget(), LIQUIDATION_BUDGET);
    let ewma = config.ewma_config();
    assert_eq!(ewma_config::alpha(ewma), EWMA_ALPHA);
    assert_eq!(ewma_config::z_score_threshold(ewma), EWMA_Z_SCORE);
    assert_eq!(ewma_config::penalty_rate(ewma), EWMA_PENALTY_RATE);
    assert!(ewma_config::enabled(ewma));
    assert_eq!(
        stake_config::rebate_amount(
            config.stake_config(),
            1_000,
            config_constants::min_lower_benefit_power!(),
        ),
        500,
    );

    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}
