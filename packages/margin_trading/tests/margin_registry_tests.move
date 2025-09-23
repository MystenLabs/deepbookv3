// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_registry_tests;

use margin_trading::margin_registry::{Self, MarginRegistry};
use margin_trading::test_constants;
use margin_trading::test_helpers::{setup_margin_registry, cleanup_margin_test};

// === Test mint_maintainer_cap ===

#[test]
fun test_mint_maintainer_cap_ok() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Mint a new maintainer cap
    let new_maintainer_cap = registry.mint_maintainer_cap(&admin_cap, &clock, scenario.ctx());

    // Verify cap was created successfully (just ensure it doesn't abort)
    sui::test_utils::destroy(new_maintainer_cap);

    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

// === Test revoke_maintainer_cap ===

#[test]
fun test_revoke_maintainer_cap_ok() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let maintainer_cap_id = sui::object::id(&maintainer_cap);

    // Revoke the maintainer cap
    registry.revoke_maintainer_cap(&admin_cap, maintainer_cap_id, &clock);

    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_registry::EMaintainerCapNotValid)]
fun test_revoke_random_cap_should_fail() {
    let (mut scenario, clock, admin_cap, maintainer_cap) = setup_margin_registry();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();

    // Try to revoke a random ID that was never a maintainer cap
    let random_id = sui::object::id_from_address(@0x123);
    registry.revoke_maintainer_cap(&admin_cap, random_id, &clock);

    cleanup_margin_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
