// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `protocol_config::set_oracle_binding` and the binding checks: the admin-set
/// record of which signed data prices, settles, and values an underlying's
/// markets, its bounds, its event, and the series ids `block_scholes` derives,
/// which must equal the ones Propbook's stores accepted.
#[test_only]
module deepbook_predict::oracle_binding_tests;

use deepbook_predict::{
    config_events::OracleBindingUpdated,
    oracle_fixture,
    protocol_config::{Self, ProtocolConfig},
    test_constants,
    test_helpers
};
use deepbook_predict_math::block_scholes;
use std::{string::String, unit_test::{assert_eq, destroy}};
use sui::{bcs, clock, event, test_scenario::{Scenario, return_shared}};

const UNDERLYING_ID: u32 = 7;
const FEED_ID: u32 = 31;
const CHANNEL_50MS: u8 = 2;
const CHANNEL_200MS: u8 = 3;
const REAL_TIME_CHANNEL: u8 = 1;
const NINE: u8 = 9;
const EIGHTEEN: u8 = 18;
const TWELVE: u8 = 12;
const NOW_MS: u64 = 120_000;
const LONGEST_NAME_BYTES: u64 = 32;

fun set(
    config: &mut ProtocolConfig,
    admin_cap: &deepbook_predict::admin::AdminCap,
    scenario: &mut Scenario,
    channel: u8,
    base: String,
    model: String,
    decimals: u8,
) {
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    config.set_oracle_binding(
        admin_cap,
        UNDERLYING_ID,
        FEED_ID,
        channel,
        base,
        model,
        decimals,
        &clock,
    );
    clock.destroy_for_testing();
}

fun name_of(length: u64): String {
    let mut bytes = vector[];
    length.do!(|_| bytes.push_back(65));
    bytes.to_string()
}

/// BCS mirror of `OracleBindingUpdated`.
public struct ExpectedBindingUpdated has copy, drop {
    propbook_underlying_id: u32,
    lazer_feed_id: u32,
    lazer_channel: u8,
    block_scholes_base_asset: String,
    svi_model: String,
    svi_decimals: u8,
    onchain_timestamp_ms: u64,
}

#[test]
fun an_unset_underlying_has_no_binding() {
    let (scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();
    assert!(config.oracle_binding(UNDERLYING_ID).is_none());
    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test]
fun set_oracle_binding_stores_replaces_and_emits_the_whole_binding() {
    let (mut scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"BTC".to_string(),
        b"SVI".to_string(),
        NINE,
    );
    assert!(config.oracle_binding(UNDERLYING_ID).is_some());
    // Replacing keeps one binding: the second write wins.
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_50MS,
        b"ETH".to_string(),
        b"SVI_REGIME".to_string(),
        EIGHTEEN,
    );
    let binding = config.oracle_binding(UNDERLYING_ID).destroy_some();
    let emitted = event::events_by_type<OracleBindingUpdated>();
    assert_eq!(emitted.length(), 2);
    assert_eq!(
        bcs::to_bytes(&emitted[1]),
        bcs::to_bytes(
            &ExpectedBindingUpdated {
                propbook_underlying_id: UNDERLYING_ID,
                lazer_feed_id: FEED_ID,
                lazer_channel: CHANNEL_50MS,
                block_scholes_base_asset: b"ETH".to_string(),
                svi_model: b"SVI_REGIME".to_string(),
                svi_decimals: EIGHTEEN,
                onchain_timestamp_ms: NOW_MS,
            },
        ),
    );
    // The stored binding serializes as the event's fields between its id and its time.
    let (feed, channel, decimals) = (FEED_ID, CHANNEL_50MS, EIGHTEEN);
    let mut expected = bcs::to_bytes(&feed);
    expected.append(bcs::to_bytes(&channel));
    expected.append(bcs::to_bytes(&b"ETH".to_string()));
    expected.append(bcs::to_bytes(&b"SVI_REGIME".to_string()));
    expected.append(bcs::to_bytes(&decimals));
    assert_eq!(bcs::to_bytes(&binding), expected);
    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test]
fun names_of_exactly_32_bytes_are_accepted() {
    let (mut scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        name_of(LONGEST_NAME_BYTES),
        name_of(LONGEST_NAME_BYTES),
        NINE,
    );
    assert!(config.oracle_binding(UNDERLYING_ID).is_some());
    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun a_real_time_channel_is_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        REAL_TIME_CHANNEL,
        b"BTC".to_string(),
        b"SVI".to_string(),
        NINE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun decimals_other_than_9_or_18_are_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"BTC".to_string(),
        b"SVI".to_string(),
        TWELVE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun an_empty_base_asset_is_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"".to_string(),
        b"SVI".to_string(),
        NINE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun an_empty_model_is_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"BTC".to_string(),
        b"".to_string(),
        NINE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun a_base_asset_past_32_bytes_is_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        name_of(LONGEST_NAME_BYTES + 1),
        b"SVI".to_string(),
        NINE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EInvalidOracleBinding)]
fun a_model_past_32_bytes_is_refused() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"BTC".to_string(),
        name_of(LONGEST_NAME_BYTES + 1),
        NINE,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun the_setter_refuses_while_frozen() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.set_frozen(&admin_cap, true);
    set(
        &mut config,
        &admin_cap,
        &mut scenario,
        CHANNEL_200MS,
        b"BTC".to_string(),
        b"SVI".to_string(),
        NINE,
    );
    abort 999
}

/// The series ids `block_scholes` derives are the ones Propbook's stores accepted, so the
/// keeper's batches decode the same way after the move.
#[test]
fun block_scholes_series_ids_equal_propbooks() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let bs = oracle_fixture::bs(&oracle);
    let base = test_constants::block_scholes_base_asset();
    let expiry = fx.expiry();
    assert_eq!(block_scholes::spot_sid(&base), bs.values().spot_sid());
    assert_eq!(block_scholes::forward_sid(&base, expiry), bs.values().forward_sid(expiry));
    assert_eq!(
        block_scholes::svi_sid(&base, &bs.svi().svi_model(), bs.svi().svi_decimals(), expiry),
        bs.svi().svi_sid(expiry),
    );
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
