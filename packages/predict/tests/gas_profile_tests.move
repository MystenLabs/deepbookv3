// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::gas_profile_tests;

use deepbook_predict::{
    constants,
    i64,
    market_key,
    oracle::{Self, OracleSVICap, OracleSVI},
    plp::PLP,
    predict::{Self, Predict},
    predict_manager::PredictManager,
    registry::{Self, AdminCap, Registry},
    vault
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, TreasuryCap},
    coin_registry::{Self, CoinRegistry, Currency},
    test_scenario::{Scenario, begin, end, return_shared}
};

const OWNER: address = @0xA;
const SYSTEM: address = @0x0;

const QUOTE_DECIMALS: u8 = 6;
const LADDER_POINTS: u64 = 21;
const LADDER_MIN_TICK_OFFSET: u64 = 13_000;
const LADDER_MAX_TICK_OFFSET: u64 = 26_000;
const LADDER_QTY: u64 = 1_000_000;
const PROFILE_QTY: u64 = 1_000_000;
const INITIAL_MANAGER_BALANCE: u64 = 10_000_000_000;
const INITIAL_VAULT_LIQUIDITY: u64 = 1_000_000_000_000;

const STRIKE_MIN_DOLLARS: u64 = 50_000;
// Representative BTC-like snapshot from
// `packages/predict/simulations/data/scenario_mar6_1000mints.csv` lines 656-658.
const SIM_SPOT_PRICE: u64 = 69_439_968_330_000;
const SIM_FORWARD_PRICE: u64 = 69_429_405_310_000;
const SIM_SVI_A: u64 = 460_000;
const SIM_SVI_B: u64 = 35_510_000;
const SIM_SVI_RHO_MAGNITUDE: u64 = 268_200_000;
const SIM_SVI_M_MAGNITUDE: u64 = 2_890_000;
const SIM_SVI_SIGMA: u64 = 72_010_000;
const SIM_PROFILED_STRIKE: u64 = 69_788_000_000_000;
const ETestAssertion: u64 = 0;

public struct ProfileQuote has key, store {
    id: UID,
}

