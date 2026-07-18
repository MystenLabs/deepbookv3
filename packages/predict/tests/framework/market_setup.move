// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid market prerequisites for tests whose unit under test begins
/// after construction. Every function operates in the caller's current transaction.
#[test_only]
module deepbook_predict::market_setup;

use block_scholes_oracle::update;
use deepbook_predict::{
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    test_values,
    test_world::{Self, OwnedResources, World}
};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::{Self, PythFeed},
    registry
};
use sui::{clock::Clock, test_scenario::return_shared};

const PYTH_EXPONENT_NEGATIVE_NINE: u16 = 9;

public struct OracleIds has copy, drop {
    pyth_id: ID,
    bs_spot_id: ID,
    bs_forward_id: ID,
    bs_svi_id: ID,
}

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

public fun create_default_oracles(world: &mut World): OracleIds {
    let mut oracle_registry = test_world::take_oracle_registry(world);
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(world),
    );
    let bs_spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(world),
    );
    let bs_forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(world),
    );
    let bs_svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(world),
    );
    return_shared(oracle_registry);
    OracleIds { pyth_id, bs_spot_id, bs_forward_id, bs_svi_id }
}

public fun bind_default_oracles(world: &World, resources: &OwnedResources, ids: &OracleIds) {
    let mut oracle_registry = test_world::take_oracle_registry(world);
    let pyth = test_world::take_shared_by_id<PythFeed>(world, ids.pyth_id);
    let bs_spot = test_world::take_shared_by_id<BlockScholesSpotFeed>(world, ids.bs_spot_id);
    let bs_forward = test_world::take_shared_by_id<BlockScholesForwardFeed>(
        world,
        ids.bs_forward_id,
    );
    let bs_svi = test_world::take_shared_by_id<BlockScholesSVIFeed>(world, ids.bs_svi_id);
    oracle_registry.bind_pyth_to_underlying(
        test_world::propbook_admin_cap(resources),
        &pyth,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_spot_to_underlying(
        test_world::propbook_admin_cap(resources),
        &bs_spot,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_surface_to_underlying(
        test_world::propbook_admin_cap(resources),
        &bs_forward,
        &bs_svi,
        test_values::propbook_underlying_id(),
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
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

public fun take_pyth(world: &World, ids: &OracleIds): PythFeed {
    test_world::take_shared_by_id<PythFeed>(world, ids.pyth_id)
}

public fun take_bs_spot(world: &World, ids: &OracleIds): BlockScholesSpotFeed {
    test_world::take_shared_by_id<BlockScholesSpotFeed>(world, ids.bs_spot_id)
}

public fun take_bs_forward(world: &World, ids: &OracleIds): BlockScholesForwardFeed {
    test_world::take_shared_by_id<BlockScholesForwardFeed>(world, ids.bs_forward_id)
}

public fun take_bs_svi(world: &World, ids: &OracleIds): BlockScholesSVIFeed {
    test_world::take_shared_by_id<BlockScholesSVIFeed>(world, ids.bs_svi_id)
}

public fun seed_pyth(pyth: &mut PythFeed, price: u64, source_timestamp_ms: u64, now_ms: u64) {
    pyth_feed::record_raw_for_testing(
        pyth,
        price,
        false,
        PYTH_EXPONENT_NEGATIVE_NINE,
        true,
        source_timestamp_ms * 1000,
        now_ms,
        false,
    );
}

public fun seed_bs_spot(
    feed: &mut BlockScholesSpotFeed,
    price: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    feed.update(
        update::new_spot_update(test_values::pyth_source_id(), source_timestamp_ms, price),
        clock,
    );
}

public fun seed_bs_forward(
    feed: &mut BlockScholesForwardFeed,
    expiry_ms: u64,
    price: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    feed.update(
        update::new_forward_update(
            test_values::pyth_source_id(),
            expiry_ms,
            source_timestamp_ms,
            price,
        ),
        clock,
        ctx,
    );
}

public fun seed_default_bs_svi(
    feed: &mut BlockScholesSVIFeed,
    expiry_ms: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    feed.update(
        update::new_svi_update(
            test_values::pyth_source_id(),
            expiry_ms,
            source_timestamp_ms,
            test_values::svi_a(),
            false,
            test_values::svi_b(),
            test_values::svi_sigma(),
            test_values::svi_rho_magnitude(),
            false,
            test_values::svi_m_magnitude(),
            false,
        ),
        clock,
        ctx,
    );
}
