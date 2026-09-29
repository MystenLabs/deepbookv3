// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module venue::world;

use account::{
    account::{Self, AccountWrapper},
    account_registry::{Self, AccountRegistry},
};
use sui::{clock::{Self, Clock}, coin, test_scenario::{Self as test, Scenario, return_shared, return_to_address}};
use venue::{
    admin::AdminCap,
    deployer_registry::{Self, DeployerRegistry},
    deployer_vault::{Self, Vault},
    market_type,
};

public struct USDC has drop {}

const ADMIN: address = @0xAD;
const SYNC: address = @0x51C;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const FEE: address = @0xFEE;

public fun admin(): address { ADMIN }
public fun sync(): address { SYNC }
public fun alice(): address { ALICE }
public fun bob(): address { BOB }
public fun fee(): address { FEE }

public fun start(): (Scenario, ID) {
    let mut scenario = test::begin(ADMIN);
    scenario.next_tx(ADMIN);
    account_registry::init_for_testing(scenario.ctx());
    deployer_registry::init_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    clock.share_for_testing();

    scenario.next_tx(ADMIN);
    let cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let accounts = scenario.take_shared<AccountRegistry>();
    let type_id = market_type::create(&mut registry, &cap, b"index", scenario.ctx());
    let _deployer_id = deployer_vault::admit<USDC>(
        &mut registry,
        &cap,
        SYNC,
        vector[type_id],
        vector[],
        10_000_000_000_000,
        vector[],
        FEE,
        7000,
        2000,
        0,
        1000,
        option::none(),
        scenario.ctx(),
    );
    return_to_address(ADMIN, cap);
    return_shared(registry);
    return_shared(accounts);

    scenario.next_tx(ALICE);
    let mut accounts = scenario.take_shared<AccountRegistry>();
    let alice = accounts.new(scenario.ctx());
    alice.share();
    return_shared(accounts);

    scenario.next_tx(BOB);
    let mut accounts = scenario.take_shared<AccountRegistry>();
    let bob = accounts.new(scenario.ctx());
    bob.share();
    return_shared(accounts);

    scenario.next_tx(ADMIN);
    (scenario, type_id)
}

public fun fund(wrapper: &mut AccountWrapper, amount: u64, ctx: &mut TxContext) {
    let auth = account::generate_auth(ctx);
    wrapper.load_account_mut(auth).deposit(coin::mint_for_testing<USDC>(amount, ctx));
}

public fun wrapper(scenario: &Scenario, accounts: &AccountRegistry, owner: address): AccountWrapper {
    let id = accounts.derived_wrapper_address(owner).to_id();
    scenario.take_shared_by_id<AccountWrapper>(id)
}

public fun clock(scenario: &Scenario): Clock {
    scenario.take_shared<Clock>()
}

public fun vault(scenario: &Scenario): Vault<USDC> {
    scenario.take_shared<Vault<USDC>>()
}
