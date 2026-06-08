// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP NAV tests for the verified-floor Q haircut.
#[test_only]
module deepbook_predict::plp_nav_haircut_tests;

use deepbook::math;
use deepbook_predict::{
    constants::{Self, float_scaling as float},
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    order,
    plp::{Self, PoolVault},
    predict_manager::PredictManager,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::clock::Clock;

const FAR_EXPIRY_MS: u64 = 31_536_100_000;
const OPEN_PRICE: u64 = 100_000_000_000;
const STRESS_PRICE: u64 = 10;
const OPEN_SOURCE_TIMESTAMP_MS: u64 = 99_000;
const STRESS_SOURCE_TIMESTAMP_MS: u64 = 99_500;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const HEALTHY_QUANTITY: u64 = 1_000_000_000;
const UNDERWATER_QUANTITY: u64 = 100_000_000;
const ONE_X_QUANTITY: u64 = 100_000_000;
const TRADE_PASS_QUANTITY: u64 = 10_000_000;
const ZERO_PROTOCOL_SHARE: u64 = 0;

const MIN_VALUATION_BUDGET: u64 = 24;
const HALF_SCAN_HEALTHY_COUNT: u64 = 4;
const HALF_SCAN_UNDERWATER_COUNT: u64 = 48;
const TRANSIENT_HEALTHY_COUNT: u64 = 4;
const TRANSIENT_UNDERWATER_COUNT: u64 = 60;
const MAX_TRADE_BUDGET: u64 = 3_000;

#[test]
fun sync_expiry_haircuts_unverified_underfloor_orders() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(FAR_EXPIRY_MS);
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.set_protocol_reserve_profit_share(&mut config, ZERO_PROTOCOL_SHARE);
    fx.set_valuation_liquidation_budget(&mut config, MIN_VALUATION_BUDGET);
    fx.prepare_live_oracle_at(
        &config,
        &mut oracle,
        &mut pyth,
        OPEN_PRICE,
        OPEN_SOURCE_TIMESTAMP_MS,
    );
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let healthy_floor = mint_order_set_floor_sum(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        HEALTHY_QUANTITY,
        LEVERAGE_TWO_X,
        HALF_SCAN_HEALTHY_COUNT,
    );
    mint_order_set(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        UNDERWATER_QUANTITY,
        LEVERAGE_TWO_X,
        HALF_SCAN_UNDERWATER_COUNT,
    );

    fx.set_pyth_price_for_testing(&mut pyth, STRESS_PRICE, STRESS_SOURCE_TIMESTAMP_MS);
    assert_stress_range_prices(&config, &oracle, &pyth, fx.clock());

    let healthy_true_liability = HEALTHY_QUANTITY * HALF_SCAN_HEALTHY_COUNT - healthy_floor;
    let (recorded_active_nav, optimistic_nav) = sync_and_observe_active_nav(
        &fx,
        &mut config,
        &mut vault,
        &mut market,
        &oracle,
        &pyth,
    );
    let true_nav = market.cash_balance() - market.rebate_reserve() - healthy_true_liability;

    assert!(recorded_active_nav < optimistic_nav);
    assert!(recorded_active_nav >= true_nav);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

#[test]
fun sync_expiry_one_x_only_keeps_optimistic_nav() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(FAR_EXPIRY_MS);
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.set_protocol_reserve_profit_share(&mut config, ZERO_PROTOCOL_SHARE);
    fx.prepare_live_oracle_at(
        &config,
        &mut oracle,
        &mut pyth,
        OPEN_PRICE,
        OPEN_SOURCE_TIMESTAMP_MS,
    );
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    mint_order_set(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
        MIN_VALUATION_BUDGET,
    );

    fx.set_pyth_price_for_testing(&mut pyth, STRESS_PRICE, STRESS_SOURCE_TIMESTAMP_MS);
    assert_stress_range_prices(&config, &oracle, &pyth, fx.clock());

    let (recorded_active_nav, optimistic_nav) = sync_and_observe_active_nav(
        &fx,
        &mut config,
        &mut vault,
        &mut market,
        &oracle,
        &pyth,
    );

    assert_eq!(recorded_active_nav, optimistic_nav);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

#[test]
fun trade_time_verification_does_not_leak_into_later_valuation() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(FAR_EXPIRY_MS);
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.set_protocol_reserve_profit_share(&mut config, ZERO_PROTOCOL_SHARE);
    fx.set_trade_liquidation_budget(&mut config, MAX_TRADE_BUDGET);
    fx.set_valuation_liquidation_budget(&mut config, MIN_VALUATION_BUDGET);
    fx.prepare_live_oracle_at(
        &config,
        &mut oracle,
        &mut pyth,
        OPEN_PRICE,
        OPEN_SOURCE_TIMESTAMP_MS,
    );
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let healthy_floor = mint_order_set_floor_sum(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        HEALTHY_QUANTITY,
        LEVERAGE_TWO_X,
        TRANSIENT_HEALTHY_COUNT,
    );
    mint_order_set(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        UNDERWATER_QUANTITY,
        LEVERAGE_TWO_X,
        TRANSIENT_UNDERWATER_COUNT,
    );
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        TRADE_PASS_QUANTITY,
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.scenario_mut().next_tx(test_constants::admin());
    let (mut pyth, mut vault, mut market, oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );

    fx.set_pyth_price_for_testing(&mut pyth, STRESS_PRICE, STRESS_SOURCE_TIMESTAMP_MS);
    assert_stress_range_prices(&config, &oracle, &pyth, fx.clock());

    let healthy_true_liability = HEALTHY_QUANTITY * TRANSIENT_HEALTHY_COUNT - healthy_floor;
    let (recorded_active_nav, optimistic_nav) = sync_and_observe_active_nav(
        &fx,
        &mut config,
        &mut vault,
        &mut market,
        &oracle,
        &pyth,
    );
    let true_nav = market.cash_balance() - market.rebate_reserve() - healthy_true_liability;

    assert!(recorded_active_nav < optimistic_nav);
    assert!(recorded_active_nav >= true_nav);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

fun mint_order_set(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
    count: u64,
) {
    let mut i = 0;
    while (i < count) {
        fx.mint(
            config,
            manager,
            market,
            oracle,
            pyth,
            lower,
            higher,
            quantity,
            leverage,
        );
        i = i + 1;
    };
}

fun mint_order_set_floor_sum(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
    count: u64,
): u64 {
    let mut floor_sum = 0;
    let mut i = 0;
    while (i < count) {
        let order_id = fx.mint(
            config,
            manager,
            market,
            oracle,
            pyth,
            lower,
            higher,
            quantity,
            leverage,
        );
        let minted_order = order::from_order_id(order_id);
        floor_sum = floor_sum + math::mul(minted_order.floor_shares(), float!());
        i = i + 1;
    };
    floor_sum
}

fun sync_and_observe_active_nav(
    fx: &helpers::Fixture,
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): (u64, u64) {
    let mut sync = plp::start_pool_sync(config, vault);
    sync.sync_expiry(vault, market, config, oracle, pyth, fx.clock());
    let (optimistic_nav, _, _) = market.pool_nav(config, oracle, pyth, fx.clock());
    let pool_value = vault.finish_pool_sync(config, sync);
    (pool_value - vault.idle_balance(), optimistic_nav)
}

fun assert_stress_range_prices(
    config: &ProtocolConfig,
    oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
) {
    let up_price = pricing::live_range_probability(
        config.pricing_config(),
        oracle,
        pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        clock,
    );
    let down_price = pricing::live_range_probability(
        config.pricing_config(),
        oracle,
        pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        clock,
    );

    assert_eq!(up_price, 0);
    assert_eq!(down_price, float!());
}
