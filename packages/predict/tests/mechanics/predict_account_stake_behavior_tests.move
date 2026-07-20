// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Epoch-gated Predict account stake activation and removal.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__predict_account_stake_tests;

use account::account;
use deepbook_predict::{account_setup, predict_account, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

#[test]
fun inactive_stake_activates_next_epoch_and_all_stake_removes_exactly() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let initial_epoch = test_world::ctx(&mut world).epoch();
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    predict_account::add_inactive_stake(account, 50, test_world::ctx(&mut world));
    assert_eq!(predict_account::roll_active_stake(account, test_world::ctx(&mut world)), 0);
    assert_eq!(predict_account::active_stake(account), 0);
    assert_eq!(predict_account::inactive_stake(account), 50);
    return_shared(wrapper);

    test_world::next_tx_with_epoch(&mut world, test_values::alice(), initial_epoch + 1);
    let mut wrapper = account_setup::take_account(&world, &handle);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    assert_eq!(predict_account::roll_active_stake(account, test_world::ctx(&mut world)), 50);
    assert_eq!(predict_account::active_stake(account), 50);
    assert_eq!(predict_account::inactive_stake(account), 0);
    predict_account::add_inactive_stake(account, 20, test_world::ctx(&mut world));
    assert_eq!(predict_account::remove_all_stake(account, test_world::ctx(&mut world)), 70);
    assert_eq!(predict_account::active_stake(account), 0);
    assert_eq!(predict_account::inactive_stake(account), 0);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
