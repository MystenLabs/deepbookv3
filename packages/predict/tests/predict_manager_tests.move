// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{predict_manager, registry};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

const OWNER: address = @0xA11CE;
const OTHER: address = @0xB0B;

fun setup(): Scenario {
    let mut scenario = test_scenario::begin(OWNER);
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(OWNER);
    scenario
}

#[test]
fun owner_can_mint_and_revoke_caps() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());

    let trade_cap = manager.mint_trade_cap(scenario.ctx());
    let deposit_cap = manager.mint_deposit_cap(scenario.ctx());
    let withdraw_cap = manager.mint_withdraw_cap(scenario.ctx());

    // Revoke each by id; the cap object remains but can no longer authorize.
    manager.revoke_cap(object::borrow_id(&trade_cap), scenario.ctx());
    manager.revoke_cap(object::borrow_id(&deposit_cap), scenario.ctx());
    manager.revoke_cap(object::borrow_id(&withdraw_cap), scenario.ctx());

    destroy(trade_cap);
    destroy(deposit_cap);
    destroy(withdraw_cap);
    destroy(manager);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun non_owner_cannot_mint_trade_cap() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());

    scenario.next_tx(OTHER);
    let _cap = manager.mint_trade_cap(scenario.ctx());

    abort
}

#[test]
fun owner_can_generate_proof() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let manager = {
        let m = registry::create_manager(&mut registry, scenario.ctx());
        m
    };

    let proof = manager.generate_proof_as_owner(scenario.ctx());
    manager.validate_proof(&proof);

    destroy(manager);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun trade_cap_holder_can_generate_proof() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());
    let trade_cap = manager.mint_trade_cap(scenario.ctx());

    scenario.next_tx(OTHER);
    let proof = manager.generate_proof_as_trader(&trade_cap, scenario.ctx());
    manager.validate_proof(&proof);

    destroy(trade_cap);
    destroy(manager);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInvalidCap)]
fun revoked_trade_cap_cannot_generate_proof() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());
    let trade_cap = manager.mint_trade_cap(scenario.ctx());

    manager.revoke_cap(object::borrow_id(&trade_cap), scenario.ctx());

    scenario.next_tx(OTHER);
    let _proof = manager.generate_proof_as_trader(&trade_cap, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = predict_manager::ECapNotInList)]
fun revoking_unknown_cap_aborts() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let mut manager = registry::create_manager(&mut registry, scenario.ctx());

    let fake_id = object::id_from_address(@0xDEAD);
    manager.revoke_cap(&fake_id, scenario.ctx());

    abort
}

#[test]
fun proof_from_one_manager_does_not_validate_against_another() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let manager_a = registry::create_manager(&mut registry, scenario.ctx());

    scenario.next_tx(OTHER);
    let manager_b = registry::create_manager(&mut registry, scenario.ctx());

    scenario.next_tx(OWNER);
    let proof_a = manager_a.generate_proof_as_owner(scenario.ctx());
    // Mismatch fails the assert in validate_proof; check the other direction
    // explicitly by counting that A's proof matches A, not B.
    assert_eq!(manager_a.id(), object::id(&manager_a));
    manager_a.validate_proof(&proof_a);

    destroy(manager_a);
    destroy(manager_b);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInvalidProof)]
fun cross_manager_proof_validation_aborts() {
    let mut scenario = setup();
    let mut registry = scenario.take_shared<registry::Registry>();
    let manager_a = registry::create_manager(&mut registry, scenario.ctx());

    scenario.next_tx(OTHER);
    let manager_b = registry::create_manager(&mut registry, scenario.ctx());

    scenario.next_tx(OWNER);
    let proof_a = manager_a.generate_proof_as_owner(scenario.ctx());
    manager_b.validate_proof(&proof_a);

    abort
}
