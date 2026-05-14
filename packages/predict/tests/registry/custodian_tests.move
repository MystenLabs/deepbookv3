// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::custodian_tests;

use deepbook_predict::predict_manager::PredictManager;
use deepbook_predict::registry::{Self, Registry, AdminCap};
use sui::test_scenario as ts;

/// A test-only App-witness. In real usage a calling protocol would
/// define this in its own module.
public struct TestApp() has drop;

/// A second witness used to test that auth is per-type.
public struct OtherApp() has drop;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const CUSTODIAN: address = @0xCAFE;

#[test]
fun authorize_then_create_for_custodian_succeeds() {
    let mut sc = ts::begin(ADMIN);

    // Init the registry. Admin keeps the AdminCap.
    let _registry_id = registry::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);

    // Admin authorizes TestApp.
    let admin_cap: AdminCap = ts::take_from_sender(&sc);
    let mut registry: Registry = ts::take_shared(&sc);
    registry::authorize_app<TestApp>(&mut registry, &admin_cap);
    ts::return_to_sender(&sc, admin_cap);

    // App-authorization sanity check should not abort.
    registry::assert_app_is_authorized<TestApp>(&registry);

    // ALICE (any sender) can now create a manager whose owner is CUSTODIAN.
    ts::next_tx(&mut sc, ALICE);
    let manager = registry::create_manager_for_custodian<TestApp>(
        &mut registry,
        CUSTODIAN,
        ts::ctx(&mut sc),
    );

    // Owner is the custodian, not the sender (Alice).
    assert!(manager.owner() == CUSTODIAN, 0);
    assert!(manager.owner() != ALICE, 1);

    manager.share();
    ts::return_shared(registry);
    ts::end(sc);
}

// EAppNotAuthorized = 7 in registry.move (module-private const; we use the
// numeric form here because Move constants aren't cross-module visible).
#[test, expected_failure(abort_code = 7, location = deepbook_predict::registry)]
fun unauthorized_app_aborts() {
    let mut sc = ts::begin(ADMIN);
    let _registry_id = registry::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut registry: Registry = ts::take_shared(&sc);

    // Authorize TestApp only.
    let admin_cap: AdminCap = ts::take_from_sender(&sc);
    registry::authorize_app<TestApp>(&mut registry, &admin_cap);
    ts::return_to_sender(&sc, admin_cap);

    // Attempting to create_manager_for_custodian<OtherApp> must abort.
    ts::next_tx(&mut sc, ALICE);
    let manager = registry::create_manager_for_custodian<OtherApp>(
        &mut registry,
        CUSTODIAN,
        ts::ctx(&mut sc),
    );

    manager.share();
    ts::return_shared(registry);
    ts::end(sc);
}

#[test]
fun deauthorize_removes_access() {
    let mut sc = ts::begin(ADMIN);
    let _registry_id = registry::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);

    let admin_cap: AdminCap = ts::take_from_sender(&sc);
    let mut registry: Registry = ts::take_shared(&sc);
    registry::authorize_app<TestApp>(&mut registry, &admin_cap);
    let was_present = registry::deauthorize_app<TestApp>(&mut registry, &admin_cap);
    assert!(was_present, 0);
    ts::return_to_sender(&sc, admin_cap);
    ts::return_shared(registry);
    ts::end(sc);
}

#[test]
fun create_for_custodian_with_owner_eq_sender_still_works() {
    // The custom-owner constructor is general — if a caller wants owner ==
    // sender, that's allowed too. Just exercises the equivalence path.
    let mut sc = ts::begin(ADMIN);
    let _registry_id = registry::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);

    let admin_cap: AdminCap = ts::take_from_sender(&sc);
    let mut registry: Registry = ts::take_shared(&sc);
    registry::authorize_app<TestApp>(&mut registry, &admin_cap);
    ts::return_to_sender(&sc, admin_cap);

    ts::next_tx(&mut sc, ALICE);
    let manager = registry::create_manager_for_custodian<TestApp>(
        &mut registry,
        ALICE,
        ts::ctx(&mut sc),
    );

    assert!(manager.owner() == ALICE, 0);

    manager.share();
    ts::return_shared(registry);
    ts::end(sc);
}
