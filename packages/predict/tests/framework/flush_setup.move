// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Full-pool flush driver for Phase 7 valuation/settlement tests. Runs the whole
/// privileged flush (`start_pool_valuation` -> per-market `value_expiry` ->
/// `finish_flush`) across every given market in the caller's current transaction
/// and returns the pool NAV. Every market's oracle surface must already be seeded
/// for its expiry; the caller owns transaction boundaries and actor identity.
#[test_only]
module deepbook_predict::flush_setup;

use deepbook_predict::{
    market_setup::{Self, MarketHandle},
    oracle_setup::{Self, OracleIds},
    plp,
    test_world::{Self, OwnedResources, World}
};
use sui::test_scenario::return_shared;

/// Drive one full-pool flush across `market_handles`, valuing each on its live
/// pricer at the frozen mark. `supply_budget`/`withdraw_budget` bound the queue
/// drains (`none` = unbounded). Returns the LP-attributable pool NAV.
public fun flush(
    world: &mut World,
    resources: &OwnedResources,
    oracles: &OracleIds,
    market_handles: &vector<MarketHandle>,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
): u64 {
    let admin_cap = test_world::take_predict_admin_cap(world);
    let mut registry = test_world::take_registry(world);
    let mut config = test_world::take_config(world);
    let mut vault = test_world::take_vault(world);
    let oracle_registry = test_world::take_oracle_registry(world);
    let pyth = oracle_setup::take_pyth(world, oracles);
    let bs_spot = oracle_setup::take_bs_spot(world, oracles);
    let bs_forward = oracle_setup::take_bs_forward(world, oracles);
    let bs_svi = oracle_setup::take_bs_svi(world, oracles);

    let lifecycle_cap = registry.mint_lifecycle_cap(&config, &admin_cap, test_world::ctx(world));
    let proof = registry.generate_lifecycle_proof(&lifecycle_cap);
    let mut valuation = plp::start_pool_valuation(&mut config, &vault, proof);

    let mut markets = vector[];
    let mut i = 0;
    while (i < market_handles.length()) {
        markets.push_back(market_setup::take_market(world, &market_handles[i]));
        i = i + 1;
    };
    let mut j = 0;
    while (j < markets.length()) {
        plp::value_expiry(
            &mut valuation,
            &mut vault,
            &mut markets[j],
            &config,
            &oracle_registry,
            &pyth,
            &bs_spot,
            &bs_forward,
            &bs_svi,
            test_world::clock(resources),
        );
        j = j + 1;
    };
    let pool_nav = plp::finish_flush(
        valuation,
        &mut vault,
        &mut config,
        supply_budget,
        withdraw_budget,
        test_world::ctx(world),
    );

    while (!markets.is_empty()) {
        return_shared(markets.pop_back());
    };
    markets.destroy_empty();
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    lifecycle_cap.destroy();
    test_world::return_predict_admin_cap(world, admin_cap);
    pool_nav
}
