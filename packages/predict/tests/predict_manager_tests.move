// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{market_key, predict_manager};
use sui::test_scenario;

#[test]
fun test_predict_manager_positions() {
    let user = @0xABC;
    let mut scenario = test_scenario::begin(user);
    
    let mut manager = predict_manager::new_test_manager(scenario.ctx());
    let oracle_id = @0x123.to_id();
    let expiry = 1000;
    let strike = 50000;
    let up_key = market_key::new(oracle_id, expiry, strike, true);
    let down_key = market_key::new(oracle_id, expiry, strike, false);

    // Initial state
    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 0 && up_locked == 0, 0);

    // Increase position
    manager.increase_position(up_key, 100);
    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 100 && up_locked == 0, 1);

    // Decrease position
    manager.decrease_position(up_key, 40);
    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 60 && up_locked == 0, 2);

    // Collateral lock
    manager.increase_position(down_key, 100);
    manager.lock_collateral(up_key, down_key, 50);

    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 10 && up_locked == 50, 3);

    let (down_free, down_locked) = manager.position(down_key);
    assert!(down_free == 50 && down_locked == 50, 4);

    let collateral_key = up_key.to_collateral();
    assert!(manager.collateral(collateral_key) == 50, 5);

    // Collateral unlock
    manager.unlock_collateral(up_key, down_key, 20);
    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 30 && up_locked == 30, 6);

    predict_manager::destroy_test_manager(manager);
    scenario.end();
}
