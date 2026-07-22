// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict account trading-summary accounting.
#[test_only]
module deepbook_predict::scope_mechanics__intent_accounting__predict_account_tests;

use account::account;
use deepbook_predict::{account_setup, predict_account, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const ORDER_ID: u256 = 11;

#[test]
fun closed_summary_returns_fees_and_net_gross_profit_once() {
    let (mut world, resources) = test_world::new(
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
    predict_account::record_trading_fee_paid(account, expiry_id, 7, test_world::ctx(&mut world));
    predict_account::record_trading_fee_paid(account, expiry_id, 0, test_world::ctx(&mut world));
    predict_account::record_gross_paid_to_expiry(
        account,
        expiry_id,
        100,
        test_world::ctx(&mut world),
    );
    predict_account::record_gross_received_from_expiry(
        account,
        expiry_id,
        160,
        test_world::ctx(&mut world),
    );
    assert_eq!(predict_account::trading_fees_paid(account, expiry_id), 7);
    let _ = predict_account::remove_position(
        account,
        expiry_id,
        ORDER_ID,
        test_world::ctx(&mut world),
    );
    let summary = predict_account::resolve_expiry_summary(account, expiry_id);
    assert_eq!(predict_account::fees_paid(&summary), 7);
    assert_eq!(predict_account::gross_profit(&summary), 60);
    let empty = predict_account::resolve_expiry_summary(account, expiry_id);
    assert_eq!(predict_account::fees_paid(&empty), 0);
    assert_eq!(predict_account::gross_profit(&empty), 0);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
