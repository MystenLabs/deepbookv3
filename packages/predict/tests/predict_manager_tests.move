// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{market_key, predict_manager::{Self, PredictManager}};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, sui::SUI, test_scenario};

const ALICE: address = @0xA;
const BOB: address = @0xB;
const STRIKE: u64 = 50_000;
const EXPIRY: u64 = 1000;

fun dummy_oracle_id(ctx: &mut TxContext): ID {
    object::id_from_address(ctx.fresh_object_address())
}

fun setup(): test_scenario::Scenario {
    let mut scenario = test_scenario::begin(ALICE);
    { predict_manager::new(scenario.ctx()); };
    scenario.next_tx(ALICE);
    scenario
}

// ============================================================
// Construction
// ============================================================

#[test]
fun new_creates_manager_with_correct_owner() {
    let scenario = setup();
    let manager = scenario.take_shared<PredictManager>();
    assert_eq!(manager.owner(), ALICE);
    test_scenario::return_shared(manager);
    scenario.end();
}

// ============================================================
// Position tracking
// ============================================================

#[test]
fun position_returns_zero_for_unknown_key() {
    let mut scenario = setup();
    {
        let manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let (free, locked) = manager.position(key);
        assert_eq!(free, 0);
        assert_eq!(locked, 0);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun increase_position_adds_to_free() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(key, 100);

        let (free, locked) = manager.position(key);
        assert_eq!(free, 100);
        assert_eq!(locked, 0);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun increase_position_accumulates() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(key, 100);
        manager.increase_position(key, 250);

        let (free, locked) = manager.position(key);
        assert_eq!(free, 350);
        assert_eq!(locked, 0);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun decrease_position_subtracts_from_free() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(key, 300);
        manager.decrease_position(key, 120);

        let (free, locked) = manager.position(key);
        assert_eq!(free, 180);
        assert_eq!(locked, 0);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientPosition)]
fun decrease_position_aborts_unknown_key() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.decrease_position(key, 10);

        abort 999
    }
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun decrease_position_aborts_insufficient_free() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(key, 50);
        manager.decrease_position(key, 51);

        abort 999
    }
}

// ============================================================
// Collateral lock / release
// ============================================================

#[test]
fun lock_collateral_moves_free_to_locked() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 200);
        manager.lock_collateral(up_key, down_key, 80);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 120);
        assert_eq!(locked, 80);

        // Down key should be unaffected
        let (free_dn, locked_dn) = manager.position(down_key);
        assert_eq!(free_dn, 0);
        assert_eq!(locked_dn, 0);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientPosition)]
fun lock_collateral_aborts_unknown_key() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.lock_collateral(up_key, down_key, 10);

        abort 999
    }
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun lock_collateral_aborts_insufficient_free() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 50);
        manager.lock_collateral(up_key, down_key, 51);

        abort 999
    }
}

#[test]
fun release_collateral_moves_locked_to_free() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 200);
        manager.lock_collateral(up_key, down_key, 80);
        manager.release_collateral(up_key, down_key, 80);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 200);
        assert_eq!(locked, 0);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun release_partial_collateral() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 200);
        manager.lock_collateral(up_key, down_key, 100);
        manager.release_collateral(up_key, down_key, 40);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 140);
        assert_eq!(locked, 60);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_collateral_aborts_unknown_pair() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.release_collateral(up_key, down_key, 10);

        abort 999
    }
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_collateral_aborts_insufficient_locked() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 100);
        manager.lock_collateral(up_key, down_key, 50);
        manager.release_collateral(up_key, down_key, 51);

        abort 999
    }
}

