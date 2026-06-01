// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_stake_tests;

use deepbook_predict::{
    admin,
    plp::{Self, PoolVault},
    predict_manager::{Self, PredictManager},
    registry,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario as test};
use token::deep::DEEP;

const FIFTY_K_DEEP: u64 = 50_000_000_000; // 50k DEEP raw (6 decimals)
const THIRTY_K_DEEP: u64 = 30_000_000_000;

// === Helpers ===

fun begin(): (test::Scenario, registry::Registry, admin::AdminCap, PoolVault, PredictManager) {
    let mut scenario = test::begin(test_constants::alice());
    plp::init_for_testing(scenario.ctx()); // shares a PoolVault
    let (mut reg, admin_cap) = registry::new_for_testing(scenario.ctx());
    let manager = registry::create_manager(&mut reg, scenario.ctx());
    scenario.next_tx(test_constants::alice());
    let vault = scenario.take_shared<PoolVault>();
    (scenario, reg, admin_cap, vault, manager)
}

fun finish(
    scenario: test::Scenario,
    reg: registry::Registry,
    admin_cap: admin::AdminCap,
    vault: PoolVault,
    manager: PredictManager,
) {
    destroy(manager);
    destroy(admin_cap);
    test::return_shared(vault);
    registry::destroy_registry_drop_for_testing(reg);
    scenario.end();
}

// === stake_deep ===

#[test]
fun stake_adds_to_inactive_and_vault_custody() {
    let (mut scenario, reg, admin_cap, mut vault, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, deep, scenario.ctx());

    // Not active until the next epoch; DEEP is custodied in the vault.
    assert_eq!(manager.inactive_stake(), FIFTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(vault.staked_deep(), FIFTY_K_DEEP);

    finish(scenario, reg, admin_cap, vault, manager);
}

#[test]
fun stake_activates_prior_inactive_next_epoch() {
    let (mut scenario, reg, admin_cap, mut vault, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, first, scenario.ctx());

    scenario.next_epoch(test_constants::alice());
    let second = coin::mint_for_testing<DEEP>(THIRTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, second, scenario.ctx());

    assert_eq!(manager.active_stake(), FIFTY_K_DEEP);
    assert_eq!(manager.inactive_stake(), THIRTY_K_DEEP);
    assert_eq!(vault.staked_deep(), FIFTY_K_DEEP + THIRTY_K_DEEP);

    finish(scenario, reg, admin_cap, vault, manager);
}

// === unstake_deep ===

#[test]
fun unstake_returns_all_anytime_no_penalty() {
    let (mut scenario, reg, admin_cap, mut vault, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, deep, scenario.ctx());

    // Unstake immediately (same epoch, still inactive) — full amount, no penalty.
    let returned = vault.unstake_deep(&mut manager, scenario.ctx());
    assert_eq!(returned.value(), FIFTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(manager.inactive_stake(), 0);
    assert_eq!(vault.staked_deep(), 0);

    destroy(returned);
    finish(scenario, reg, admin_cap, vault, manager);
}

#[test]
fun unstake_returns_active_and_inactive() {
    let (mut scenario, reg, admin_cap, mut vault, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, first, scenario.ctx());
    scenario.next_epoch(test_constants::alice());
    let second = coin::mint_for_testing<DEEP>(THIRTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, second, scenario.ctx()); // 50k active, 30k inactive

    let returned = vault.unstake_deep(&mut manager, scenario.ctx());
    assert_eq!(returned.value(), FIFTY_K_DEEP + THIRTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(manager.inactive_stake(), 0);

    destroy(returned);
    finish(scenario, reg, admin_cap, vault, manager);
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun stake_by_non_owner_aborts() {
    let (mut scenario, _reg, _admin_cap, mut vault, mut manager) = begin();

    scenario.next_tx(test_constants::bob());
    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    vault.stake_deep(&mut manager, deep, scenario.ctx());
    abort 999
}
