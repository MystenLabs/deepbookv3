// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for Predict registry setup, oracle creation, and admin controls.
#[test_only]
module deepbook_predict::registry_tests;

use deepbook_predict::{
    constants::{Self, oracle_strike_grid_ticks},
    currency_helper,
    oracle::OracleSVI,
    oracle_config,
    plp::PLP,
    predict::{Self as predict, Predict},
    registry::{Self, AdminCap, Registry},
    treasury_config
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{
    coin::{Self, TreasuryCap},
    coin_registry::{Self as coin_registry, Currency, MetadataCap},
    test_scenario::{Self, Scenario}
};

const ADMIN: address = @0xAD;
const TEST_MIN_STRIKE: u64 = 1_000_000_000;
const TEST_TICK_SIZE: u64 = 1_000_000_000;
const BAD_DECIMALS: u8 = 9;

public struct QUOTEUSD has key { id: UID }
public struct ALTUSD has key { id: UID }
public struct BADDEC has key { id: UID }

fun new_quoteusd_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<QUOTEUSD>, TreasuryCap<QUOTEUSD>, MetadataCap<QUOTEUSD>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<QUOTEUSD>(
        decimals,
        b"QUSD".to_string(),
        b"Quote USD".to_string(),
        b"Quote USD".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

fun new_altusd_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<ALTUSD>, TreasuryCap<ALTUSD>, MetadataCap<ALTUSD>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<ALTUSD>(
        decimals,
        b"AUSD".to_string(),
        b"Alt USD".to_string(),
        b"Alt USD".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

fun new_baddec_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<BADDEC>, TreasuryCap<BADDEC>, MetadataCap<BADDEC>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<BADDEC>(
        decimals,
        b"BDEC".to_string(),
        b"Bad Decimals".to_string(),
        b"Bad Decimals".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

// Setup: init registry, return scenario with AdminCap transferred to ADMIN.
fun setup(): (Scenario, ID) {
    let mut scenario = test_scenario::begin(ADMIN);
    let registry_id;
    {
        registry_id = registry::init_for_testing(scenario.ctx());
    };
    scenario.next_tx(ADMIN);
    (scenario, registry_id)
}

fun create_shared_predict(
    scenario: &mut Scenario,
    registry: &mut Registry,
    admin_cap: &AdminCap,
): ID {
    let currency_ctx = &mut tx_context::dummy();
    let (currency, quote_treasury_cap, metadata_cap) = new_quoteusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    let plp_treasury_cap = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    let predict_id = registry.create_predict<QUOTEUSD>(
        admin_cap,
        &currency,
        plp_treasury_cap,
        scenario.ctx(),
    );
    currency_helper::destroy_currency_bundle(currency, quote_treasury_cap, metadata_cap);
    predict_id
}

fun setup_with_predict(): (Scenario, ID, ID, AdminCap) {
    let (mut scenario, registry_id) = setup();
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let predict_id = create_shared_predict(&mut scenario, &mut registry, &admin_cap);
    test_scenario::return_shared(registry);
    (scenario, registry_id, predict_id, admin_cap)
}

// ============================================================
// Init
// ============================================================

#[test]
fun init_creates_registry_and_admin_cap() {
    let (scenario, registry_id) = setup();

    // AdminCap transferred to ADMIN
    let admin_cap = scenario.take_from_sender<AdminCap>();

    // Registry is shared and has no oracle IDs for any cap
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let cap_id = object::id(&admin_cap);
    assert_eq!(registry.oracle_ids(cap_id).length(), 0);

    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);

    scenario.end();
}

#[test]
fun init_registry_has_no_predict_id() {
    let (scenario, registry_id) = setup();

    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    assert!(registry.predict_id().is_none());
    test_scenario::return_shared(registry);

    scenario.end();
}

#[test]
fun init_registry_has_no_oracle_ids() {
    let (scenario, registry_id) = setup();

    let registry = scenario.take_shared_by_id<Registry>(registry_id);
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
    let (mut scenario, registry_id) = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);

    let currency_ctx = &mut tx_context::dummy();
    let (currency, quote_treasury_cap, metadata_cap) = new_quoteusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    let plp_treasury_cap = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    let predict_id = registry.create_predict<QUOTEUSD>(
        &admin_cap,
        &currency,
        plp_treasury_cap,
        scenario.ctx(),
    );
    // Returned ID matches the one stored in registry
    assert_eq!(registry.predict_id(), option::some(predict_id));
    currency_helper::destroy_currency_bundle(currency, quote_treasury_cap, metadata_cap);

    test_scenario::return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EPredictAlreadyCreated)]
fun create_predict_twice_aborts() {
    let (mut scenario, registry_id) = setup();

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let currency_ctx = &mut tx_context::dummy();
    let (currency, quote_treasury_cap, metadata_cap) = new_quoteusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    let tc1 = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<QUOTEUSD>(&admin_cap, &currency, tc1, scenario.ctx());
    // Second call should abort
    let tc2 = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    registry.create_predict<QUOTEUSD>(&admin_cap, &currency, tc2, scenario.ctx());

    currency_helper::destroy_currency_bundle(currency, quote_treasury_cap, metadata_cap);

    abort 999
}

// ============================================================
// create_oracle_cap
// ============================================================

#[test]
fun create_oracle_cap_succeeds() {
    let (mut scenario, _registry_id) = setup();

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
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap_id = object::id(&cap);

    let oracle_id = registry.create_oracle(
        &mut predict,
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
    test_scenario::return_shared(predict);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun create_oracle_persists_grid_on_predict_runtime() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let oracle_id = registry.create_oracle(
        &mut predict,
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    test_scenario::return_shared(predict);
    test_scenario::return_shared(registry);
    scenario.next_tx(ADMIN);

    {
        let predict = scenario.take_shared_by_id<Predict>(predict_id);
        let oracle = scenario.take_shared_by_id<OracleSVI>(oracle_id);
        let oracle_config_ref = predict::oracle_config(&predict);
        let max_strike = TEST_MIN_STRIKE + oracle_strike_grid_ticks!() * TEST_TICK_SIZE;

        oracle_config::assert_valid_strike(
            oracle_config_ref,
            &oracle,
            TEST_MIN_STRIKE,
        );
        oracle_config::assert_valid_strike(
            oracle_config_ref,
            &oracle,
            max_strike,
        );

        test_scenario::return_shared(predict);
        test_scenario::return_shared(oracle);
    };

    destroy(cap);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EInvalidTickSize)]
fun create_oracle_invalid_tick_size_aborts() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    registry.create_oracle(
        &mut predict,
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        1,
        scenario.ctx(),
    );

    abort 999
}

#[test, expected_failure(abort_code = registry::EInvalidStrikeGrid)]
fun create_oracle_zero_min_strike_aborts() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());

    registry.create_oracle(
        &mut predict,
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        0,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );

    abort 999
}

