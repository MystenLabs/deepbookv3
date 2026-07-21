// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid account creation and DUSDC funding prerequisites. Every
/// function operates in the caller's current transaction.
#[test_only]
module deepbook_predict::account_setup;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use deepbook_predict::test_world::{Self, OwnedResources, World};
use dusdc::dusdc::DUSDC;
use sui::{coin, test_scenario::return_shared};
use token::deep::DEEP;

public struct AccountHandle has copy, drop {
    id: ID,
}

public fun create_account(world: &mut World): AccountHandle {
    let mut registry = test_world::take_account_registry(world);
    let wrapper = registry.new(test_world::ctx(world));
    let id = wrapper.id();
    wrapper.share();
    return_shared(registry);
    AccountHandle { id }
}

public fun create_funded_account(
    world: &mut World,
    resources: &OwnedResources,
    amount: u64,
): AccountHandle {
    let mut registry = test_world::take_account_registry(world);
    let root = test_world::take_accumulator_root(world);
    let mut wrapper = registry.new(test_world::ctx(world));
    let id = wrapper.id();
    fund_wrapper(world, resources, &mut wrapper, &root, amount);
    wrapper.share();
    return_shared(root);
    return_shared(registry);
    AccountHandle { id }
}

public fun create_funded_trader(
    world: &mut World,
    resources: &OwnedResources,
    dusdc_amount: u64,
    deep_amount: u64,
): AccountHandle {
    let mut registry = test_world::take_account_registry(world);
    let root = test_world::take_accumulator_root(world);
    let mut wrapper = registry.new(test_world::ctx(world));
    let id = wrapper.id();
    fund_wrapper(world, resources, &mut wrapper, &root, dusdc_amount);
    let deep = coin::mint_for_testing<DEEP>(deep_amount, test_world::ctx(world));
    let auth = account::generate_auth(test_world::ctx(world));
    account::deposit_funds(
        &mut wrapper,
        auth,
        deep,
        &root,
        test_world::clock(resources),
    );
    wrapper.share();
    return_shared(root);
    return_shared(registry);
    AccountHandle { id }
}

public fun take_account(world: &World, handle: &AccountHandle): AccountWrapper {
    test_world::take_shared_by_id<AccountWrapper>(world, handle.id)
}

fun fund_wrapper(
    world: &mut World,
    resources: &OwnedResources,
    wrapper: &mut AccountWrapper,
    root: &sui::accumulator::AccumulatorRoot,
    amount: u64,
) {
    let funds = coin::mint_for_testing<DUSDC>(amount, test_world::ctx(world));
    let auth = account::generate_auth(test_world::ctx(world));
    account::deposit_funds(
        wrapper,
        auth,
        funds,
        root,
        test_world::clock(resources),
    );
}
