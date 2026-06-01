// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::expiry_market_tests;

use deepbook_predict::{
    constants,
    expiry_market::{Self, ExpiryMarket},
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    order,
    predict_manager::PredictManager,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, test_scenario::{Self as test, return_shared}, vec_set};

const NOW_MS: u64 = 100_000;
const EXPIRY_MS: u64 = 200_000;
const MIN_STRIKE: u64 = 100_000_000_000;
const TICK_SIZE: u64 = 1_000_000_000;
const LIVE_PRICE: u64 = 100_000_000_000;
const SETTLEMENT_PRICE: u64 = 99_000_000_000;
const LIVE_SOURCE_TIMESTAMP_MS: u64 = 99_000;
const MIN_FEE_LOWER_STRIKE: u64 = 100_000_000_000;

const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_DEPOSIT: u64 = 1_000_000_000;
const MINT_FEE: u64 = 5_000_000;
const REBATE_RESERVE: u64 = 2_500_000;
const GROSS_PROFIT_ONE: u64 = 1;
const FULL_REBATE_STAKE: u64 = 1_100_000_000_000;
const EXPECTED_REBATE_WITH_ONE_GROSS_PROFIT: u64 = 2_499_999;

#[test]
fun rebate_eligibility_offsets_fee_reserve_by_gross_profit() {
    let mut scenario = test::begin(test_constants::alice());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_base_fee(&admin_cap, 1);
    config.set_min_ask_price(&admin_cap, 0);
    let cap = market_oracle::create_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        MIN_STRIKE,
        TICK_SIZE,
        constants::default_expiry_preallocated_ticks!(),
        constants::float_scaling!(),
        scenario.ctx(),
    );
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());
    scenario.next_tx(test_constants::alice());
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);

    prepare_live_oracle_for_trading(&mut oracle, &mut pyth, &config, &cap, &clock);
    market.receive_pool_cash(coin::mint_for_testing<DUSDC>(
        constants::expiry_cash_floor!(),
        scenario.ctx(),
    ).into_balance());
    manager.deposit(
        coin::mint_for_testing<DUSDC>(MINT_DEPOSIT, scenario.ctx()),
        scenario.ctx(),
    );

    let order_id = market.mint(
        &mut manager,
        &config,
        &oracle,
        &pyth,
        MIN_FEE_LOWER_STRIKE,
        constants::pos_inf!(),
        MINT_QUANTITY,
        order::leverage_one_x(),
        &clock,
        scenario.ctx(),
    );
    assert_eq!(manager.trading_fees_paid(expiry_id), MINT_FEE);
    assert_eq!(market.rebate_reserve(), REBATE_RESERVE);

    let order = order::from_order_id(order_id);
    manager.record_gross_received_from_expiry(
        expiry_id,
        order.user_contribution() + GROSS_PROFIT_ONE,
    );
    manager.remove_position(expiry_id, order_id);
    manager.add_inactive_stake(FULL_REBATE_STAKE);
    return_shared(market);

    scenario.next_epoch(test_constants::alice());
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    settle_oracle(&mut oracle, &mut pyth, &config, &cap, &mut clock);

    let balance_before_claim = manager.balance();
    let residual_cash = market.claim_trading_loss_rebate(
        &mut manager,
        &config,
        &oracle,
        scenario.ctx(),
    );

    assert_eq!(manager.balance(), balance_before_claim + EXPECTED_REBATE_WITH_ONE_GROSS_PROFIT);
    assert_eq!(residual_cash.value(), GROSS_PROFIT_ONE);
    assert_eq!(market.rebate_reserve(), 0);

    destroy(residual_cash);
    return_shared(market);
    destroy(manager);
    destroy(oracle);
    destroy(pyth);
    market_oracle::destroy_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}

fun prepare_live_oracle_for_trading(
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    clock: &Clock,
) {
    pyth.set_state_for_testing(
        LIVE_PRICE,
        LIVE_SOURCE_TIMESTAMP_MS,
        LIVE_SOURCE_TIMESTAMP_MS,
    );
    oracle.update_block_scholes_prices(
        config,
        pyth,
        cap,
        LIVE_PRICE,
        LIVE_PRICE,
        LIVE_SOURCE_TIMESTAMP_MS,
        clock,
    );
    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    oracle.update_svi(
        config,
        cap,
        svi,
        LIVE_SOURCE_TIMESTAMP_MS,
        clock,
    );
}

fun settle_oracle(
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    config: &ProtocolConfig,
    cap: &MarketOracleCap,
    clock: &mut Clock,
) {
    let settlement_source_timestamp_ms = EXPIRY_MS + 1_000;
    let settlement_update_timestamp_ms = EXPIRY_MS + 2_000;
    clock.set_for_testing(settlement_update_timestamp_ms);
    pyth.set_state_for_testing(
        SETTLEMENT_PRICE,
        settlement_source_timestamp_ms,
        settlement_update_timestamp_ms,
    );
    assert!(
        oracle.settle_if_possible(
            config,
            pyth,
            cap,
            clock,
        ),
    );
}
