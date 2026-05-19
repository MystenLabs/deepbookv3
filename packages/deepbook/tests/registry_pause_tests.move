// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::registry_pause_tests;

use deepbook::{
    balance_manager_tests::{USDC, USDT},
    constants,
    pool::{Self, Pool},
    registry::{Self, Registry}
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{begin, end, return_shared};

const OWNER: address = @0xF;

#[test]
fun mint_pause_cap_adds_id_to_allowed_set() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let pause_cap_id = sui::object::id(&pause_cap);

    let allowed = registry.allowed_pause_caps();
    assert_eq!(allowed.length(), 1);
    assert!(allowed.contains(&pause_cap_id));

    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);
    end(test);
}

#[test]
fun mint_two_pause_caps_both_recorded() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let cap_a = registry.mint_pause_cap(&admin_cap, test.ctx());
    let cap_b = registry.mint_pause_cap(&admin_cap, test.ctx());
    let id_a = sui::object::id(&cap_a);
    let id_b = sui::object::id(&cap_b);

    let allowed = registry.allowed_pause_caps();
    assert_eq!(allowed.length(), 2);
    assert!(allowed.contains(&id_a));
    assert!(allowed.contains(&id_b));

    return_shared(registry);
    destroy(admin_cap);
    destroy(cap_a);
    destroy(cap_b);
    end(test);
}

#[test]
fun disable_version_with_pause_cap_ok() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let new_version = constants::current_version() + 1;
    registry.enable_version(new_version, &admin_cap);

    registry.disable_version_pause_cap(new_version, &pause_cap);

    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);
    end(test);
}

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun disable_version_with_revoked_pause_cap_fails() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let pause_cap_id = sui::object::id(&pause_cap);
    let new_version = constants::current_version() + 1;
    registry.enable_version(new_version, &admin_cap);

    registry.disable_version_pause_cap(new_version, &pause_cap);
    registry.enable_version(new_version, &admin_cap);
    registry.revoke_pause_cap(&admin_cap, pause_cap_id);

    registry.disable_version_pause_cap(new_version, &pause_cap);

    abort
}

#[test]
fun revoke_pause_cap_removes_id() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let pause_cap_id = sui::object::id(&pause_cap);

    registry.revoke_pause_cap(&admin_cap, pause_cap_id);

    assert_eq!(registry.allowed_pause_caps().length(), 0);

    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);
    end(test);
}

#[test]
fun disable_and_readmit_when_only_current_version_live_ok() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let allowed_before = registry.allowed_versions();
    assert_eq!(allowed_before.length(), 1);
    assert!(allowed_before.contains(&constants::current_version()));

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());

    registry.disable_version_pause_cap(constants::current_version(), &pause_cap);

    registry.enable_version(constants::current_version(), &admin_cap);

    let allowed_after = registry.allowed_versions();
    assert_eq!(allowed_after.length(), 1);
    assert!(allowed_after.contains(&constants::current_version()));

    registry.set_treasury_address(@0xCAFE, &admin_cap);

    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);
    end(test);
}

#[test, expected_failure(abort_code = registry::EPackageVersionNotEnabled)]
fun disable_current_version_with_pause_cap_blocks_gated_calls() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    registry.disable_version_pause_cap(constants::current_version(), &pause_cap);

    registry.set_treasury_address(@0xCAFE, &admin_cap);

    abort
}

#[test, expected_failure(abort_code = registry::EVersionNotEnabled)]
fun disable_already_disabled_version_with_pause_cap_fails() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let new_version = constants::current_version() + 1;

    registry.disable_version_pause_cap(new_version, &pause_cap);

    abort
}

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoke_unknown_pause_cap_fails() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let _pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    let bogus_id = sui::object::id_from_address(@0xDEAD);

    registry.revoke_pause_cap(&admin_cap, bogus_id);

    abort
}

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoke_pause_cap_before_any_minted_fails() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let bogus_id = sui::object::id_from_address(@0xBEEF);
    registry.revoke_pause_cap(&admin_cap, bogus_id);

    abort
}

#[test]
fun allowed_versions_readable_while_paused() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());

    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    registry.disable_version_pause_cap(constants::current_version(), &pause_cap);

    let allowed = registry.allowed_versions();
    assert_eq!(allowed.length(), 0);

    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);
    end(test);
}

#[test, expected_failure(abort_code = pool::EPackageVersionDisabled)]
fun pause_cap_propagates_to_pool_via_permissionless_update() {
    let mut test = begin(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let pool_id = pool::create_pool_admin<USDC, USDT>(
        &mut registry,
        1000,
        1000,
        10000,
        false,
        false,
        &admin_cap,
        test.ctx(),
    );
    return_shared(registry);
    destroy(admin_cap);

    test.next_tx(OWNER);
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let pause_cap = registry.mint_pause_cap(&admin_cap, test.ctx());
    registry.disable_version_pause_cap(constants::current_version(), &pause_cap);
    return_shared(registry);
    destroy(admin_cap);
    destroy(pause_cap);

    test.next_tx(@0xCAFE);
    let registry = test.take_shared_by_id<Registry>(registry_id);
    let mut pool = test.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    pool::update_pool_allowed_versions(&mut pool, &registry);
    return_shared(registry);
    return_shared(pool);

    test.next_tx(@0xCAFE);
    let pool = test.take_shared_by_id<Pool<USDC, USDT>>(pool_id);
    let _ = pool.whitelisted();

    abort
}
