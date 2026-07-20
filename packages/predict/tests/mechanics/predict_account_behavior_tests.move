// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict account position indexing and empty-state projections.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__predict_account_tests;

use account::account;
use deepbook_predict::{account_setup, predict_account, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const FIRST_ORDER: u256 = 11;
const SECOND_ORDER: u256 = 22;
const ROOT_ORDER: u256 = 7;

#[test]
fun empty_account_projects_no_predict_state() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let wrapper = account_setup::take_account(&world, &handle);
    let account = wrapper.load_account();
    let expiry_id = test_world::registry_id(&world);
    assert!(!predict_account::has_position(account, expiry_id, FIRST_ORDER));
    assert_eq!(predict_account::expiry_position_count(account, expiry_id), 0);
    assert_eq!(predict_account::trading_fees_paid(account, expiry_id), 0);
    assert_eq!(predict_account::active_stake(account), 0);
    assert_eq!(predict_account::inactive_stake(account), 0);
    assert!(predict_account::builder_code_id(account).is_none());
    return_shared(wrapper);
    test_world::finish(world, resources);
}

#[test]
fun positions_are_scoped_and_round_trip_their_root() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let first_expiry = test_world::registry_id(&world);
    let second_expiry = test_world::config_id(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    predict_account::add_position(
        account,
        first_expiry,
        FIRST_ORDER,
        ROOT_ORDER,
        test_values::now_ms(),
        test_world::ctx(&mut world),
    );
    predict_account::add_position(
        account,
        second_expiry,
        SECOND_ORDER,
        SECOND_ORDER,
        test_values::now_ms(),
        test_world::ctx(&mut world),
    );
    assert!(predict_account::has_position(account, first_expiry, FIRST_ORDER));
    assert!(!predict_account::has_position(account, first_expiry, SECOND_ORDER));
    assert_eq!(predict_account::expiry_position_count(account, first_expiry), 1);
    assert_eq!(predict_account::expiry_position_count(account, second_expiry), 1);
    assert_eq!(
        predict_account::remove_position(
            account,
            first_expiry,
            FIRST_ORDER,
            test_world::ctx(&mut world),
        ),
        ROOT_ORDER,
    );
    assert!(!predict_account::has_position(account, first_expiry, FIRST_ORDER));
    assert_eq!(predict_account::expiry_position_count(account, first_expiry), 0);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
