// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::expiry_market_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market::{Self, ExpiryMarket},
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleWriterCap, MarketOracleLifecycleCap},
    order,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource},
    registry,
    strike_grid,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{
    clock::{Self, Clock},
    coin,
    test_scenario::{Self as test, return_shared, Scenario},
    vec_set
};

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

fun grid_center_spot(): u64 {
    MIN_STRIKE + TICK_SIZE * (constants::oracle_strike_grid_ticks!() / 2)
}

// EWMA penalty fixtures. Gas sequence 1000 -> 2000 -> 3000 puts the z-score at
// ~0.99 after the first observation (below 1 sigma) and ~1.94 after the second
// (above 1 sigma), so the penalty fires only on the spike. See ewma_tests.
const ONE_SIGMA: u64 = 1_000_000_000;
const SEED_GAS: u64 = 1_000;
const FIRST_TRADE_GAS: u64 = 2_000;
const SPIKE_GAS: u64 = 3_000;
const LOW_GAS: u64 = 1;
const BIG_SPIKE_GAS: u64 = 50_000;
const PENALTY_FEE_RATE: u64 = 2_000_000; // 0.2% surcharge rate
// 0.2% of MINT_QUANTITY (1e9) = 2_000_000 base units, derived independently.
const EXPECTED_PENALTY: u64 = 2_000_000;
const POOL_CASH: u64 = 1_000_000_000_000;
const LARGE_DEPOSIT: u64 = 1_000_000_000_000;

#[test]
fun rebate_eligibility_offsets_fee_reserve_by_gross_profit() {
    let mut scenario = test::begin(test_constants::alice());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_base_fee(&admin_cap, 1);
    config.set_min_ask_price(&admin_cap, 0);
    let cap = market_oracle::create_writer_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        pyth.feed_id(),
        scenario.ctx(),
    );
    market_oracle::register_lifecycle_cap(&oracle, &admin_cap, &mut lifecycle_cap);
    let grid = strike_grid::new_centered(grid_center_spot(), TICK_SIZE);
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        grid,
        constants::default_expiry_preallocated_ticks!(),
        config_constants::default_expiry_fee_window_ms!(),
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

    let proof = manager.generate_proof_as_owner(scenario.ctx());
    let order_id = market.mint(
        &mut manager,
        &proof,
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
    settle_oracle(&mut oracle, &mut pyth, &config, &lifecycle_cap, &mut clock);

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
    market_oracle::destroy_lifecycle_cap(lifecycle_cap);
    market_oracle::destroy_writer_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun mint_withholds_ewma_penalty_into_pool_on_gas_spike() {
    let mut scenario = test::begin(test_constants::alice());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_base_fee(&admin_cap, 1);
    config.set_min_ask_price(&admin_cap, 0);
    config.set_ewma_params(
        &admin_cap,
        config_constants::default_ewma_alpha!(),
        ONE_SIGMA,
        PENALTY_FEE_RATE,
    );
    config.set_ewma_enabled(&admin_cap, true);
    let cap = market_oracle::create_writer_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );

    // Seed the market's EWMA mean at SEED_GAS.
    advance_to_gas(&mut scenario, SEED_GAS);
    let grid = strike_grid::new_centered(grid_center_spot(), TICK_SIZE);
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        grid,
        constants::default_expiry_preallocated_ticks!(),
        config_constants::default_expiry_fee_window_ms!(),
        constants::float_scaling!(),
        scenario.ctx(),
    );
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());
    prepare_live_oracle_for_trading(&mut oracle, &mut pyth, &config, &cap, &clock);
    manager.deposit(
        coin::mint_for_testing<DUSDC>(LARGE_DEPOSIT, scenario.ctx()),
        scenario.ctx(),
    );

    // First mint at FIRST_TRADE_GAS seeds variance; z ~= 0.99 < 1 sigma, no penalty.
    advance_to_gas(&mut scenario, FIRST_TRADE_GAS);
    clock.set_for_testing(NOW_MS);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    market.receive_pool_cash(coin::mint_for_testing<DUSDC>(
        POOL_CASH,
        scenario.ctx(),
    ).into_balance());
    let balance_before_first = manager.balance();
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    market.mint(
        &mut manager,
        &proof,
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
    let first_mint_cost = balance_before_first - manager.balance();
    return_shared(market);

    // Second mint at SPIKE_GAS: z ~= 1.94 > 1 sigma, penalty fires.
    advance_to_gas(&mut scenario, SPIKE_GAS);
    clock.set_for_testing(NOW_MS + 1);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let balance_before_second = manager.balance();
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    market.mint(
        &mut manager,
        &proof,
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
    let second_mint_cost = balance_before_second - manager.balance();

    // Identical orders, so the only extra cost on the spike is the surcharge.
    assert_eq!(second_mint_cost - first_mint_cost, EXPECTED_PENALTY);
    // The penalty is pool surplus, not a recorded trading fee.
    assert_eq!(manager.trading_fees_paid(expiry_id), 2 * MINT_FEE);

    return_shared(market);
    destroy(manager);
    destroy(oracle);
    destroy(pyth);
    market_oracle::destroy_writer_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun redeem_withholds_ewma_penalty_from_payout_on_gas_spike() {
    let mut scenario = test::begin(test_constants::alice());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_base_fee(&admin_cap, 1);
    config.set_min_ask_price(&admin_cap, 0);
    config.set_ewma_params(
        &admin_cap,
        config_constants::default_ewma_alpha!(),
        ONE_SIGMA,
        PENALTY_FEE_RATE,
    );
    config.set_ewma_enabled(&admin_cap, true);
    let cap = market_oracle::create_writer_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );

    advance_to_gas(&mut scenario, SEED_GAS);
    let grid = strike_grid::new_centered(grid_center_spot(), TICK_SIZE);
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        grid,
        constants::default_expiry_preallocated_ticks!(),
        config_constants::default_expiry_fee_window_ms!(),
        constants::float_scaling!(),
        scenario.ctx(),
    );
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());
    prepare_live_oracle_for_trading(&mut oracle, &mut pyth, &config, &cap, &clock);
    manager.deposit(
        coin::mint_for_testing<DUSDC>(LARGE_DEPOSIT, scenario.ctx()),
        scenario.ctx(),
    );

    // Mint two identical positions; their later redeems differ only by penalty.
    advance_to_gas(&mut scenario, FIRST_TRADE_GAS);
    clock.set_for_testing(NOW_MS);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    market.receive_pool_cash(coin::mint_for_testing<DUSDC>(
        POOL_CASH,
        scenario.ctx(),
    ).into_balance());
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    let order_a = market.mint(
        &mut manager,
        &proof,
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
    return_shared(market);

    advance_to_gas(&mut scenario, FIRST_TRADE_GAS);
    clock.set_for_testing(NOW_MS + 1);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    let order_b = market.mint(
        &mut manager,
        &proof,
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
    return_shared(market);

    // Redeem A at LOW_GAS: gas below the mean, so no penalty applies.
    advance_to_gas(&mut scenario, LOW_GAS);
    clock.set_for_testing(NOW_MS + 2);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let balance_before_a = manager.balance();
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    market.redeem(
        &mut manager,
        proof,
        &config,
        &oracle,
        &pyth,
        order_a,
        MINT_QUANTITY,
        &clock,
        scenario.ctx(),
    );
    let payout_a = manager.balance() - balance_before_a;
    return_shared(market);

    // Redeem B at BIG_SPIKE_GAS: z far above 1 sigma, penalty withheld.
    advance_to_gas(&mut scenario, BIG_SPIKE_GAS);
    clock.set_for_testing(NOW_MS + 3);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let balance_before_b = manager.balance();
    let proof = manager.generate_proof_as_owner(scenario.ctx());
    market.redeem(
        &mut manager,
        proof,
        &config,
        &oracle,
        &pyth,
        order_b,
        MINT_QUANTITY,
        &clock,
        scenario.ctx(),
    );
    let payout_b = manager.balance() - balance_before_b;

    // Identical positions: the penalized redeem pays exactly the surcharge less.
    assert_eq!(payout_a - payout_b, EXPECTED_PENALTY);

    return_shared(market);
    destroy(manager);
    destroy(oracle);
    destroy(pyth);
    market_oracle::destroy_writer_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun compact_storage_accepts_registered_lifecycle_cap() {
    let mut scenario = test::begin(test_constants::alice());
    let (registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let config = protocol_config::new_for_testing(scenario.ctx());
    let cap = market_oracle::create_writer_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        pyth.feed_id(),
        scenario.ctx(),
    );
    market_oracle::register_lifecycle_cap(&oracle, &admin_cap, &mut lifecycle_cap);
    let grid = strike_grid::new_centered(grid_center_spot(), TICK_SIZE);
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        grid,
        0,
        config_constants::default_expiry_fee_window_ms!(),
        constants::float_scaling!(),
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::alice());
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    settle_oracle(&mut oracle, &mut pyth, &config, &lifecycle_cap, &mut clock);
    market.compact_storage(&config, &oracle, &lifecycle_cap);
    assert_eq!(market.payout_liability(), 0);

    return_shared(market);
    destroy(oracle);
    destroy(pyth);
    market_oracle::destroy_lifecycle_cap(lifecycle_cap);
    market_oracle::destroy_writer_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = market_oracle::EInvalidMarketOracleLifecycleCap)]
