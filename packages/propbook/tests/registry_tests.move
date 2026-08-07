// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::registry_tests;

use propbook::{
    pyth_feed::{Self as pyth_feed, PythFeed},
    registry::{Self, OracleMetadata, OracleRegistry, RegistryAdminCap}
};
use std::{string::String, unit_test::{assert_eq, destroy}};
use sui::{event, test_scenario::{Self as test, Scenario, return_shared}};

const ADMIN: address = @0xAD;
const BTC_UNDERLYING_ID: u32 = 1;
const ETH_UNDERLYING_ID: u32 = 2;
const PYTH_SOURCE_A: u32 = 10;
const PYTH_SOURCE_B: u32 = 11;
const PYTH_SOURCE_UNKNOWN: u32 = 99;

#[test]
fun bind_pyth_to_underlying_records_typed_lookup_and_metadata() {
    let (scenario, pyth_a_id, _pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_a_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth, BTC_UNDERLYING_ID);

    assert_eq!(
        registry.propbook_pyth_id_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        pyth_a_id,
    );
    assert_metadata(
        registry.pyth_metadata_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        BTC_UNDERLYING_ID,
        PYTH_SOURCE_A,
        pyth_a_id,
    );
    assert!(registry.propbook_pyth_id_for_underlying(ETH_UNDERLYING_ID).is_none());

    return_shared(pyth);
    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun replace_pyth_binding_updates_typed_lookup_and_metadata() {
    let (scenario, pyth_a_id, pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a = scenario.take_shared_by_id<PythFeed>(pyth_a_id);
    let pyth_b = scenario.take_shared_by_id<PythFeed>(pyth_b_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, BTC_UNDERLYING_ID);
    registry.replace_pyth_binding_for_underlying(&admin_cap, &pyth_b, BTC_UNDERLYING_ID);

    assert_eq!(
        registry.propbook_pyth_id_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        pyth_b_id,
    );
    assert_metadata(
        registry.pyth_metadata_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        BTC_UNDERLYING_ID,
        PYTH_SOURCE_B,
        pyth_b_id,
    );

    return_shared(pyth_b);
    return_shared(pyth_a);
    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EInvalidOracleObject)]
fun bind_source_with_wrong_propbook_object_aborts() {
    let (mut scenario, _pyth_a_id, _pyth_b_id) = setup_registry_with_feeds();
    let rogue_pyth_id = pyth_feed::create_and_share(PYTH_SOURCE_A, scenario.ctx());
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let rogue_pyth = scenario.take_shared_by_id<PythFeed>(rogue_pyth_id);

    registry.bind_pyth_to_underlying(&admin_cap, &rogue_pyth, BTC_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::ESourceNotFound)]
fun bind_unregistered_source_aborts() {
    let (mut scenario, _pyth_a_id, _pyth_b_id) = setup_registry_with_feeds();
    let unregistered_pyth_id = pyth_feed::create_and_share(PYTH_SOURCE_UNKNOWN, scenario.ctx());
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let unregistered_pyth = scenario.take_shared_by_id<PythFeed>(unregistered_pyth_id);

    registry.bind_pyth_to_underlying(&admin_cap, &unregistered_pyth, BTC_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::EBindingNotFound)]
fun replace_pyth_binding_without_existing_binding_aborts() {
    let (scenario, pyth_a_id, _pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_a_id);

    registry.replace_pyth_binding_for_underlying(&admin_cap, &pyth, BTC_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyBound)]
fun replace_pyth_binding_to_source_bound_to_other_underlying_aborts() {
    let (scenario, pyth_a_id, pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a = scenario.take_shared_by_id<PythFeed>(pyth_a_id);
    let pyth_b = scenario.take_shared_by_id<PythFeed>(pyth_b_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth_b, ETH_UNDERLYING_ID);
    registry.replace_pyth_binding_for_underlying(&admin_cap, &pyth_b, BTC_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyBound)]
fun replaced_pyth_source_stays_bound_to_original_underlying() {
    let (scenario, pyth_a_id, pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a = scenario.take_shared_by_id<PythFeed>(pyth_a_id);
    let pyth_b = scenario.take_shared_by_id<PythFeed>(pyth_b_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, BTC_UNDERLYING_ID);
    registry.replace_pyth_binding_for_underlying(&admin_cap, &pyth_b, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, ETH_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyBound)]
fun same_source_cannot_bind_to_two_underlyings() {
    let (scenario, pyth_a_id, _pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_a_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth, ETH_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::EBindingAlreadyExists)]
fun rebinding_bound_underlying_aborts() {
    let (scenario, pyth_a_id, pyth_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a = scenario.take_shared_by_id<PythFeed>(pyth_a_id);
    let pyth_b = scenario.take_shared_by_id<PythFeed>(pyth_b_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth_b, BTC_UNDERLYING_ID);

    abort 999
}

fun setup_registry_with_feeds(): (Scenario, ID, ID) {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a_id = registry::create_and_share_pyth_feed(
        &mut registry,
        PYTH_SOURCE_A,
        scenario.ctx(),
    );
    let pyth_b_id = registry::create_and_share_pyth_feed(
        &mut registry,
        PYTH_SOURCE_B,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, pyth_a_id, pyth_b_id)
}

fun assert_metadata(
    metadata: OracleMetadata,
    expected_underlying_id: u32,
    expected_source_id: u32,
    expected_oracle_id: ID,
) {
    assert_eq!(registry::propbook_underlying_id(&metadata), expected_underlying_id);
    assert_eq!(registry::source_id(&metadata), expected_source_id);
    assert_eq!(registry::propbook_oracle_id(&metadata), expected_oracle_id);
}

// === Block Scholes stores ===

#[test]
fun create_block_scholes_stores_records_the_pair_lookup() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let created_pair = registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        btc(),
        scenario.ctx(),
    );
    let value_store_id = created_pair.block_scholes_value_store_id();
    let svi_store_id = created_pair.block_scholes_svi_store_id();

    let pair = registry
        .propbook_block_scholes_store_pair_for_underlying(BTC_UNDERLYING_ID)
        .destroy_some();
    assert_eq!(pair.block_scholes_value_store_id(), value_store_id);
    assert_eq!(pair.block_scholes_svi_store_id(), svi_store_id);
    assert_eq!(pair.block_scholes_base_asset(), btc());
    assert!(value_store_id != svi_store_id);

    let events = event::events_by_type<registry::BlockScholesStoresRegistered>();
    assert_eq!(events.length(), 1);
    let (
        event_underlying_id,
        event_value_id,
        event_svi_id,
        event_base_asset,
    ) = registry::stores_registered_fields(&events[0]);
    assert_eq!(event_underlying_id, BTC_UNDERLYING_ID);
    assert_eq!(event_value_id, value_store_id);
    assert_eq!(event_svi_id, svi_store_id);
    assert_eq!(event_base_asset, btc());

    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

/// The binding is what lets a consumer reject a store it was not meant to price from, so an
/// underlying with no pair resolves to nothing rather than to some default.
#[test]
fun store_lookups_are_none_for_an_underlying_without_a_pair() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        btc(),
        scenario.ctx(),
    );

    assert!(registry.propbook_block_scholes_store_pair_for_underlying(ETH_UNDERLYING_ID).is_none());

    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

/// One canonical storage pair per underlying for life: observations advance it in place, and any
/// future structural recovery belongs to the package upgrade that defines the migration.
#[test, expected_failure(abort_code = registry::EBlockScholesStoresAlreadyExist)]
fun creating_a_second_store_pair_for_an_underlying_aborts() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        btc(),
        scenario.ctx(),
    );
    registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        btc(),
        scenario.ctx(),
    );

    abort
}

