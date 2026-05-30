// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared scaffolding for Predict tests.
///
/// Patterns mirror `deepbook_margin::test_helpers`:
/// - small destroy/return macros to keep cleanup terse,
/// - a `setup_test` that begins a `test_scenario` and seeds a real `Registry`
///   + `AdminCap` via `registry::init_for_testing`, so downstream tests can
///   `take_shared_by_id<T>` for known IDs (see `.claude/rules/unit-tests.md` rule 13).
#[test_only]
module deepbook_predict::test_helpers;

use deepbook_predict::{registry::{AdminCap, Registry}, test_constants};
use std::unit_test::destroy;
use sui::test_scenario::{Self as test, Scenario};

// === Destroy macros ===

public macro fun destroy_2<$T1, $T2>($obj1: $T1, $obj2: $T2) {
    destroy($obj1);
    destroy($obj2);
}

public macro fun destroy_3<$T1, $T2, $T3>($obj1: $T1, $obj2: $T2, $obj3: $T3) {
    destroy($obj1);
    destroy($obj2);
    destroy($obj3);
}

public macro fun destroy_4<$T1, $T2, $T3, $T4>($obj1: $T1, $obj2: $T2, $obj3: $T3, $obj4: $T4) {
    destroy($obj1);
    destroy($obj2);
    destroy($obj3);
    destroy($obj4);
}

// === Scenario setup ===

/// Begin a `Scenario` as `test_constants::admin()` and share a `Registry` +
/// `ProtocolConfig` via `registry::init_for_testing`. Returns the registry ID
/// so callers can `take_shared_by_id<Registry>` later.
public fun setup_test(): (Scenario, ID) {
    let mut scenario = test::begin(test_constants::admin());
    let registry_id = deepbook_predict::registry::init_for_testing(scenario.ctx());

    (scenario, registry_id)
}

/// Take a shared `Registry` by ID and the admin `AdminCap` from the admin's
/// inbox in the current transaction.
public fun take_registry_and_admin(scenario: &mut Scenario, registry_id: ID): (Registry, AdminCap) {
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let admin_cap = scenario.take_from_sender<AdminCap>();

    (registry, admin_cap)
}

/// Begin a scenario-backed registry test transaction and take the real
/// `Registry` + `AdminCap` created by package-style setup.
public fun begin_registry_test(): (Scenario, Registry, AdminCap) {
    let (mut scenario, registry_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let (registry, admin_cap) = take_registry_and_admin(&mut scenario, registry_id);

    (scenario, registry, admin_cap)
}

/// Return the shared registry and destroy the test-owned admin cap.
public fun finish_registry_test(scenario: Scenario, registry: Registry, admin_cap: AdminCap) {
    test::return_shared(registry);
    destroy(admin_cap);
    scenario.end();
}