// Warm the historical strike span to the full oracle grid, fully unwind it,
// then mint once more. The final mint should still pay the full-range curve
// rebuild cost because the matrix keeps historical bounds even after unwind.
#[test]
fun historical_full_range_mint_gas_profile() {
    let mut test = begin(OWNER);

    let clock_id = create_shared_clock(&mut test);
    let registry_id = registry::init_for_testing(test.ctx());

    test.next_tx(SYSTEM);
    let coin_registry_id = create_shared_coin_registry(&mut test);

    test.next_tx(OWNER);
    create_shared_quote_currency(&mut test, coin_registry_id);

    let predict_id;
    test.next_tx(OWNER);
    {
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let currency = test.take_shared<Currency<ProfileQuote>>();
        let clock = test.take_shared_by_id<Clock>(clock_id);
        let admin_cap = test.take_from_sender<AdminCap>();
        let plp_treasury_cap = coin::create_treasury_cap_for_testing<PLP>(test.ctx());

        predict_id = registry::create_predict<ProfileQuote>(
            &mut registry,
            &admin_cap,
            &currency,
            plp_treasury_cap,
            &clock,
            test.ctx(),
        );

        return_shared(clock);
        return_shared(currency);
        return_shared(registry);
        transfer::public_transfer(admin_cap, OWNER);
    };

    let oracle_id;
    test.next_tx(OWNER);
    {
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let mut predict = test.take_shared_by_id<Predict>(predict_id);
        let admin_cap = test.take_from_sender<AdminCap>();
        let oracle_cap = registry::create_oracle_cap(&admin_cap, test.ctx());

        oracle_id = registry::create_oracle(
            &mut registry,
            &mut predict,
            &admin_cap,
            &oracle_cap,
            b"BTC".to_string(),
            expiry_ms(),
            min_strike(),
            tick_size(),
            test.ctx(),
        );

        return_shared(predict);
        return_shared(registry);
        transfer::public_transfer(oracle_cap, OWNER);
        transfer::public_transfer(admin_cap, OWNER);
    };

    test.next_tx(OWNER);
    {
        let mut oracle = test.take_shared_by_id<OracleSVI>(oracle_id);
        let mut clock = test.take_shared_by_id<Clock>(clock_id);
        let admin_cap = test.take_from_sender<AdminCap>();
        let oracle_cap = test.take_from_sender<OracleSVICap>();

        clock::set_for_testing(&mut clock, live_timestamp_ms());
        registry::register_oracle_cap(&mut oracle, &admin_cap, &oracle_cap);
        oracle::activate(&mut oracle, &oracle_cap, &clock);
        oracle::update_prices(&mut oracle, &oracle_cap, live_prices(), &clock);
        oracle::update_svi(&mut oracle, &oracle_cap, live_svi(), &clock);

        let svi = oracle::svi(&oracle);
        let rho = oracle::svi_rho(&svi);
        let m = oracle::svi_m(&svi);
        assert!(oracle::spot_price(&oracle) == SIM_SPOT_PRICE, ETestAssertion);
        assert!(oracle::forward_price(&oracle) == SIM_FORWARD_PRICE, ETestAssertion);
        assert!(oracle::svi_a(&svi) == SIM_SVI_A, ETestAssertion);
        assert!(oracle::svi_b(&svi) == SIM_SVI_B, ETestAssertion);
        assert!(i64::magnitude(&rho) == SIM_SVI_RHO_MAGNITUDE, ETestAssertion);
        assert!(i64::is_negative(&rho), ETestAssertion);
        assert!(i64::magnitude(&m) == SIM_SVI_M_MAGNITUDE, ETestAssertion);
        assert!(!i64::is_negative(&m), ETestAssertion);
        assert!(oracle::svi_sigma(&svi) == SIM_SVI_SIGMA, ETestAssertion);

        return_shared(clock);
        return_shared(oracle);
        transfer::public_transfer(admin_cap, OWNER);
        transfer::public_transfer(oracle_cap, OWNER);
    };

    let manager_id;
    test.next_tx(OWNER);
    manager_id = predict::create_manager(test.ctx());

    test.next_tx(OWNER);
    fund_predict_and_manager(&mut test, clock_id, predict_id, manager_id);

    seed_live_ladder(&mut test, clock_id, predict_id, manager_id, oracle_id);

    test.next_tx(OWNER);
    {
        let mut predict = test.take_shared_by_id<Predict>(predict_id);
        let manager = test.take_shared_by_id<PredictManager>(manager_id);
        let (hist_min, hist_max) = vault::oracle_strike_range(
            predict::vault_mut(&mut predict),
            oracle_id,
        );
        assert!(hist_min == ladder_strike(0), ETestAssertion);
        assert!(hist_max == ladder_strike(LADDER_POINTS - 1), ETestAssertion);
        assert!(manager.position(ladder_key(oracle_id, 0)) == LADDER_QTY, ETestAssertion);
        assert!(
            manager.position(ladder_key(oracle_id, LADDER_POINTS / 2)) == LADDER_QTY,
            ETestAssertion,
        );
        assert!(
            manager.position(ladder_key(oracle_id, LADDER_POINTS - 1)) == LADDER_QTY,
            ETestAssertion,
        );
        return_shared(manager);
        return_shared(predict);
    };

    // This is the transaction intended for profiling.
    test.next_tx(OWNER);
    {
        let mut predict = test.take_shared_by_id<Predict>(predict_id);
        let mut manager = test.take_shared_by_id<PredictManager>(manager_id);
        let oracle = test.take_shared_by_id<OracleSVI>(oracle_id);
        let clock = test.take_shared_by_id<Clock>(clock_id);
        let key = market_key::up(oracle_id, expiry_ms(), profiled_strike());
        assert!(profiled_strike() == SIM_PROFILED_STRIKE, ETestAssertion);

        predict::mint<ProfileQuote>(
            &mut predict,
            &mut manager,
            &oracle,
            key,
            PROFILE_QTY,
            &clock,
            test.ctx(),
        );

        let free = manager.position(key);
        assert!(free == PROFILE_QTY, ETestAssertion);

        return_shared(clock);
        return_shared(oracle);
        return_shared(manager);
        return_shared(predict);
    };

    end(test);
}

fun create_shared_clock(test: &mut Scenario): ID {
    let clock = clock::create_for_testing(test.ctx());
    let clock_id = object::id(&clock);
    clock::share_for_testing(clock);
    clock_id
}

fun create_shared_coin_registry(test: &mut Scenario): ID {
    let coin_registry = coin_registry::create_coin_data_registry_for_testing(test.ctx());
    let coin_registry_id = object::id(&coin_registry);
    coin_registry::share_for_testing(coin_registry);
    coin_registry_id
}