#[test]
fun create_multiple_oracles_same_cap() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);

    let cap = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap_id = object::id(&cap);

    let id1 = registry.create_oracle(
        &mut predict,
        &admin_cap,
        &cap,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );
    let id2 = registry.create_oracle(
        &mut predict,
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
    test_scenario::return_shared(predict);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun create_oracles_different_caps_tracked_separately() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);

    let cap1 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap2 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let cap1_id = object::id(&cap1);
    let cap2_id = object::id(&cap2);

    let id1 = registry.create_oracle(
        &mut predict,
        &admin_cap,
        &cap1,
        b"BTC".to_string(),
        1_000_000,
        TEST_MIN_STRIKE,
        TEST_TICK_SIZE,
        scenario.ctx(),
    );
    let id2 = registry.create_oracle(
        &mut predict,
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
    test_scenario::return_shared(predict);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

// ============================================================
// register_oracle_cap (authorize additional cap on oracle)
// ============================================================

#[test]
fun register_oracle_cap_on_oracle() {
    let (mut scenario, registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let mut predict = scenario.take_shared_by_id<Predict>(predict_id);

    let cap1 = registry::create_oracle_cap(&admin_cap, scenario.ctx());
    let oracle_id = registry.create_oracle(
        &mut predict,
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

    test_scenario::return_shared(predict);
    test_scenario::return_shared(registry);
    scenario.next_tx(ADMIN);
    {
        let mut oracle = scenario.take_shared_by_id<OracleSVI>(oracle_id);
        registry::register_oracle_cap(&mut oracle, &admin_cap, &cap2);
        test_scenario::return_shared(oracle);
    };

    destroy(cap1);
    destroy(cap2);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

// ============================================================
// Config setters via registry (admin-gated)
// ============================================================

#[test]
fun set_trading_paused_via_registry() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::set_trading_paused(&mut predict, &admin_cap, true);
        assert_eq!(predict.trading_paused(), true);
        registry::set_trading_paused(&mut predict, &admin_cap, false);
        assert_eq!(predict.trading_paused(), false);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun add_quote_asset_via_registry_updates_predict_whitelist() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    let currency_ctx = &mut tx_context::dummy();
    let (alt_currency, alt_treasury_cap, alt_metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        assert!(treasury_config::is_quote_asset<QUOTEUSD>(predict::treasury_config(&predict)));
        assert!(!treasury_config::is_quote_asset<ALTUSD>(predict::treasury_config(&predict)));

        registry::add_quote_asset<ALTUSD>(&mut predict, &admin_cap, &alt_currency);

        assert!(treasury_config::is_quote_asset<ALTUSD>(predict::treasury_config(&predict)));
        let accepted_quotes = predict::accepted_quotes(&predict);
        assert_eq!(accepted_quotes.length(), 2);
        assert!(accepted_quotes.contains(&type_name::with_defining_ids<QUOTEUSD>()));
        assert!(accepted_quotes.contains(&type_name::with_defining_ids<ALTUSD>()));
        test_scenario::return_shared(predict);
    };
    let effects = scenario.next_tx(ADMIN);
    assert_eq!(test_scenario::num_user_events(&effects), 1);

    currency_helper::destroy_currency_bundle(alt_currency, alt_treasury_cap, alt_metadata_cap);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun remove_quote_asset_via_registry_updates_predict_whitelist() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    let currency_ctx = &mut tx_context::dummy();
    let (alt_currency, alt_treasury_cap, alt_metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::add_quote_asset<ALTUSD>(&mut predict, &admin_cap, &alt_currency);
        registry::remove_quote_asset<ALTUSD>(&mut predict, &admin_cap);

        assert!(!treasury_config::is_quote_asset<ALTUSD>(predict::treasury_config(&predict)));
        assert!(treasury_config::is_quote_asset<QUOTEUSD>(predict::treasury_config(&predict)));
        test_scenario::return_shared(predict);
    };
    let effects = scenario.next_tx(ADMIN);
    assert_eq!(test_scenario::num_user_events(&effects), 2);

    currency_helper::destroy_currency_bundle(alt_currency, alt_treasury_cap, alt_metadata_cap);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = predict::EQuoteAssetHasVaultBalance)]
fun remove_quote_asset_with_vault_balance_aborts() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    let currency_ctx = &mut tx_context::dummy();
    let (alt_currency, alt_treasury_cap, alt_metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        currency_ctx,
    );
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::add_quote_asset<ALTUSD>(&mut predict, &admin_cap, &alt_currency);

        let payment = coin::mint_for_testing<ALTUSD>(1_000_000, scenario.ctx());
        let lp = predict::supply<ALTUSD>(&mut predict, payment, scenario.ctx());
        destroy(lp);

        registry::remove_quote_asset<ALTUSD>(&mut predict, &admin_cap);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
    currency_helper::destroy_currency_bundle(alt_currency, alt_treasury_cap, alt_metadata_cap);
    abort 999
}

#[test, expected_failure(abort_code = treasury_config::EInvalidQuoteDecimals)]
fun add_quote_asset_with_wrong_decimals_aborts() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    let currency_ctx = &mut tx_context::dummy();
    let (bad_currency, bad_treasury_cap, bad_metadata_cap) = new_baddec_currency(
        BAD_DECIMALS,
        currency_ctx,
    );
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::add_quote_asset<BADDEC>(&mut predict, &admin_cap, &bad_currency);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
    destroy(bad_currency);
    destroy(bad_treasury_cap);
    destroy(bad_metadata_cap);
    abort 999
}

#[test]
fun set_base_spread_via_registry() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::set_base_spread(&mut predict, &admin_cap, 100_000_000);
        assert_eq!(predict.base_spread(), 100_000_000);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_min_spread_via_registry() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::set_min_spread(&mut predict, &admin_cap, 10_000_000);
        assert_eq!(predict.min_spread(), 10_000_000);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_utilization_multiplier_via_registry() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::set_utilization_multiplier(&mut predict, &admin_cap, 3_000_000_000);
        assert_eq!(predict.utilization_multiplier(), 3_000_000_000);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun set_max_total_exposure_pct_via_registry() {
    let (mut scenario, _registry_id, predict_id, admin_cap) = setup_with_predict();
    scenario.next_tx(ADMIN);
    {
        let mut predict = scenario.take_shared_by_id<Predict>(predict_id);
        registry::set_max_total_exposure_pct(&mut predict, &admin_cap, 500_000_000);
        assert_eq!(predict.max_total_exposure_pct(), 500_000_000);
        test_scenario::return_shared(predict);
    };

    scenario.return_to_sender(admin_cap);
    scenario.end();
}
