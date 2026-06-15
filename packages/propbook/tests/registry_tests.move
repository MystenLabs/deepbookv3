// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module propbook::registry_tests;

use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::{Self as pyth_feed, PythFeed},
    registry::{Self, OracleMetadata, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ADMIN: address = @0xAD;
const BTC_UNDERLYING_ID: u32 = 1;
const ETH_UNDERLYING_ID: u32 = 2;
const PYTH_SOURCE_A: u32 = 10;
const PYTH_SOURCE_B: u32 = 11;
const PYTH_SOURCE_UNKNOWN: u32 = 99;
const BS_SOURCE_A: u32 = 20;
const BS_SOURCE_B: u32 = 21;

#[test]
fun bind_pyth_to_underlying_records_typed_lookup_and_metadata() {
    let (scenario, pyth_a_id, _pyth_b_id, _bs_a_id, _bs_b_id) = setup_registry_with_feeds();
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
fun bind_block_scholes_to_underlying_records_typed_lookup_and_metadata() {
    let (scenario, _pyth_a_id, _pyth_b_id, bs_a_id, _bs_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_a_id);

    registry.bind_block_scholes_to_underlying(&admin_cap, &bs, BTC_UNDERLYING_ID);

    assert_eq!(
        registry.propbook_block_scholes_id_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        bs_a_id,
    );
    assert_metadata(
        registry.block_scholes_metadata_for_underlying(BTC_UNDERLYING_ID).destroy_some(),
        BTC_UNDERLYING_ID,
        BS_SOURCE_A,
        bs_a_id,
    );
    assert!(registry.propbook_block_scholes_id_for_underlying(ETH_UNDERLYING_ID).is_none());

    return_shared(bs);
    return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EInvalidOracleObject)]
fun bind_source_with_wrong_propbook_object_aborts() {
    let (mut scenario, _pyth_a_id, _pyth_b_id, _bs_a_id, _bs_b_id) = setup_registry_with_feeds();
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
    let (mut scenario, _pyth_a_id, _pyth_b_id, _bs_a_id, _bs_b_id) = setup_registry_with_feeds();
    let unregistered_pyth_id = pyth_feed::create_and_share(PYTH_SOURCE_UNKNOWN, scenario.ctx());
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let unregistered_pyth = scenario.take_shared_by_id<PythFeed>(unregistered_pyth_id);

    registry.bind_pyth_to_underlying(&admin_cap, &unregistered_pyth, BTC_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::ESourceAlreadyBound)]
fun same_source_cannot_bind_to_two_underlyings() {
    let (scenario, pyth_a_id, _pyth_b_id, _bs_a_id, _bs_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_a_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth, ETH_UNDERLYING_ID);

    abort 999
}

#[test, expected_failure(abort_code = registry::EBindingAlreadyExists)]
fun rebinding_bound_underlying_aborts() {
    let (scenario, pyth_a_id, pyth_b_id, _bs_a_id, _bs_b_id) = setup_registry_with_feeds();
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut registry = scenario.take_shared<OracleRegistry>();
    let pyth_a = scenario.take_shared_by_id<PythFeed>(pyth_a_id);
    let pyth_b = scenario.take_shared_by_id<PythFeed>(pyth_b_id);

    registry.bind_pyth_to_underlying(&admin_cap, &pyth_a, BTC_UNDERLYING_ID);
    registry.bind_pyth_to_underlying(&admin_cap, &pyth_b, BTC_UNDERLYING_ID);

    abort 999
}

fun setup_registry_with_feeds(): (Scenario, ID, ID, ID, ID) {
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
    let bs_a_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        BS_SOURCE_A,
        scenario.ctx(),
    );
    let bs_b_id = registry::create_and_share_block_scholes_feed(
        &mut registry,
        BS_SOURCE_B,
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, pyth_a_id, pyth_b_id, bs_a_id, bs_b_id)
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
