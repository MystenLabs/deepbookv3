// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid oracle prerequisites and leaf feed setters. Every function
/// operates in the caller's current transaction.
#[test_only]
module deepbook_predict::oracle_setup;

use block_scholes_oracle::update;
use deepbook_predict::{
    oracle_profile::{Self, SurfaceProfile},
    test_values,
    test_world::{Self, World}
};
use propbook::{
    block_scholes_forward_feed::{Self as block_scholes_forward_feed, BlockScholesForwardFeed},
    block_scholes_spot_feed::{Self as block_scholes_spot_feed, BlockScholesSpotFeed},
    block_scholes_svi_feed::{Self as block_scholes_svi_feed, BlockScholesSVIFeed},
    pyth_feed::{Self, PythFeed},
    registry::{Self, RegistryAdminCap}
};
use sui::{clock::Clock, test_scenario::return_shared};

const PYTH_EXPONENT_NEGATIVE_NINE: u16 = 9;

public struct OracleIds has copy, drop {
    pyth_id: ID,
    bs_spot_id: ID,
    bs_forward_id: ID,
    bs_svi_id: ID,
}

public fun create_default_oracles(world: &mut World): OracleIds {
    create_oracles(world, test_values::pyth_source_id())
}

public fun create_oracles(world: &mut World, source_id: u32): OracleIds {
    let mut oracle_registry = test_world::take_oracle_registry(world);
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        source_id,
        test_world::ctx(world),
    );
    let bs_spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        source_id,
        test_world::ctx(world),
    );
    let bs_forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        source_id,
        test_world::ctx(world),
    );
    let bs_svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        source_id,
        test_world::ctx(world),
    );
    return_shared(oracle_registry);
    OracleIds { pyth_id, bs_spot_id, bs_forward_id, bs_svi_id }
}

public fun bind_default_oracles(world: &World, admin_cap: &RegistryAdminCap, ids: &OracleIds) {
    bind_oracles(
        world,
        admin_cap,
        ids,
        test_values::propbook_underlying_id(),
    )
}

public fun bind_oracles(
    world: &World,
    admin_cap: &RegistryAdminCap,
    ids: &OracleIds,
    propbook_underlying_id: u32,
) {
    let mut oracle_registry = test_world::take_oracle_registry(world);
    let pyth = test_world::take_shared_by_id<PythFeed>(world, ids.pyth_id);
    let bs_spot = test_world::take_shared_by_id<BlockScholesSpotFeed>(world, ids.bs_spot_id);
    let bs_forward = test_world::take_shared_by_id<BlockScholesForwardFeed>(
        world,
        ids.bs_forward_id,
    );
    let bs_svi = test_world::take_shared_by_id<BlockScholesSVIFeed>(world, ids.bs_svi_id);
    oracle_registry.bind_pyth_to_underlying(
        admin_cap,
        &pyth,
        propbook_underlying_id,
    );
    oracle_registry.bind_block_scholes_spot_to_underlying(
        admin_cap,
        &bs_spot,
        propbook_underlying_id,
    );
    oracle_registry.bind_block_scholes_surface_to_underlying(
        admin_cap,
        &bs_forward,
        &bs_svi,
        propbook_underlying_id,
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
}

public fun pyth_id(ids: &OracleIds): ID { ids.pyth_id }

public fun bs_spot_id(ids: &OracleIds): ID { ids.bs_spot_id }

public fun bs_forward_id(ids: &OracleIds): ID { ids.bs_forward_id }

public fun bs_svi_id(ids: &OracleIds): ID { ids.bs_svi_id }

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

public fun seed_exact_pyth(pyth: &mut PythFeed, price: u64, source_timestamp_ms: u64, now_ms: u64) {
    pyth_feed::record_raw_for_testing(
        pyth,
        price,
        false,
        PYTH_EXPONENT_NEGATIVE_NINE,
        true,
        source_timestamp_ms * 1000,
        now_ms,
        true,
    );
}

public fun seed_bs_spot(
    feed: &mut BlockScholesSpotFeed,
    price: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    let source_id = block_scholes_spot_feed::bs_source_id(feed);
    feed.update(
        update::new_spot_update(
            source_id,
            source_timestamp_ms,
            price,
        ),
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
    let source_id = block_scholes_forward_feed::bs_source_id(feed);
    feed.update(
        update::new_forward_update(
            source_id,
            expiry_ms,
            source_timestamp_ms,
            price,
        ),
        clock,
        ctx,
    );
}

public fun seed_bs_svi(
    feed: &mut BlockScholesSVIFeed,
    expiry_ms: u64,
    profile: &SurfaceProfile,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let source_id = block_scholes_svi_feed::bs_source_id(feed);
    feed.update(
        update::new_svi_update(
            source_id,
            expiry_ms,
            profile.source_timestamp_ms(),
            profile.svi_a(),
            profile.svi_a_is_negative(),
            profile.svi_b(),
            profile.svi_sigma(),
            profile.svi_rho_magnitude(),
            profile.svi_rho_is_negative(),
            profile.svi_m_magnitude(),
            profile.svi_m_is_negative(),
        ),
        clock,
        ctx,
    );
}

public fun seed_surface(
    pyth: &mut PythFeed,
    bs_spot: &mut BlockScholesSpotFeed,
    bs_forward: &mut BlockScholesForwardFeed,
    bs_svi: &mut BlockScholesSVIFeed,
    expiry_ms: u64,
    profile: &SurfaceProfile,
    now_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    seed_pyth(pyth, profile.pyth_spot(), profile.source_timestamp_ms(), now_ms);
    seed_bs_spot(
        bs_spot,
        profile.block_scholes_spot(),
        profile.source_timestamp_ms(),
        clock,
    );
    seed_bs_forward(
        bs_forward,
        expiry_ms,
        profile.block_scholes_forward(),
        profile.source_timestamp_ms(),
        clock,
        ctx,
    );
    seed_bs_svi(bs_svi, expiry_ms, profile, clock, ctx);
}