fun compact_storage_rejects_unregistered_lifecycle_cap() {
    let mut scenario = test::begin(test_constants::alice());
    let (_registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let config = protocol_config::new_for_testing(scenario.ctx());
    let cap = market_oracle::create_writer_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let mut pyth = pyth_source::new_for_testing(scenario.ctx());
    let mut oracle = market_oracle::create_test_market_oracle_with_pyth(
        &pyth,
        EXPIRY_MS,
        &cap,
        scenario.ctx(),
    );
    let unregistered_lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        pyth.feed_id(),
        scenario.ctx(),
    );
    let grid = strike_grid::new_centered(grid_center_spot(), TICK_SIZE);
    let expiry_id = expiry_market::create_and_share(
        &config,
        vec_set::singleton(constants::current_version!()),
        oracle.id(),
        pyth.feed_id(),
        EXPIRY_MS,
        grid,
        0,
        config_constants::default_expiry_fee_window_ms!(),
        constants::float_scaling!(),
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::alice());
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let mut lifecycle_cap = market_oracle::create_lifecycle_cap(
        &cap,
        pyth.feed_id(),
        scenario.ctx(),
    );
    market_oracle::register_lifecycle_cap(&oracle, &admin_cap, &mut lifecycle_cap);
    settle_oracle(&mut oracle, &mut pyth, &config, &lifecycle_cap, &mut clock);
    market.compact_storage(&config, &oracle, &unregistered_lifecycle_cap);
    abort 999
}

/// Start the next transaction with `gas_price` so the per-market EWMA observes
/// it. Only `gas_price` changes, so the reference gas price stays put and no
/// epoch advance is required.
fun advance_to_gas(scenario: &mut Scenario, gas_price: u64) {
    let builder = scenario.ctx_builder().set_gas_price(gas_price);
    scenario.next_with_context(builder);
}

fun prepare_live_oracle_for_trading(
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    config: &ProtocolConfig,
    cap: &MarketOracleWriterCap,
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
    cap: &MarketOracleLifecycleCap,
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
