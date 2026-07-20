// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid cadence and market prerequisites. Every function operates
/// in the caller's current transaction.
#[test_only]
module deepbook_predict::market_setup;

use deepbook_predict::{
    admin::AdminCap,
    expiry_market::ExpiryMarket,
    protocol_config::ProtocolConfig,
    registry::Registry,
    test_values,
    test_world::{Self, OwnedResources, World}
};
use sui::test_scenario::return_shared;

public struct MarketHandle has copy, drop {
    id: ID,
}

public fun market_id(handle: &MarketHandle): ID { handle.id }

public fun configure_cadence(world: &World, admin_cap: &AdminCap, window_size: u64) {
    let mut registry = test_world::take_registry(world);
    let config = test_world::take_config(world);
    configure_cadence_objects(&mut registry, &config, admin_cap, window_size);
    return_shared(config);
    return_shared(registry);
}

public fun configure_default_cadence(world: &World, admin_cap: &AdminCap) {
    configure_cadence(world, admin_cap, test_values::cadence_window_size());
}

public fun configure_trading_defaults(world: &World, admin_cap: &AdminCap) {
    let mut registry = test_world::take_registry(world);
    let mut config = test_world::take_config(world);
    config.set_template_base_fee(admin_cap, 1);
    config.set_template_no_leverage_window_ms(admin_cap, 0);
    configure_cadence_objects(
        &mut registry,
        &config,
        admin_cap,
        test_values::cadence_window_size(),
    );
    return_shared(config);
    return_shared(registry);
}

public fun create_markets(
    world: &mut World,
    resources: &OwnedResources,
    admin_cap: &AdminCap,
    market_count: u64,
): vector<MarketHandle> {
    let mut registry = test_world::take_registry(world);
    let mut vault = test_world::take_vault(world);
    let config = test_world::take_config(world);
    let oracle_registry = test_world::take_oracle_registry(world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        admin_cap,
        test_world::ctx(world),
    );
    let mut handles = vector[];
    let mut index = 0;
    while (index < market_count) {
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
        handles.push_back(MarketHandle { id });
        index = index + 1;
    };
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    lifecycle_cap.destroy();
    handles
}

public fun create_default_market(
    world: &mut World,
    resources: &OwnedResources,
    admin_cap: &AdminCap,
): MarketHandle {
    let mut handles = create_markets(
        world,
        resources,
        admin_cap,
        1,
    );
    handles.pop_back()
}

public fun take_market(world: &World, handle: &MarketHandle): ExpiryMarket {
    test_world::take_shared_by_id<ExpiryMarket>(world, handle.id)
}

fun configure_cadence_objects(
    registry: &mut Registry,
    config: &ProtocolConfig,
    admin_cap: &AdminCap,
    window_size: u64,
) {
    registry.register_underlying(
        config,
        admin_cap,
        test_values::propbook_underlying_id(),
    );
    registry.set_template_cadence_config(
        config,
        admin_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        window_size,
    );
}
