// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid pool funding prerequisites for trading tests. Every
/// function operates in the caller's current transaction.
#[test_only]
module deepbook_predict::pool_setup;

use deepbook_predict::{
    market_setup::{Self, MarketHandle},
    test_world::{Self, OwnedResources, World}
};
use dusdc::dusdc::DUSDC;
use sui::{coin, test_scenario::return_shared};

public fun fund_market(
    world: &mut World,
    resources: &OwnedResources,
    market_handle: &MarketHandle,
    capital_amount: u64,
) {
    let mut vault = test_world::take_vault(world);
    let mut market = market_setup::take_market(world, market_handle);
    let config = test_world::take_config(world);
    let capital = coin::mint_for_testing<DUSDC>(capital_amount, test_world::ctx(world));
    let admin_cap = test_world::take_predict_admin_cap(world);
    vault.lock_capital(&config, &admin_cap, capital);
    test_world::return_predict_admin_cap(world, admin_cap);
    vault.rebalance_expiry_cash(
        &mut market,
        &config,
        test_world::clock(resources),
    );
    return_shared(config);
    return_shared(market);
    return_shared(vault);
}
