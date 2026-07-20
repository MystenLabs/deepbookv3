// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical Propbook source catalog and binding projections used by Predict.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__oracle_registry_tests;

use deepbook_predict::{oracle_setup, test_values, test_world};
use propbook::registry as registry;
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const REPLACEMENT_SOURCE_ID: u32 = 2;

#[test]
fun source_creation_records_each_feed_identity_under_its_kind() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );

    assert!(oracle_registry.contains_pyth_source(test_values::pyth_source_id()));
    assert!(
        oracle_registry
            .propbook_pyth_id_for_source(test_values::pyth_source_id())
            .contains(&pyth_id),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_spot_id_for_source(test_values::pyth_source_id())
            .contains(&bs_spot_id),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_forward_id_for_source(test_values::pyth_source_id())
            .contains(&bs_forward_id),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_svi_id_for_source(test_values::pyth_source_id())
            .contains(&bs_svi_id),
    );

    return_shared(oracle_registry);
    test_world::finish(world, resources);
}

#[test]
fun binding_projects_each_canonical_identity_and_metadata_kind() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let ids = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let admin_cap = test_world::take_propbook_admin_cap(&world);
    let pyth = oracle_setup::take_pyth(&world, &ids);
    let bs_spot = oracle_setup::take_bs_spot(&world, &ids);
    let bs_forward = oracle_setup::take_bs_forward(&world, &ids);
    let bs_svi = oracle_setup::take_bs_svi(&world, &ids);

    oracle_registry.bind_pyth_to_underlying(
        &admin_cap,
        &pyth,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_spot_to_underlying(
        &admin_cap,
        &bs_spot,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_surface_to_underlying(
        &admin_cap,
        &bs_forward,
        &bs_svi,
        test_values::propbook_underlying_id(),
    );

    assert!(
        oracle_registry
            .propbook_pyth_id_for_underlying(test_values::propbook_underlying_id())
            .contains(&oracle_setup::pyth_id(&ids)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_spot_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_spot_id(&ids)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_forward_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_forward_id(&ids)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_svi_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_svi_id(&ids)),
    );
    let svi_metadata = oracle_registry
        .block_scholes_svi_metadata_for_underlying(test_values::propbook_underlying_id())
        .destroy_some();
    assert_eq!(
        registry::propbook_underlying_id(&svi_metadata),
        test_values::propbook_underlying_id(),
    );
    assert_eq!(registry::source_id(&svi_metadata), test_values::pyth_source_id());
    assert_eq!(registry::propbook_oracle_id(&svi_metadata), oracle_setup::bs_svi_id(&ids));

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    test_world::return_propbook_admin_cap(&world, admin_cap);
    return_shared(oracle_registry);
    test_world::finish(world, resources);
}

#[test]
fun replacement_moves_all_canonical_slots_to_the_new_source() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let original = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &admin_cap, &original);
    test_world::return_propbook_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let replacement = oracle_setup::create_oracles(&mut world, REPLACEMENT_SOURCE_ID);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let admin_cap = test_world::take_propbook_admin_cap(&world);
    let pyth = oracle_setup::take_pyth(&world, &replacement);
    let bs_spot = oracle_setup::take_bs_spot(&world, &replacement);
    let bs_forward = oracle_setup::take_bs_forward(&world, &replacement);
    let bs_svi = oracle_setup::take_bs_svi(&world, &replacement);

    oracle_registry.replace_pyth_binding_for_underlying(
        &admin_cap,
        &pyth,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.replace_block_scholes_bindings_for_underlying(
        &admin_cap,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_values::propbook_underlying_id(),
    );

    assert!(
        oracle_registry
            .propbook_pyth_id_for_underlying(test_values::propbook_underlying_id())
            .contains(&oracle_setup::pyth_id(&replacement)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_spot_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_spot_id(&replacement)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_forward_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_forward_id(&replacement)),
    );
    assert!(
        oracle_registry
            .propbook_block_scholes_svi_id_for_underlying(
                test_values::propbook_underlying_id(),
            )
            .contains(&oracle_setup::bs_svi_id(&replacement)),
    );
    assert!(
        !oracle_registry
            .propbook_pyth_id_for_underlying(test_values::propbook_underlying_id())
            .contains(&oracle_setup::pyth_id(&original)),
    );

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    test_world::return_propbook_admin_cap(&world, admin_cap);
    return_shared(oracle_registry);
    test_world::finish(world, resources);
}
