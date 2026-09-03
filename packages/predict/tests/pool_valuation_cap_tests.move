// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pool-valuation-cap allowlist coverage: `registry::mint_pool_valuation_cap` /
/// `registry::revoke_pool_valuation_cap`, the `EPoolValuationCapNotValid` gate on
/// `registry::generate_pool_valuation_proof`, and that destroying a cap leaves the
/// allowlist untouched. Flush starts through a valid cap are exercised by every flow
/// test that calls `flow_test_helpers::start_flush`.
#[test_only]
module deepbook_predict::pool_valuation_cap_tests;

use deepbook_predict::{registry, test_helpers};
use std::unit_test::destroy;
use sui::test_scenario::return_shared;

const EUnexpectedSuccess: u64 = 999;

// === Pool-valuation-cap allowlist gates ===

#[test, expected_failure(abort_code = registry::EPoolValuationCapNotValid)]
fun generate_proof_with_revoked_pool_valuation_cap_aborts() {
    let (mut scenario, mut registry, config, admin_cap) = test_helpers::begin_registry_test();
    let revoked_cap = registry.mint_pool_valuation_cap(&config, &admin_cap, scenario.ctx());
    registry.revoke_pool_valuation_cap(&admin_cap, revoked_cap.id());
    let proof = registry.generate_pool_valuation_proof(&revoked_cap);
    proof.destroy_proof();
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = registry::EPoolValuationCapNotFound)]
fun revoke_unknown_pool_valuation_cap_aborts() {
    let (_scenario, mut registry, _config, admin_cap) = test_helpers::begin_registry_test();
    // An id that was never minted into the allowlist.
    registry.revoke_pool_valuation_cap(&admin_cap, object::id_from_address(@0xCAFE));
    abort EUnexpectedSuccess
}

#[test]
fun destroy_pool_valuation_cap_does_not_revoke() {
    let (mut scenario, mut registry, config, admin_cap) = test_helpers::begin_registry_test();
    let cap = registry.mint_pool_valuation_cap(&config, &admin_cap, scenario.ctx());
    let other_cap = registry.mint_pool_valuation_cap(&config, &admin_cap, scenario.ctx());
    let destroyed_id = cap.id();
    cap.destroy();
    // Destroying the cap object must not touch the registry allowlist: the id is
    // still allow-listed, so revoking it by the copied id succeeds (revoke aborts
    // EPoolValuationCapNotFound for ids not in the set).
    registry.revoke_pool_valuation_cap(&admin_cap, destroyed_id);
    // Post-state: revoking the destroyed cap's id leaves other allow-listed caps
    // valid.
    registry.revoke_pool_valuation_cap(&admin_cap, other_cap.id());
    other_cap.destroy();
    destroy(admin_cap);
    return_shared(registry);
    return_shared(config);
    scenario.end();
}
