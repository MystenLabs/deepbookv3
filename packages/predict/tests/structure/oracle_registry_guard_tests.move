// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical Propbook source and surface-binding guards used by Predict.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__oracle_registry_tests;

use deepbook_predict::{oracle_setup, test_values, test_world};
use propbook::registry as registry;

const OTHER_SOURCE_ID: u32 = 2;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = registry::ESourceAlreadyExists)]
fun duplicate_source_creation_aborts_before_a_second_feed_is_shared() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let _ = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let _ = registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = registry::EWrongBlockScholesSource)]
fun block_scholes_surface_binding_rejects_mixed_source_ids() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let first = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let second = oracle_setup::create_oracles(&mut world, OTHER_SOURCE_ID);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let admin_cap = test_world::take_propbook_admin_cap(&world);
    let first_spot = oracle_setup::take_bs_spot(&world, &first);
    let first_forward = oracle_setup::take_bs_forward(&world, &first);
    let second_svi = oracle_setup::take_bs_svi(&world, &second);

    oracle_registry.bind_block_scholes_spot_to_underlying(
        &admin_cap,
        &first_spot,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_surface_to_underlying(
        &admin_cap,
        &first_forward,
        &second_svi,
        test_values::propbook_underlying_id(),
    );
    abort EUnexpectedSuccess
}
