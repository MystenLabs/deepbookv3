// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict account position and summary guards.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__predict_account_tests;

use account::account;
use deepbook_predict::{account_setup, predict_account, test_values, test_world};

const ORDER_ID: u256 = 11;
const ROOT_ORDER: u256 = 7;

#[test, expected_failure(abort_code = predict_account::EPositionAlreadyExists)]
fun duplicate_position_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let expiry_id = test_world::registry_id(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    predict_account::add_position(
        account,
        expiry_id,
        ORDER_ID,
        ROOT_ORDER,
        test_values::now_ms(),
        test_world::ctx(&mut world),
    );
    predict_account::add_position(
        account,
        expiry_id,
        ORDER_ID,
        ROOT_ORDER,
        test_values::now_ms(),
        test_world::ctx(&mut world),
    );
    abort 999
}

#[test, expected_failure(abort_code = predict_account::EPositionNotFound)]
fun removing_unknown_position_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    let _ = predict_account::remove_position(
        account,
        test_world::registry_id(&world),
        ORDER_ID,
        test_world::ctx(&mut world),
    );
    abort 999
}

#[test, expected_failure(abort_code = predict_account::EExpirySummaryHasOpenPositions)]
fun resolving_summary_with_open_position_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let expiry_id = test_world::registry_id(&world);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    let account = wrapper.load_account_mut(auth);
    predict_account::add_position(
        account,
        expiry_id,
        ORDER_ID,
        ORDER_ID,
        test_values::now_ms(),
        test_world::ctx(&mut world),
    );
    let _ = predict_account::resolve_expiry_summary(account, expiry_id);
    abort 999
}