fun create_shared_quote_currency(test: &mut Scenario, coin_registry_id: ID) {
    let mut coin_registry = test.take_shared_by_id<CoinRegistry>(coin_registry_id);
    let (quote_initializer, quote_treasury_cap) = coin_registry::new_currency<ProfileQuote>(
        &mut coin_registry,
        QUOTE_DECIMALS,
        b"PGQ".to_string(),
        b"Predict Gas Quote".to_string(),
        b"Profile-only quote asset for predict gas harness".to_string(),
        b"".to_string(),
        test.ctx(),
    );
    let metadata_cap = coin_registry::finalize(quote_initializer, test.ctx());

    return_shared(coin_registry);
    transfer::public_transfer(metadata_cap, OWNER);
    transfer::public_transfer(quote_treasury_cap, OWNER);
}

fun fund_predict_and_manager(test: &mut Scenario, clock_id: ID, predict_id: ID, manager_id: ID) {
    let clock = test.take_shared_by_id<Clock>(clock_id);
    let mut predict = test.take_shared_by_id<Predict>(predict_id);
    let mut manager = test.take_shared_by_id<PredictManager>(manager_id);
    let mut treasury_cap = test.take_from_sender<TreasuryCap<ProfileQuote>>();

    let supply_coin = coin::mint(&mut treasury_cap, INITIAL_VAULT_LIQUIDITY, test.ctx());
    let manager_coin = coin::mint(&mut treasury_cap, INITIAL_MANAGER_BALANCE, test.ctx());
    let lp_coin = predict::supply<ProfileQuote>(&mut predict, supply_coin, &clock, test.ctx());
    manager.deposit(manager_coin, test.ctx());

    assert!(manager.balance<ProfileQuote>() == INITIAL_MANAGER_BALANCE, ETestAssertion);

    return_shared(clock);
    return_shared(manager);
    return_shared(predict);
    transfer::public_transfer(lp_coin, OWNER);
    transfer::public_transfer(treasury_cap, OWNER);
}

fun seed_live_ladder(
    test: &mut Scenario,
    clock_id: ID,
    predict_id: ID,
    manager_id: ID,
    oracle_id: ID,
) {
    test.next_tx(OWNER);
    {
        let mut predict = test.take_shared_by_id<Predict>(predict_id);
        let mut manager = test.take_shared_by_id<PredictManager>(manager_id);
        let oracle = test.take_shared_by_id<OracleSVI>(oracle_id);
        let clock = test.take_shared_by_id<Clock>(clock_id);
        let mut i = 0;
        while (i < LADDER_POINTS) {
            predict::mint<ProfileQuote>(
                &mut predict,
                &mut manager,
                &oracle,
                ladder_key(oracle_id, i),
                LADDER_QTY,
                &clock,
                test.ctx(),
            );
            i = i + 1;
        };

        return_shared(clock);
        return_shared(oracle);
        return_shared(manager);
        return_shared(predict);
    };
}

fun tick_size(): u64 {
    constants::float_scaling!()
}

fun ladder_step_ticks(): u64 {
    (LADDER_MAX_TICK_OFFSET - LADDER_MIN_TICK_OFFSET) / (LADDER_POINTS - 1)
}

fun ladder_strike(index: u64): u64 {
    min_strike() + (LADDER_MIN_TICK_OFFSET + index * ladder_step_ticks()) * tick_size()
}

fun ladder_key(oracle_id: ID, index: u64): market_key::MarketKey {
    let strike = ladder_strike(index);
    if (index == LADDER_POINTS - 1 || index % 2 == 1) {
        market_key::down(oracle_id, expiry_ms(), strike)
    } else {
        market_key::up(oracle_id, expiry_ms(), strike)
    }
}

fun min_strike(): u64 {
    STRIKE_MIN_DOLLARS * constants::float_scaling!()
}

fun profiled_strike(): u64 {
    SIM_PROFILED_STRIKE
}

fun expiry_ms(): u64 {
    2 * constants::ms_per_year!()
}

fun live_timestamp_ms(): u64 {
    1_000
}

fun live_prices(): oracle::PriceData {
    oracle::new_price_data(SIM_SPOT_PRICE, SIM_FORWARD_PRICE)
}

fun live_svi(): oracle::SVIParams {
    oracle::new_svi_params(
        SIM_SVI_A,
        SIM_SVI_B,
        i64::from_parts(SIM_SVI_RHO_MAGNITUDE, true),
        i64::from_parts(SIM_SVI_M_MAGNITUDE, false),
        SIM_SVI_SIGMA,
    )
}
