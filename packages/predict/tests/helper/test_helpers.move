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

use deepbook_predict::{admin::AdminCap, registry::Registry, test_constants};
use std::unit_test::destroy;
use sui::{coin::{Self, Coin}, test_scenario::{Self as test, Scenario}};

// === Coin minting ===

/// Mint a test coin of any type for the current sender.
public fun mint_coin<T>(amount: u64, scenario: &mut Scenario): Coin<T> {
    coin::mint_for_testing<T>(amount, scenario.ctx())
}

// === Bounded assertion (math carve-out) ===

/// Assert `actual` is within `max_abs_diff` of an INDEPENDENTLY-derived
/// `reference`. The only sanctioned use is fixed-point math whose approximation
/// error is fundamental: `max_abs_diff` must be a principled bound (the fixed-
/// point representation granularity, or a documented intended precision), NEVER
/// a value measured from the contract's current output (see unit-tests rule 10
/// carve-out). Exact results must use `assert_eq!`, not this.
public fun assert_within(actual: u64, reference: u64, max_abs_diff: u64) {
    let diff = if (actual > reference) actual - reference else reference - actual;
    assert!(diff <= max_abs_diff);
}

/// Assert `actual` is within a RELATIVE budget of an independently-derived
/// `reference`, for fixed-point primitives whose error scales with magnitude
/// (`exp`/`ln`; see math.move "Precision contract"). `rel_budget` is in parts
/// per 1e9, e.g. 100 = 1e-7. Tolerance is `reference * rel_budget / 1e9`, floored
/// at 1 ULP so small-magnitude references still admit the representation
/// granularity. NEVER tune `rel_budget` from contract output (unit-tests rule 10).
public fun assert_within_relative(actual: u64, reference: u64, rel_budget: u64) {
    let rel_tol = (reference as u128) * (rel_budget as u128) / 1_000_000_000;
    let tol = if (rel_tol < 1) 1
    else (rel_tol as u64); // 1-ULP representation floor
    let diff = if (actual > reference) actual - reference else reference - actual;
    assert!(diff <= tol);
}

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

// === return_shared macros ===
// Terse multi-object `test_scenario::return_shared` for flow tests that take
// several shared objects at once (port of `deepbook_margin::test_helpers`).

public macro fun return_shared_2<$T1, $T2>($o1: $T1, $o2: $T2) {
    test::return_shared($o1);
    test::return_shared($o2);
}

public macro fun return_shared_3<$T1, $T2, $T3>($o1: $T1, $o2: $T2, $o3: $T3) {
    test::return_shared($o1);
    test::return_shared($o2);
    test::return_shared($o3);
}

public macro fun return_shared_4<$T1, $T2, $T3, $T4>($o1: $T1, $o2: $T2, $o3: $T3, $o4: $T4) {
    test::return_shared($o1);
    test::return_shared($o2);
    test::return_shared($o3);
    test::return_shared($o4);
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
