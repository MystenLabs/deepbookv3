// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_tests;

use deepbook_predict::{
    constants::oracle_strike_grid_ticks,
    oracle::{Self, OracleSVI},
    plp::PLP,
    predict::Predict,
    registry::{Self, AdminCap, Registry}
};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, sui::SUI, test_scenario::{Self, Scenario}};

const ADMIN: address = @0xAD;
const TEST_MIN_STRIKE: u64 = 1_000_000_000;
const TEST_TICK_SIZE: u64 = 1_000_000_000;

// Setup: init registry, return scenario with AdminCap transferred to ADMIN.
fun setup(): Scenario {
    let mut scenario = test_scenario::begin(ADMIN);
    {
        registry::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    scenario
}

// ============================================================
// Init
// ============================================================

#[test]
fun init_creates_registry_and_admin_cap() {
    let scenario = setup();

    // AdminCap transferred to ADMIN
    let admin_cap = scenario.take_from_sender<AdminCap>();

    // Registry is shared and has no oracle IDs for any cap
    let registry = scenario.take_shared<Registry>();
    let cap_id = object::id(&admin_cap);
    assert_eq!(registry.oracle_ids(cap_id).length(), 0);

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);

    scenario.end();
}

#[test]
fun init_registry_has_no_predict_id() {
    let scenario = setup();

    let registry = scenario.take_shared<Registry>();
    assert!(registry.predict_id().is_none());
    test_scenario::return_shared(registry);

    scenario.end();
}

#[test]
fun init_registry_has_no_oracle_ids() {
    let scenario = setup();

    let registry = scenario.take_shared<Registry>();
    let fake_id = object::id_from_address(@0x1);
    assert_eq!(registry.oracle_ids(fake_id).length(), 0);
    test_scenario::return_shared(registry);

    scenario.end();
}

// ============================================================
// create_predict
// ============================================================

#[test]
fun create_predict_succeeds() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    let predict_id = registry.create_predict<SUI>(&admin_cap, treasury_cap, scenario.ctx());
    // Returned ID matches the one stored in registry
    assert_eq!(registry.predict_id(), option::some(predict_id));

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EPredictAlreadyCreated)]
fun create_predict_twice_aborts() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let tc1 = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc1, scenario.ctx());
    // Second call should abort
    let tc2 = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc2, scenario.ctx());

    abort
}

// ============================================================
// create_oracle_cap
// ============================================================

#[test]
fun create_oracle_cap_succeeds() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    destroy(cap);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

// ============================================================
// create_oracle
// ============================================================

#[test]
fun create_oracle_and_tracks_in_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap_id = object::id(&cap);

    let oracle_id = registry.create_oracle(
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    // Registry tracks the oracle under this cap
    let ids = registry.oracle_ids(cap_id);
    assert_eq!(ids.length(), 1);
    assert_eq!(ids[0], oracle_id);

    destroy(cap);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun create_oracle_persists_grid_on_oracle() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    registry.create_oracle(
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    scenario.next_tx(ADMIN);
    {
        let oracle = scenario.take_shared<OracleSVI>();
        assert_eq!(oracle::min_strike(&oracle), TEST_MIN_STRIKE);
        assert_eq!(
            oracle::max_strike(&oracle),
            TEST_MIN_STRIKE + oracle_strike_grid_ticks!() * TEST_TICK_SIZE,
        );
        assert_eq!(oracle::tick_size(&oracle), TEST_TICK_SIZE);
        test_scenario::return_shared(oracle);
    };

    destroy(cap);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = oracle::EInvalidTickSize)]
fun create_oracle_invalid_tick_size_aborts() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    registry.create_oracle(
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        1,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = oracle::EInvalidStrikeGrid)]
fun create_oracle_zero_min_strike_aborts() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    registry.create_oracle(
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        0,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    abort
}

#[test]
fun create_multiple_oracles_same_cap() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap_id = object::id(&cap);

    let id1 = registry.create_oracle(
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );
    let id2 = registry.create_oracle(
        &admin_cap,
        &cap,
        b"ETH".to_string(),
        2_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    let ids = registry.oracle_ids(cap_id);
    assert_eq!(ids.length(), 2);
    assert_eq!(ids[0], id1);
    assert_eq!(ids[1], id2);

    destroy(cap);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun create_oracles_different_caps_tracked_separately() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let cap1 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap2 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap1_id = object::id(&cap1);
    let cap2_id = object::id(&cap2);

    let id1 = registry.create_oracle(
        &admin_cap,
        &cap1,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );
    let id2 = registry.create_oracle(
        &admin_cap,
        &cap2,
        b"ETH".to_string(),
        2_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    let ids1 = registry.oracle_ids(cap1_id);
    assert_eq!(ids1.length(), 1);
    assert_eq!(ids1[0], id1);

    let ids2 = registry.oracle_ids(cap2_id);
    assert_eq!(ids2.length(), 1);
    assert_eq!(ids2[0], id2);

    destroy(cap1);
    destroy(cap2);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

// ============================================================
// register_oracle_cap (authorize additional cap on oracle)
// ============================================================

#[test]
fun register_oracle_cap_on_oracle() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let cap1 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    registry.create_oracle(
        &admin_cap,
        &cap1,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    // Create a second cap and register it on the oracle
    let cap2 = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut oracle = scenario.take_shared<OracleSVI>();
        registry::register_oracle_cap(&mut oracle, &admin_cap, &cap2);
        test_scenario::return_shared(oracle);
    };

    destroy(cap1);
    destroy(cap2);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

// ============================================================
// Config setters via registry (admin-gated)
// ============================================================

#[test]
fun set_trading_paused_via_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let tc = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared<Predict<SUI>>();
        registry::set_trading_paused(&mut predict, &admin_cap, true);
        assert_eq!(predict.trading_paused(), true);
        registry::set_trading_paused(&mut predict, &admin_cap, false);
        assert_eq!(predict.trading_paused(), false);
        test_scenario::return_shared(predict);
    };

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_base_spread_via_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let tc = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared<Predict<SUI>>();
        registry::set_base_spread(&mut predict, &admin_cap, 100_000_000);
        assert_eq!(predict.base_spread(), 100_000_000);
        test_scenario::return_shared(predict);
    };

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_min_spread_via_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let tc = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared<Predict<SUI>>();
        registry::set_min_spread(&mut predict, &admin_cap, 10_000_000);
        assert_eq!(predict.min_spread(), 10_000_000);
        test_scenario::return_shared(predict);
    };

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_utilization_multiplier_via_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let tc = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared<Predict<SUI>>();
        registry::set_utilization_multiplier(&mut predict, &admin_cap, 3_000_000_000);
        assert_eq!(predict.utilization_multiplier(), 3_000_000_000);
        test_scenario::return_shared(predict);
    };

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_max_total_exposure_pct_via_registry() {
    let mut scenario = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();

    let tc = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<SUI>(&admin_cap, tc, scenario.ctx());

    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared<Predict<SUI>>();
        registry::set_max_total_exposure_pct(&mut predict, &admin_cap, 500_000_000);
        assert_eq!(predict.max_total_exposure_pct(), 500_000_000);
        test_scenario::return_shared(predict);
    };

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}
