// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `ProtocolConfig` gates added for delayed execution: the flush-operator
/// allowlist (add, remove, read, and the package `chk_operator`), the
/// freeze-blind `chk_floor`, the `chk_cutover` check
/// against the version watermark, and the `FlushOperatorUpdated` event layout.
#[test_only]
module deepbook_predict::delayed_execution_gate_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_events,
    constants,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self as test, Scenario, return_shared}};

const EVENT_TIMESTAMP_MS: u64 = 1_750_000_000_000;
const ONE_EVENT: u64 = 1;
const TWO_EVENTS: u64 = 2;

/// Field-for-field mirror of `config_events::FlushOperatorUpdated`.
public struct ExpectedFlushOperatorUpdated has copy, drop {
    operator: address,
    added: bool,
    onchain_timestamp_ms: u64,
}

// === Flush operators ===

#[test]
fun flush_operator_reads_false_before_any_add() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // No allowlist field exists yet; that reads as an empty set.
    assert!(!config.is_flush_operator(test_constants::admin()));

    finish(scenario, admin_cap, config, clock);
}

#[test]
fun add_flush_operator_allows_only_that_address_and_emits() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);

    assert!(config.is_flush_operator(test_constants::alice()));
    assert!(!config.is_flush_operator(test_constants::bob()));
    let events = event::events_by_type<config_events::FlushOperatorUpdated>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedFlushOperatorUpdated {
        operator: test_constants::alice(),
        added: true,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[ONE_EVENT - 1]), bcs::to_bytes(&expected));

    finish(scenario, admin_cap, config, clock);
}

#[test]
fun remove_flush_operator_revokes_and_emits() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    config.remove_flush_operator(&admin_cap, test_constants::alice(), &clock);

    assert!(!config.is_flush_operator(test_constants::alice()));
    let events = event::events_by_type<config_events::FlushOperatorUpdated>();
    assert_eq!(events.length(), TWO_EVENTS);
    let expected = ExpectedFlushOperatorUpdated {
        operator: test_constants::alice(),
        added: false,
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[TWO_EVENTS - 1]), bcs::to_bytes(&expected));

    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::EFlushOperatorAlreadyAdded)]
fun add_flush_operator_twice_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun add_flush_operator_while_frozen_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_frozen(&admin_cap, true);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EFlushOperatorNotFound)]
fun remove_flush_operator_before_any_add_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.remove_flush_operator(&admin_cap, test_constants::alice(), &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EFlushOperatorNotFound)]
fun remove_flush_operator_not_in_set_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    config.remove_flush_operator(&admin_cap, test_constants::bob(), &clock);
    abort 999
}

/// Revocation bypasses the version gate, so it works under the freeze.
#[test]
fun remove_flush_operator_works_while_frozen() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    config.set_frozen(&admin_cap, true);

    config.remove_flush_operator(&admin_cap, test_constants::alice(), &clock);

    assert!(!config.is_flush_operator(test_constants::alice()));
    finish(scenario, admin_cap, config, clock);
}

/// Revocation also works from a package version below the watermark.
#[test]
fun remove_flush_operator_works_below_version_floor() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::alice(), &clock);
    config.set_version_watermark_for_testing(constants::current_version!() + 1);

    config.remove_flush_operator(&admin_cap, test_constants::alice(), &clock);

    assert!(!config.is_flush_operator(test_constants::alice()));
    finish(scenario, admin_cap, config, clock);
}

#[test]
fun assert_flush_operator_passes_for_listed_sender() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::admin(), &clock);

    // The scenario's sender is admin.
    config.chk_operator(scenario.ctx());

    assert_eq!(scenario.ctx().sender(), test_constants::admin());
    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::ENotFlushOperator)]
fun assert_flush_operator_rejects_unlisted_sender() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.add_flush_operator(&admin_cap, test_constants::admin(), &clock);
    return_shared(config);

    scenario.next_tx(test_constants::alice());
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.chk_operator(scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::ENotFlushOperator)]
fun assert_flush_operator_rejects_everyone_before_any_add() {
    let (mut scenario, _admin_cap, config_id, _clock) = new_shared_config();
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.chk_operator(scenario.ctx());
    abort 999
}

// === Version floor and cutover ===

#[test]
fun version_watermark_reads_the_floor() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // Genesis seeds the floor at the running version.
    assert_eq!(config.version_watermark(), constants::current_version!());
    config.set_version_watermark_for_testing(constants::current_version!() - 1);
    assert_eq!(config.version_watermark(), constants::current_version!() - 1);

    finish(scenario, admin_cap, config, clock);
}

/// Unlike `chk_version`, the floor check ignores the freeze, so refunds,
/// admin refunds, and cleanup keep working while frozen.
#[test]
fun assert_version_floor_passes_while_frozen() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_frozen(&admin_cap, true);

    config.chk_floor();

    assert!(config.frozen());
    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun assert_version_floor_below_watermark_aborts() {
    let (scenario, _admin_cap, config_id, _clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_version_watermark_for_testing(constants::current_version!() + 1);
    config.chk_floor();
    abort 999
}

#[test]
fun assert_cutover_reached_at_current_version() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    config.chk_cutover();

    assert_eq!(config.version_watermark(), constants::current_version!());
    finish(scenario, admin_cap, config, clock);
}

/// The window between the v4 upgrade and its `bump_version_watermark`: the
/// watermark still names the previous version, so queued placement waits.
#[test, expected_failure(abort_code = protocol_config::ECutoverNotReached)]
fun assert_cutover_reached_one_version_below_aborts() {
    let (scenario, _admin_cap, config_id, _clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_version_watermark_for_testing(constants::current_version!() - 1);
    config.chk_cutover();
    abort 999
}

#[test]
fun bump_version_watermark_reaches_the_cutover() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_version_watermark_for_testing(constants::current_version!() - 1);

    config.bump_version_watermark(&admin_cap);
    config.chk_cutover();

    assert_eq!(config.version_watermark(), constants::current_version!());
    finish(scenario, admin_cap, config, clock);
}

// === Helpers ===

/// A real shared `ProtocolConfig` at genesis (watermark at `current_version!()`,
/// not frozen, no flush operators) and an `AdminCap`, ready in the next
/// transaction with admin as sender.
fun new_shared_config(): (Scenario, AdminCap, ID, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id, clock)
}

fun finish(scenario: Scenario, admin_cap: AdminCap, config: ProtocolConfig, clock: Clock) {
    return_shared(config);
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}
