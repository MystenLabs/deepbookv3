// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_stake_tests;

use deepbook_predict::{predict_manager::{Self, PredictManager}, registry, test_constants};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario as test};
use token::deep::DEEP;

const FIFTY_K_DEEP: u64 = 50_000_000_000; // 50k DEEP raw (6 decimals)
const THIRTY_K_DEEP: u64 = 30_000_000_000;

// === Helpers ===

fun begin(): (test::Scenario, registry::Registry, registry::AdminCap, PredictManager) {
    let mut scenario = test::begin(test_constants::alice());
    let (mut reg, admin_cap) = registry::new_for_testing(scenario.ctx());
    let manager = registry::create_manager(&mut reg, scenario.ctx());
    (scenario, reg, admin_cap, manager)
}

fun finish(
    scenario: test::Scenario,
    reg: registry::Registry,
    admin_cap: registry::AdminCap,
    manager: PredictManager,
) {
    destroy(manager);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(reg);
    scenario.end();
}

// === stake_deep ===

#[test]
fun stake_adds_to_inactive() {
    let (mut scenario, mut reg, admin_cap, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, scenario.ctx());

    // Not active until the next epoch.
    assert_eq!(manager.inactive_stake(), FIFTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);

    finish(scenario, reg, admin_cap, manager);
}

#[test]
fun stake_activates_prior_inactive_next_epoch() {
    let (mut scenario, mut reg, admin_cap, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, first, scenario.ctx());

    // New epoch + a second stake: the first stake rolls into active, the new
    // one lands in inactive.
    scenario.next_epoch(test_constants::alice());
    let second = coin::mint_for_testing<DEEP>(THIRTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, second, scenario.ctx());

    assert_eq!(manager.active_stake(), FIFTY_K_DEEP);
    assert_eq!(manager.inactive_stake(), THIRTY_K_DEEP);

    finish(scenario, reg, admin_cap, manager);
}

// === unstake_deep ===

#[test]
fun unstake_returns_all_anytime_no_penalty() {
    let (mut scenario, mut reg, admin_cap, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, scenario.ctx());

    // Unstake immediately (same epoch, still inactive) — full amount, no penalty.
    let returned = reg.unstake_deep(&mut manager, scenario.ctx());
    assert_eq!(returned.value(), FIFTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(manager.inactive_stake(), 0);

    destroy(returned);
    finish(scenario, reg, admin_cap, manager);
}

#[test]
fun unstake_returns_active_and_inactive() {
    let (mut scenario, mut reg, admin_cap, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, first, scenario.ctx());
    scenario.next_epoch(test_constants::alice());
    let second = coin::mint_for_testing<DEEP>(THIRTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, second, scenario.ctx()); // 50k active, 30k inactive

    let returned = reg.unstake_deep(&mut manager, scenario.ctx());
    assert_eq!(returned.value(), FIFTY_K_DEEP + THIRTY_K_DEEP);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(manager.inactive_stake(), 0);

    destroy(returned);
    finish(scenario, reg, admin_cap, manager);
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun stake_by_non_owner_aborts() {
    let (mut scenario, mut reg, _admin_cap, mut manager) = begin();

    scenario.next_tx(test_constants::bob());
    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, scenario.ctx());
    abort 999
}