/// Underlyings are independent: a pair for one neither blocks nor leaks into another.
#[test]
fun each_underlying_gets_its_own_store_pair() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let btc_created_pair = registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        btc(),
        scenario.ctx(),
    );
    let eth_created_pair = registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        ETH_UNDERLYING_ID,
        eth(),
        scenario.ctx(),
    );
    let btc_value_id = btc_created_pair.block_scholes_value_store_id();
    let eth_value_id = eth_created_pair.block_scholes_value_store_id();

    assert!(btc_value_id != eth_value_id);
    let btc_pair = registry
        .propbook_block_scholes_store_pair_for_underlying(BTC_UNDERLYING_ID)
        .destroy_some();
    let eth_pair = registry
        .propbook_block_scholes_store_pair_for_underlying(ETH_UNDERLYING_ID)
        .destroy_some();
    assert_eq!(btc_pair.block_scholes_value_store_id(), btc_value_id);
    assert_eq!(eth_pair.block_scholes_value_store_id(), eth_value_id);

    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EInvalidBlockScholesBaseAsset)]
fun creating_store_pair_with_empty_base_asset_aborts() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        b"".to_string(),
        scenario.ctx(),
    );

    abort 999
}

/// 32 bytes is the longest accepted spelling; the boundary lands on the accepting side.
#[test]
fun creating_store_pair_with_a_maximum_length_base_asset_succeeds() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let pair = registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        thirty_two_byte_asset(),
        scenario.ctx(),
    );
    assert_eq!(pair.block_scholes_base_asset(), thirty_two_byte_asset());

    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EInvalidBlockScholesBaseAsset)]
fun creating_store_pair_with_an_over_length_base_asset_aborts() {
    let mut scenario = test::begin(ADMIN);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let mut registry = scenario.take_shared<OracleRegistry>();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut over_length = thirty_two_byte_asset();
    over_length.append(b"X".to_string());
    registry::create_and_share_block_scholes_stores(
        &mut registry,
        &admin_cap,
        BTC_UNDERLYING_ID,
        over_length,
        scenario.ctx(),
    );

    abort 999
}

fun btc(): String {
    b"BTC".to_string()
}

/// Exactly 32 ASCII bytes, counted by hand: eight groups of four.
fun thirty_two_byte_asset(): String {
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345".to_string()
}

fun eth(): String {
    b"ETH".to_string()
}
