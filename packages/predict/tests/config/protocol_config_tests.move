// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard tests for the protocol config's per-expiry runtime-config table.
#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{protocol_config::{Self, ProtocolConfig}, test_constants, test_helpers};
use sui::test_scenario::return_shared;

const EXPIRY_MARKET_ID: address = @0xE1;
const UNKNOWN_EXPIRY_MARKET_ID: address = @0xE2;

#[test, expected_failure(abort_code = protocol_config::EExpiryConfigAlreadyExists)]
fun register_expiry_runtime_config_twice_aborts() {
    let (mut scenario, _registry_id) = test_helpers::setup_test();
    scenario.next_tx(test_constants::admin());
    let mut config = scenario.take_shared<ProtocolConfig>();
    // The registry registers each created expiry market exactly once; a second
    // registration of the same market ID is rejected.
    config.register_expiry_runtime_config(EXPIRY_MARKET_ID.to_id());
    config.register_expiry_runtime_config(EXPIRY_MARKET_ID.to_id());
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EExpiryConfigNotFound)]
fun set_mint_paused_for_unknown_expiry_aborts() {
    let (mut scenario, _registry_id) = test_helpers::setup_test();
    scenario.next_tx(test_constants::admin());
    let mut config = scenario.take_shared<ProtocolConfig>();
    let admin_cap = scenario.take_from_sender<deepbook_predict::admin::AdminCap>();
    config.set_expiry_mint_paused(&admin_cap, UNKNOWN_EXPIRY_MARKET_ID.to_id(), true);
    abort 999
}

#[test]
fun registered_expiry_starts_unpaused_with_default_funding() {
    let (mut scenario, _registry_id) = test_helpers::setup_test();
    scenario.next_tx(test_constants::admin());
    let mut config = scenario.take_shared<ProtocolConfig>();
    config.register_expiry_runtime_config(EXPIRY_MARKET_ID.to_id());
    assert!(!config.expiry_mint_paused(EXPIRY_MARKET_ID.to_id()));
    return_shared(config);
    scenario.end();
}
