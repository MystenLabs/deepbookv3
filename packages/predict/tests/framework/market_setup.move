// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid cadence and market prerequisites. Every function operates
/// in the caller's current transaction.
#[test_only]
module deepbook_predict::market_setup;

use deepbook_predict::{
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    test_values,
    test_world::{Self, OwnedResources, World}
};
use sui::test_scenario::return_shared;

public struct MarketHandle has copy, drop {
    id: ID,
    expiry_ms: u64,
}

public fun market_id(handle: &MarketHandle): ID { handle.id }

public fun expiry_ms(handle: &MarketHandle): u64 { handle.expiry_ms }

public fun configure_default_cadence(world: &mut World, resources: &OwnedResources) {
    let mut registry = test_world::take_registry(world);
    let config = test_world::take_config(world);
    registry.register_underlying(
        &config,
        test_world::predict_admin_cap(resources),
        test_values::propbook_underlying_id(),
    );
    registry.set_template_cadence_config(
        &config,
        test_world::predict_admin_cap(resources),
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    return_shared(config);
    return_shared(registry);
}

public fun create_default_market(
    world: &mut World,
    resources: &OwnedResources,
): (MarketHandle, MarketLifecycleCap) {
    let mut registry = test_world::take_registry(world);
    let mut vault = test_world::take_vault(world);
    let config = test_world::take_config(world);
    let oracle_registry = test_world::take_oracle_registry(world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        test_world::predict_admin_cap(resources),
        test_world::ctx(world),
    );
    let id = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(resources),
        test_world::ctx(world),
    );
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    (MarketHandle { id, expiry_ms: test_values::expiry_ms() }, lifecycle_cap)
}

public fun take_market(world: &World, handle: &MarketHandle): ExpiryMarket {
    test_world::take_shared_by_id<ExpiryMarket>(world, handle.id)
}