#[test]
fun multiple_lock_release_cycles() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 500);

        // Lock 200
        manager.lock_collateral(up_key, down_key, 200);
        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 300);
        assert_eq!(locked, 200);

        // Release 100
        manager.release_collateral(up_key, down_key, 100);
        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 400);
        assert_eq!(locked, 100);

        // Lock another 150
        manager.lock_collateral(up_key, down_key, 150);
        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 250);
        assert_eq!(locked, 250);

        // Release all 250
        manager.release_collateral(up_key, down_key, 250);
        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 500);
        assert_eq!(locked, 0);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun different_collateral_pairs_tracked_independently() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id_1 = dummy_oracle_id(scenario.ctx());
        let oracle_id_2 = dummy_oracle_id(scenario.ctx());

        let key_a = market_key::up(oracle_id_1, EXPIRY, STRIKE);
        let key_b = market_key::down(oracle_id_1, EXPIRY, STRIKE);
        let key_c = market_key::up(oracle_id_2, EXPIRY + 1000, STRIKE + 10000);
        let key_d = market_key::down(oracle_id_2, EXPIRY + 1000, STRIKE + 10000);

        manager.increase_position(key_a, 300);
        manager.increase_position(key_c, 400);

        // Lock on pair (a, b)
        manager.lock_collateral(key_a, key_b, 100);
        // Lock on pair (c, d)
        manager.lock_collateral(key_c, key_d, 200);

        let (free_a, locked_a) = manager.position(key_a);
        assert_eq!(free_a, 200);
        assert_eq!(locked_a, 100);

        let (free_c, locked_c) = manager.position(key_c);
        assert_eq!(free_c, 200);
        assert_eq!(locked_c, 200);

        // Release pair (a, b) only
        manager.release_collateral(key_a, key_b, 100);
        let (free_a, locked_a) = manager.position(key_a);
        assert_eq!(free_a, 300);
        assert_eq!(locked_a, 0);

        // Pair (c, d) unchanged
        let (free_c, locked_c) = manager.position(key_c);
        assert_eq!(free_c, 200);
        assert_eq!(locked_c, 200);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

// ============================================================
// Deposit / Withdraw
// ============================================================

#[test]
fun deposit_adds_funds() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        manager.deposit(coin, scenario.ctx());
        assert_eq!(manager.balance<SUI>(), 1000);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun withdraw_removes_funds() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        manager.deposit(coin, scenario.ctx());

        let withdrawn = manager.withdraw<SUI>(400, scenario.ctx());
        assert_eq!(withdrawn.value(), 400);
        assert_eq!(manager.balance<SUI>(), 600);
        destroy(withdrawn);
        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInvalidOwner)]
fun deposit_aborts_if_not_owner() {
    let mut scenario = setup();
    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        manager.deposit(coin, scenario.ctx());

        abort 999
    }
}

#[test, expected_failure(abort_code = predict_manager::EInvalidOwner)]
fun withdraw_aborts_if_not_owner() {
    let mut scenario = setup();
    // Deposit as ALICE first
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        manager.deposit(coin, scenario.ctx());
        test_scenario::return_shared(manager);
    };
    // Try to withdraw as BOB
    scenario.next_tx(BOB);
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let _withdrawn = manager.withdraw<SUI>(100, scenario.ctx());

        abort 999
    }
}

// ============================================================
// Edge cases
// ============================================================

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun decrease_fails_when_all_free_is_locked() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 100);
        manager.lock_collateral(up_key, down_key, 100);

        // free is now 0, should fail
        manager.decrease_position(up_key, 1);

        abort 999
    }
}

#[test]
fun decrease_from_newly_added_free_after_lock() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 100);
        manager.lock_collateral(up_key, down_key, 100);

        // Add more free
        manager.increase_position(up_key, 75);

        // Decrease from newly added free
        manager.decrease_position(up_key, 50);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 25);
        assert_eq!(locked, 100);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun release_then_lock_again() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 200);
        manager.lock_collateral(up_key, down_key, 150);
        manager.release_collateral(up_key, down_key, 150);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 200);
        assert_eq!(locked, 0);

        // Lock again
        manager.lock_collateral(up_key, down_key, 100);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 100);
        assert_eq!(locked, 100);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun decrease_entire_free_position() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let key = market_key::up(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(key, 100);
        manager.decrease_position(key, 100);

        let (free, locked) = manager.position(key);
        assert_eq!(free, 0);
        assert_eq!(locked, 0);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}

#[test]
fun lock_entire_free_position() {
    let mut scenario = setup();
    {
        let mut manager = scenario.take_shared<PredictManager>();
        let oracle_id = dummy_oracle_id(scenario.ctx());
        let up_key = market_key::up(oracle_id, EXPIRY, STRIKE);
        let down_key = market_key::down(oracle_id, EXPIRY, STRIKE);

        manager.increase_position(up_key, 100);
        manager.lock_collateral(up_key, down_key, 100);

        let (free, locked) = manager.position(up_key);
        assert_eq!(free, 0);
        assert_eq!(locked, 100);

        test_scenario::return_shared(manager);
    };
    scenario.end();
}
