// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module venue::vault_tests;

use account::{
    account::{Self, AccountWrapper},
    account_registry::AccountRegistry,
};
use std::unit_test::assert_eq;
use sui::{coin::{Self, Coin}, test_scenario::{Self as test, return_shared, return_to_address}};
use venue::{
    admin::AdminCap,
    deployer_registry::DeployerRegistry,
    deployer_vault::{Self, Vault, VaultDeposit},
    world::{Self, USDC},
};

#[test]
fun two_depositors_match_the_ledger() {
    let (mut scenario, _) = world::start();
    let alice = deposit(&mut scenario, world::alice(), 1000);
    let first = snapshot(&mut scenario);
    assert_eq!(first.equity, 1000);
    assert_eq!(first.shares, 1000);

    account_loss(&mut scenario, 40, 100);
    let after_fee = snapshot(&mut scenario);
    assert_eq!(after_fee.index, 18_000_000);
    assert_quote(&mut scenario, &alice, 1018, 0);

    account_loss(&mut scenario, 200, 0);
    let after_loss = snapshot(&mut scenario);
    assert_eq!(after_loss.equity, 800);
    assert_quote(&mut scenario, &alice, 818, 0);

    let bob = deposit(&mut scenario, world::bob(), 800);
    let after_bob = snapshot(&mut scenario);
    assert_eq!(after_bob.shares, 2000);

    account_gain(&mut scenario, 500, 100);
    let after_gain = snapshot(&mut scenario);
    assert_eq!(after_gain.equity, 2100);
    assert_eq!(after_gain.index, 33_000_000);
    assert_quote(&mut scenario, &alice, 1073, 10);
    assert_quote(&mut scenario, &bob, 1015, 50);

    withdraw(&mut scenario, world::alice(), alice);
    withdraw(&mut scenario, world::bob(), bob);
    let end = snapshot(&mut scenario);
    assert_eq!(end.cash, 240);
    assert_eq!(drain_fee(&scenario), 172);
    scenario.end();
}

#[test]
fun withdrawal_cut_is_read_live() {
    let (mut scenario, _) = world::start();
    let alice = deposit(&mut scenario, world::alice(), 1000);
    account_gain(&mut scenario, 500, 0);
    assert_quote(&mut scenario, &alice, 1400, 100);

    scenario.next_tx(world::admin());
    let cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let vault = world::vault(&scenario);
    let deployer_id = vault.deployer_id();
    return_shared(vault);
    registry.update(
        &cap,
        deployer_id,
        vector[],
        vector[],
        10_000_000_000_000,
        vector[],
        world::fee(),
        7000,
        0,
        0,
        1000,
        option::none(),
    );
    return_to_address(world::admin(), cap);
    return_shared(registry);

    assert_quote(&mut scenario, &alice, 1500, 0);
    withdraw(&mut scenario, world::alice(), alice);
    scenario.end();
}

fun deposit(scenario: &mut sui::test_scenario::Scenario, owner: address, amount: u64): VaultDeposit<USDC> {
    scenario.next_tx(owner);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(scenario, &accounts, owner);
    let mut vault = world::vault(scenario);
    let registry = scenario.take_shared<DeployerRegistry>();
    world::fund(&mut wrapper, amount, scenario.ctx());
    vault.deposit(&registry, &accounts, &mut wrapper, amount, scenario.ctx());
    return_shared(accounts);
    return_shared(vault);
    return_shared(registry);
    return_shared(wrapper);
    scenario.next_tx(owner);
    scenario.take_from_sender<VaultDeposit<USDC>>()
}

fun withdraw(scenario: &mut sui::test_scenario::Scenario, owner: address, receipt: VaultDeposit<USDC>) {
    scenario.next_tx(owner);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(scenario, &accounts, owner);
    let mut vault = world::vault(scenario);
    let registry = scenario.take_shared<DeployerRegistry>();
    let (paid, _) = vault.quote(&registry, &receipt);
    vault.withdraw(&registry, &accounts, &mut wrapper, receipt, scenario.ctx());
    let coin = pull(&mut wrapper, paid, scenario.ctx());
    assert_eq!(coin.burn_for_testing(), paid);
    return_shared(accounts);
    return_shared(vault);
    return_shared(registry);
    return_shared(wrapper);
}

fun account_loss(scenario: &mut sui::test_scenario::Scenario, loss: u64, fee: u64) {
    apply(scenario, loss, 0, 0, fee);
}

fun account_gain(scenario: &mut sui::test_scenario::Scenario, gain: u64, fee: u64) {
    apply(scenario, 0, gain, gain, fee);
}

fun apply(scenario: &mut sui::test_scenario::Scenario, loss: u64, gain: u64, gain_cash: u64, fee: u64) {
    scenario.next_tx(world::admin());
    let mut vault = world::vault(scenario);
    let registry = scenario.take_shared<DeployerRegistry>();
    vault.account_result(
        &registry,
        loss,
        gain,
        7000,
        coin::mint_for_testing<USDC>(gain_cash, scenario.ctx()).into_balance(),
        coin::mint_for_testing<USDC>(fee, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );
    return_shared(vault);
    return_shared(registry);
}

public struct Snap has drop {
    equity: u64,
    shares: u64,
    index: u128,
    cash: u64,
}

fun snapshot(scenario: &mut sui::test_scenario::Scenario): Snap {
    scenario.next_tx(world::admin());
    let vault = world::vault(scenario);
    let state = Snap {
        equity: vault.equity(),
        shares: vault.total_shares(),
        index: vault.fee_index(),
        cash: vault.cash(),
    };
    return_shared(vault);
    state
}

fun assert_quote(
    scenario: &mut sui::test_scenario::Scenario,
    receipt: &VaultDeposit<USDC>,
    lp: u64,
    wallet: u64,
) {
    scenario.next_tx(world::admin());
    let vault = world::vault(scenario);
    let registry = scenario.take_shared<DeployerRegistry>();
    let (got_lp, got_wallet) = vault.quote(&registry, receipt);
    assert_eq!(got_lp, lp);
    assert_eq!(got_wallet, wallet);
    return_shared(vault);
    return_shared(registry);
}

fun pull(wrapper: &mut AccountWrapper, amount: u64, ctx: &mut TxContext): Coin<USDC> {
    let auth = account::generate_auth(ctx);
    wrapper.load_account_mut(auth).withdraw(amount, ctx)
}

fun drain_fee(scenario: &sui::test_scenario::Scenario): u64 {
    let mut total = 0;
    while (test::has_most_recent_for_address<Coin<USDC>>(world::fee())) {
        let coin = scenario.take_from_address<Coin<USDC>>(world::fee());
        total = total + coin.burn_for_testing();
    };
    total
}
