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

use deepbook_predict::{
    admin::AdminCap,
    protocol_config::ProtocolConfig,
    registry::Registry,
    test_constants
};
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::destroy;
use sui::test_scenario::{Self as test, Scenario, return_shared};

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
/// `Registry` + shared `ProtocolConfig` + `AdminCap` created by package-style
/// setup. `ProtocolConfig` is returned because version-gated registry entrypoints
/// now take it (the watermark gate lives on the config).
public fun begin_registry_test(): (Scenario, Registry, ProtocolConfig, AdminCap) {
    let (mut scenario, registry_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let (registry, admin_cap) = take_registry_and_admin(&mut scenario, registry_id);
    let config = scenario.take_shared<ProtocolConfig>();

    (scenario, registry, config, admin_cap)
}

/// Return the shared registry + config and destroy the test-owned admin cap.
public fun finish_registry_test(
    scenario: Scenario,
    registry: Registry,
    config: ProtocolConfig,
    admin_cap: AdminCap,
) {
    test::return_shared(registry);
    test::return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

/// Admin-bind both already-shared propbook feeds to `propbook_underlying_id()`,
/// so the production `registry::create_expiry_market` binding check passes. Uses
/// the propbook `RegistryAdminCap` minted to admin by `propbook_registry::
/// init_for_testing`. Operates within the CURRENT transaction (sender must be
/// admin and both feeds must already be shared); the one-shot cap is consumed.
public fun bind_feeds_to_underlying(scenario: &Scenario, pyth_id: ID, bs_id: ID) {
    let admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    let bs = scenario.take_shared_by_id<BlockScholesFeed>(bs_id);
    propbook_registry::bind_pyth_to_underlying(
        &mut oracle_registry,
        &admin_cap,
        &pyth,
        test_constants::propbook_underlying_id(),
    );
    propbook_registry::bind_block_scholes_to_underlying(
        &mut oracle_registry,
        &admin_cap,
        &bs,
        test_constants::propbook_underlying_id(),
    );
    return_shared(pyth);
    return_shared(bs);
    return_shared(oracle_registry);
    destroy(admin_cap);
}
