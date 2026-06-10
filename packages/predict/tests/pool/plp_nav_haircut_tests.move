// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP NAV tests for the verified-floor Q haircut.
#[test_only]
module deepbook_predict::plp_nav_haircut_tests;

use deepbook_predict::{
    constants,
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
use predict_math::math::{Self, float_scaling as float};
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

const CRASH_OPEN_RANGE_PRICE: u64 = 500_000_000;
const CRASH_UNDERWATER_QUANTITY: u64 = 1_000_000_000;
const CRASH_UNDERWATER_EXPOSURE_VALUE: u64 = 500_000_000;
const CRASH_UNDERWATER_USER_CONTRIBUTION: u64 = 250_000_000;
const CRASH_HEALTHY_COUNT: u64 = 2;
const CRASH_UNDERWATER_COUNT: u64 = 36;
const CRASH_REMAINING_UNDERWATER_AFTER_SUPPLY_SYNC: u64 = 12;
const CRASH_REMAINING_UNDERWATER_AFTER_WITHDRAW_SYNC: u64 = 0;
const CRASH_UNDERWATER_FLOOR_AMOUNT: u64 = 250_000_000;
const CRASH_TRUE_LIABILITY: u64 = 2_000_000_000;
const CRASH_SUPPLY_SYNC_TOTAL_FLOOR: u64 = 3_000_000_000;
const CRASH_WITHDRAW_SYNC_TOTAL_FLOOR: u64 = 0;
const CRASH_SUPPLY_SYNC_OPTIMISTIC_ACTIVE_NAV: u64 = 50_000_000_000;
const CRASH_WITHDRAW_SYNC_OPTIMISTIC_ACTIVE_NAV: u64 = 48_000_000_000;
const CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV: u64 = 49_000_000_000;
const CRASH_WITHDRAW_SYNC_CONSERVATIVE_ACTIVE_NAV: u64 = 48_000_000_000;
const CRASH_TRUE_NAV: u64 = 48_000_000_000;
const CRASH_IDLE_AFTER_SUPPLY_SYNC: u64 = 260_000_000_000;
const CRASH_POOL_VALUE_FOR_SUPPLY: u64 = 309_000_000_000;
const CRASH_SUPPLY_PAYMENT: u64 = 3_090_000_000;
const CRASH_EXPECTED_SUPPLY_SHARES: u64 = 2_999_999_998;
const CRASH_EXPECTED_WITHDRAW_DUSDC: u64 = 3_080_098_979;

const FEE_TEST_SUPPLY_PAYMENT: u64 = 3_000_000_000;
const FEE_TEST_EXPECTED_SUPPLY_SHARES: u64 = 3_000_000_000;
const FEE_TEST_IDLE_AFTER_STRESS_SYNC: u64 = 263_000_000_000;
const FEE_TEST_POOL_VALUE_BEFORE_WITHDRAW: u64 = 312_000_000_000;
const FEE_TEST_EXPECTED_GROSS_WITHDRAW: u64 = 3_089_108_880;
const FEE_TEST_AGGREGATE_BAND: u64 = 2_000_000_000;
const FEE_TEST_EXPECTED_FEE: u64 = 4_950_495;
const FEE_TEST_EXPECTED_NET_WITHDRAW: u64 = 3_084_158_385;
const FEE_TEST_EXPECTED_IDLE_AFTER_WITHDRAW: u64 = 259_915_841_615;
const IDLE_DRAIN_ROUNDING_DUST: u64 = 100;

#[test]
fun withdraw_can_drain_idle_with_active_expiry_after_sync() {
    let (mut fx, expiry_id, oracle_id, manager) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let (pyth, mut vault, mut market, oracle, mut config) = fx.take_market(expiry_id, oracle_id);
    let idle_before = vault.idle_balance();
    assert_eq!(
        idle_before,
        test_constants::default_initial_supply() - constants::expiry_cash_floor!(),
    );

    let lp_to_withdraw = fx.split_initial_plp(idle_before);
    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let (dusdc, sui, deep) = fx.withdraw(&mut config, &mut vault, sync, lp_to_withdraw);
    assert_eq!(dusdc.value(), idle_before - IDLE_DRAIN_ROUNDING_DUST);
    assert_eq!(vault.idle_balance(), IDLE_DRAIN_ROUNDING_DUST);
    assert_eq!(sui.value(), 0);
    assert_eq!(deep.value(), 0);
    destroy(dusdc);
    destroy(sui);
    destroy(deep);

    let dust_plp = fx.split_initial_plp(IDLE_DRAIN_ROUNDING_DUST);
    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let (dusdc, sui, deep) = fx.withdraw(&mut config, &mut vault, sync, dust_plp);
    assert_eq!(dusdc.value(), IDLE_DRAIN_ROUNDING_DUST);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(sui.value(), 0);
    assert_eq!(deep.value(), 0);
    destroy(dusdc);
    destroy(sui);
    destroy(deep);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

#[test]
fun aggregate_floor_deficit_keeps_sync_supply_and_withdraw_live() {
    let mut fx = helpers::setup_pool_with_pyth();
    fx.set_template_zero_min_fee();
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
    assert_crash_open_range_prices(&config, &oracle, &pyth, fx.clock());
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    mint_order_set(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        HEALTHY_QUANTITY,
        test_constants::leverage_one_x(),
        CRASH_HEALTHY_COUNT,
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
        CRASH_UNDERWATER_QUANTITY,
        LEVERAGE_TWO_X,
        CRASH_UNDERWATER_COUNT,
    );
    assert_eq!(market.rebate_reserve(), 0);

    fx.set_pyth_price_for_testing(&mut pyth, STRESS_PRICE, STRESS_SOURCE_TIMESTAMP_MS);
    assert_stress_range_prices(&config, &oracle, &pyth, fx.clock());

    // First stress sync:
    //   36 underwater 2x UP orders - 24 liquidated = 12 remaining.
    //   total_range = 2 healthy 1x DOWN orders * 1_000_000_000 = 2_000_000_000.
    //   total_floor = 12 * 250_000_000 = 3_000_000_000.
    //   optimistic active NAV = cash floor 50_000_000_000.
    //   Q = 3_000_000_000 - 2_000_000_000 = 1_000_000_000.
    //   conservative active NAV = 50_000_000_000 - Q = 49_000_000_000.
    //   TRUE NAV = 50_000_000_000 - 2_000_000_000 = 48_000_000_000.
    let mut supply_sync = plp::start_pool_sync(&mut config, &vault);
    supply_sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let (supply_optimistic_nav, supply_total_range, supply_total_floor) = market.pool_nav(
        &config,
        &oracle,
        &pyth,
        fx.clock(),
    );
    assert_eq!(supply_total_range, CRASH_TRUE_LIABILITY);
    assert_eq!(supply_total_floor, CRASH_SUPPLY_SYNC_TOTAL_FLOOR);
    assert_eq!(supply_optimistic_nav, CRASH_SUPPLY_SYNC_OPTIMISTIC_ACTIVE_NAV);
    assert_eq!(
        CRASH_SUPPLY_SYNC_TOTAL_FLOOR,
        CRASH_REMAINING_UNDERWATER_AFTER_SUPPLY_SYNC * CRASH_UNDERWATER_FLOOR_AMOUNT,
    );
    assert_eq!(
        CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV,
        CRASH_SUPPLY_SYNC_OPTIMISTIC_ACTIVE_NAV
            - (CRASH_SUPPLY_SYNC_TOTAL_FLOOR - CRASH_TRUE_LIABILITY),
    );
    assert!(CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV >= CRASH_TRUE_NAV);
    assert!(CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV <= CRASH_SUPPLY_SYNC_OPTIMISTIC_ACTIVE_NAV);
    assert_eq!(vault.idle_balance(), CRASH_IDLE_AFTER_SUPPLY_SYNC);
    assert_eq!(
        CRASH_POOL_VALUE_FOR_SUPPLY,
        CRASH_IDLE_AFTER_SUPPLY_SYNC + CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV,
    );

    let supplied_plp = fx.supply(
        &mut config,
        &mut vault,
        supply_sync,
        &pyth,
        CRASH_SUPPLY_PAYMENT,
    );
    assert_eq!(supplied_plp.value(), CRASH_EXPECTED_SUPPLY_SHARES);

    // Second stress sync for withdraw:
    //   12 remaining underwater orders - 12 liquidated = 0 remaining.
    //   total_floor = 0, total_range = 2_000_000_000, so the clamp is a no-op.
    //   optimistic active NAV = conservative active NAV = TRUE = 48_000_000_000.
    let mut withdraw_sync = plp::start_pool_sync(&mut config, &vault);
    withdraw_sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let (withdraw_optimistic_nav, withdraw_total_range, withdraw_total_floor) = market.pool_nav(
        &config,
        &oracle,
        &pyth,
        fx.clock(),
    );
    assert_eq!(withdraw_total_range, CRASH_TRUE_LIABILITY);
    assert_eq!(withdraw_total_floor, CRASH_WITHDRAW_SYNC_TOTAL_FLOOR);
    assert_eq!(withdraw_optimistic_nav, CRASH_WITHDRAW_SYNC_OPTIMISTIC_ACTIVE_NAV);
    assert_eq!(
        CRASH_WITHDRAW_SYNC_TOTAL_FLOOR,
        CRASH_REMAINING_UNDERWATER_AFTER_WITHDRAW_SYNC * CRASH_UNDERWATER_FLOOR_AMOUNT,
    );
    assert_eq!(
        CRASH_WITHDRAW_SYNC_CONSERVATIVE_ACTIVE_NAV,
        CRASH_WITHDRAW_SYNC_OPTIMISTIC_ACTIVE_NAV,
    );
    assert!(CRASH_WITHDRAW_SYNC_CONSERVATIVE_ACTIVE_NAV >= CRASH_TRUE_NAV);
    assert!(
        CRASH_WITHDRAW_SYNC_CONSERVATIVE_ACTIVE_NAV <= CRASH_WITHDRAW_SYNC_OPTIMISTIC_ACTIVE_NAV,
    );

    let (dusdc, sui, deep) = fx.withdraw(&mut config, &mut vault, withdraw_sync, supplied_plp);
    assert_eq!(dusdc.value(), CRASH_EXPECTED_WITHDRAW_DUSDC);
    assert_eq!(sui.value(), 0);
    assert_eq!(deep.value(), 0);
    destroy(dusdc);
    destroy(sui);
    destroy(deep);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

#[test]
fun withdraw_deducts_synced_uncertainty_band_fee_and_retains_idle() {
    let mut fx = helpers::setup_pool_with_pyth();
    fx.set_template_zero_min_fee();
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
    assert_crash_open_range_prices(&config, &oracle, &pyth, fx.clock());
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    let mut supply_sync = plp::start_pool_sync(&mut config, &vault);
    supply_sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let fee_test_plp = fx.supply(
        &mut config,
        &mut vault,
        supply_sync,
        &pyth,
        FEE_TEST_SUPPLY_PAYMENT,
    );
    assert_eq!(fee_test_plp.value(), FEE_TEST_EXPECTED_SUPPLY_SHARES);

    mint_order_set(
        &mut fx,
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        HEALTHY_QUANTITY,
        test_constants::leverage_one_x(),
        CRASH_HEALTHY_COUNT,
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
        CRASH_UNDERWATER_QUANTITY,
        LEVERAGE_TWO_X,
        CRASH_UNDERWATER_COUNT,
    );

    fx.set_pyth_price_for_testing(&mut pyth, STRESS_PRICE, STRESS_SOURCE_TIMESTAMP_MS);
    assert_stress_range_prices(&config, &oracle, &pyth, fx.clock());

    let mut withdraw_sync = plp::start_pool_sync(&mut config, &vault);
    withdraw_sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    let (withdraw_optimistic_nav, withdraw_total_range, withdraw_total_floor) = market.pool_nav(
        &config,
        &oracle,
        &pyth,
        fx.clock(),
    );
    assert_eq!(withdraw_total_range, CRASH_TRUE_LIABILITY);
    assert_eq!(withdraw_total_floor, CRASH_SUPPLY_SYNC_TOTAL_FLOOR);
    assert_eq!(withdraw_optimistic_nav, CRASH_SUPPLY_SYNC_OPTIMISTIC_ACTIVE_NAV);
    assert_eq!(FEE_TEST_AGGREGATE_BAND, CRASH_TRUE_LIABILITY.min(CRASH_SUPPLY_SYNC_TOTAL_FLOOR));
    assert_eq!(vault.idle_balance(), FEE_TEST_IDLE_AFTER_STRESS_SYNC);
    assert_eq!(
        FEE_TEST_POOL_VALUE_BEFORE_WITHDRAW,
        FEE_TEST_IDLE_AFTER_STRESS_SYNC + CRASH_SUPPLY_SYNC_CONSERVATIVE_ACTIVE_NAV,
    );

    // Gross withdraw = 312_000_000_000 * floor(3_000_000_000 / 303_000_000_000)
    //                = 312_000_000_000 * 9_900_990 / 1e9 = 3_089_108_880.
    // Fee band = min(D_max 3_000_000_000, unscanned_range 2_000_000_000).
    // Default alpha is 25%, so total fee pool = 500_000_000 and
    // withdraw fee = 500_000_000 * 9_900_990 / 1e9 = 4_950_495.
    let idle_before_withdraw = vault.idle_balance();
    let (dusdc, sui, deep) = fx.withdraw(&mut config, &mut vault, withdraw_sync, fee_test_plp);
    assert_eq!(
        FEE_TEST_EXPECTED_NET_WITHDRAW,
        FEE_TEST_EXPECTED_GROSS_WITHDRAW - FEE_TEST_EXPECTED_FEE,
    );
    assert_eq!(dusdc.value(), FEE_TEST_EXPECTED_NET_WITHDRAW);
    assert_eq!(idle_before_withdraw - vault.idle_balance(), FEE_TEST_EXPECTED_NET_WITHDRAW);
    assert_eq!(vault.idle_balance(), FEE_TEST_EXPECTED_IDLE_AFTER_WITHDRAW);
    assert_eq!(sui.value(), 0);
    assert_eq!(deep.value(), 0);
    destroy(dusdc);
    destroy(sui);
    destroy(deep);

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}

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

fun assert_crash_open_range_prices(
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

    assert_eq!(up_price, CRASH_OPEN_RANGE_PRICE);
    assert_eq!(down_price, CRASH_OPEN_RANGE_PRICE);
    assert_eq!(math::mul(up_price, CRASH_UNDERWATER_QUANTITY), CRASH_UNDERWATER_EXPOSURE_VALUE);
    assert_eq!(
        math::div(CRASH_UNDERWATER_EXPOSURE_VALUE, LEVERAGE_TWO_X),
        CRASH_UNDERWATER_USER_CONTRIBUTION,
    );
    assert_eq!(
        CRASH_UNDERWATER_EXPOSURE_VALUE - CRASH_UNDERWATER_USER_CONTRIBUTION,
        CRASH_UNDERWATER_FLOOR_AMOUNT,
    );
}
