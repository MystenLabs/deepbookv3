// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_stake_tests;

use deepbook_predict::{predict_manager::{Self, PredictManager}, registry, test_constants};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, test_scenario as test};
use token::deep::DEEP;

const HUNDRED_K_DEEP: u64 = 100_000_000_000; // 100k DEEP raw (6 decimals)
const FIFTY_K_DEEP: u64 = 50_000_000_000;
const TWO_HUNDRED_K_DEEP: u64 = 200_000_000_000;
const ONE_YEAR_DAYS: u64 = 365;
const ONE_YEAR_MS: u64 = 31_536_000_000; // 365 * 86_400_000
const TWO_YEAR_DAYS: u64 = 730;
const TWO_YEAR_MS: u64 = 63_072_000_000; // 730 * 86_400_000
const OVER_MAX_LOCK_DAYS: u64 = 731; // one day past the 2-year cap
const SHORTER_LOCK_DAYS: u64 = 100;

// === Helpers ===

fun begin(): (test::Scenario, registry::Registry, registry::AdminCap, Clock, PredictManager) {
    let mut scenario = test::begin(test_constants::alice());
    let (mut reg, admin_cap) = registry::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let manager = registry::create_manager(&mut reg, scenario.ctx());
    (scenario, reg, admin_cap, clock, manager)
}

fun finish(
    scenario: test::Scenario,
    reg: registry::Registry,
    admin_cap: registry::AdminCap,
    clock: Clock,
    manager: PredictManager,
) {
    destroy(manager);
    destroy(admin_cap);
    destroy(clock);
    registry::destroy_registry_drop_for_testing(reg);
    scenario.end();
}

// === stake_deep ===

#[test]
fun stake_locks_deep_and_sets_live_power() {
    let (mut scenario, mut reg, admin_cap, clock, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, TWO_YEAR_DAYS, &clock, scenario.ctx());

    assert_eq!(manager.staked_deep(), HUNDRED_K_DEEP);
    assert_eq!(manager.stake_end_ms(), TWO_YEAR_MS);
    // Full two-year lock -> weight 1 -> power == staked.
    assert_eq!(manager.effective_power(&clock), HUNDRED_K_DEEP);

    finish(scenario, reg, admin_cap, clock, manager);
}

#[test]
fun top_up_adds_deep_and_raises_power() {
    let (mut scenario, mut reg, admin_cap, clock, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, first, TWO_YEAR_DAYS, &clock, scenario.ctx());
    assert_eq!(manager.effective_power(&clock), FIFTY_K_DEEP);

    // Add another 50k keeping the same two-year end.
    let second = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, second, TWO_YEAR_DAYS, &clock, scenario.ctx());

    assert_eq!(manager.staked_deep(), HUNDRED_K_DEEP);
    assert_eq!(manager.effective_power(&clock), HUNDRED_K_DEEP);

    finish(scenario, reg, admin_cap, clock, manager);
}

#[test]
fun extend_lock_with_zero_topup_raises_power() {
    let (mut scenario, mut reg, admin_cap, clock, mut manager) = begin();

    // 100k locked for one year of a two-year horizon -> weight 0.5, 0.25 -> 25k.
    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, ONE_YEAR_DAYS, &clock, scenario.ctx());
    assert_eq!(manager.effective_power(&clock), 25_000_000_000);

    // Extend to the full two-year horizon with no added DEEP -> full power.
    let zero = coin::zero<DEEP>(scenario.ctx());
    reg.stake_deep(&mut manager, zero, TWO_YEAR_DAYS, &clock, scenario.ctx());
    assert_eq!(manager.staked_deep(), HUNDRED_K_DEEP);
    assert_eq!(manager.effective_power(&clock), HUNDRED_K_DEEP);

    finish(scenario, reg, admin_cap, clock, manager);
}

#[test, expected_failure(abort_code = registry::EInvalidLockDays)]
fun stake_beyond_max_period_aborts() {
    let (mut scenario, mut reg, _admin_cap, clock, mut manager) = begin();

    // A lock past the 2-year cap is rejected.
    let deep = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, OVER_MAX_LOCK_DAYS, &clock, scenario.ctx());
    abort 999
}

#[test]
fun power_above_max_benefit_counts_higher() {
    let (mut scenario, mut reg, admin_cap, clock, mut manager) = begin();

    // Staking beyond 100k is allowed; power is uncapped (benefits cap by power).
    let deep = coin::mint_for_testing<DEEP>(TWO_HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, TWO_YEAR_DAYS, &clock, scenario.ctx());

    assert_eq!(manager.effective_power(&clock), TWO_HUNDRED_K_DEEP);

    finish(scenario, reg, admin_cap, clock, manager);
}

#[test, expected_failure(abort_code = registry::EInvalidLockDays)]
fun stake_zero_lock_days_aborts() {
    let (mut scenario, mut reg, _admin_cap, clock, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, 0, &clock, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = registry::EStakeLocked)]
fun stake_shortening_lock_aborts() {
    let (mut scenario, mut reg, _admin_cap, clock, mut manager) = begin();

    let first = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, first, ONE_YEAR_DAYS, &clock, scenario.ctx());

    // A shorter end than the current lock is rejected.
    let second = coin::mint_for_testing<DEEP>(FIFTY_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, second, SHORTER_LOCK_DAYS, &clock, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun stake_by_non_owner_aborts() {
    let (mut scenario, mut reg, _admin_cap, clock, mut manager) = begin();

    scenario.next_tx(test_constants::bob());
    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, ONE_YEAR_DAYS, &clock, scenario.ctx());
    abort 999
}

// === unstake_deep ===

#[test]
fun unstake_after_expiry_returns_deep_and_clears_state() {
    let (mut scenario, mut reg, admin_cap, mut clock, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, ONE_YEAR_DAYS, &clock, scenario.ctx());

    clock.set_for_testing(ONE_YEAR_MS);
    let returned = reg.unstake_deep(&mut manager, &clock, scenario.ctx());

    assert_eq!(returned.value(), HUNDRED_K_DEEP);
    assert_eq!(manager.staked_deep(), 0);
    assert_eq!(manager.stake_end_ms(), 0);
    assert_eq!(manager.effective_power(&clock), 0);

    destroy(returned);
    finish(scenario, reg, admin_cap, clock, manager);
}

#[test, expected_failure(abort_code = registry::EStakeLocked)]
fun unstake_before_expiry_aborts() {
    let (mut scenario, mut reg, _admin_cap, clock, mut manager) = begin();

    let deep = coin::mint_for_testing<DEEP>(HUNDRED_K_DEEP, scenario.ctx());
    reg.stake_deep(&mut manager, deep, ONE_YEAR_DAYS, &clock, scenario.ctx());

    // Lock still active (clock at 0 < end).
    let returned = reg.unstake_deep(&mut manager, &clock, scenario.ctx());
    destroy(returned);
    abort 999
}
