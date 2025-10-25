// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::trade_params_tests;

use deepbook::{constants, trade_params};
use std::unit_test::assert_eq;

#[test]
fun test_taker_fee_basic() {
    let taker_fee = 1_000_000; // 0.1%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    assert_eq!(params.taker_fee(), taker_fee);
    assert_eq!(params.maker_fee(), maker_fee);
    assert_eq!(params.stake_required(), stake_required);
}

#[test]
fun test_taker_fee_for_user_no_stake_no_volume() {
    let taker_fee = 2_000_000; // 0.2%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has no stake and no volume
    let active_stake = 0;
    let volume_in_deep = 0;

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get full taker fee
    assert_eq!(user_taker_fee, taker_fee);
}

#[test]
fun test_taker_fee_for_user_has_stake_no_volume() {
    let taker_fee = 2_000_000; // 0.2%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has stake but no volume
    let active_stake = 150 * constants::deep_unit();
    let volume_in_deep = 0;

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should still get full taker fee (needs both stake AND volume)
    assert_eq!(user_taker_fee, taker_fee);
}

#[test]
fun test_taker_fee_for_user_has_volume_no_stake() {
    let taker_fee = 2_000_000; // 0.2%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has volume but no stake
    let active_stake = 0;
    let volume_in_deep = 200 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should still get full taker fee (needs both stake AND volume)
    assert_eq!(user_taker_fee, taker_fee);
}

#[test]
fun test_taker_fee_for_user_has_both_stake_and_volume() {
    let taker_fee = 2_000_000; // 0.2%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has both stake and volume that meet requirements
    let active_stake = 150 * constants::deep_unit();
    let volume_in_deep = 200 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get reduced taker fee (halved)
    assert_eq!(user_taker_fee, taker_fee / 2);
}

#[test]
fun test_taker_fee_for_user_exactly_at_threshold() {
    let taker_fee = 1_000_000; // 0.1%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has exactly the required stake and volume
    let active_stake = 100 * constants::deep_unit();
    let volume_in_deep = 100 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get reduced taker fee (halved)
    assert_eq!(user_taker_fee, taker_fee / 2);
}

#[test]
fun test_taker_fee_for_user_stake_just_below_threshold() {
    let taker_fee = 1_000_000; // 0.1%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has stake just below threshold but volume above
    let active_stake = 99 * constants::deep_unit();
    let volume_in_deep = 200 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get full taker fee
    assert_eq!(user_taker_fee, taker_fee);
}

#[test]
fun test_taker_fee_for_user_volume_just_below_threshold() {
    let taker_fee = 1_000_000; // 0.1%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 100 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has volume just below threshold but stake above
    let active_stake = 200 * constants::deep_unit();
    let volume_in_deep = 99 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get full taker fee
    assert_eq!(user_taker_fee, taker_fee);
}

#[test]
fun test_taker_fee_for_user_with_high_stake_requirement() {
    let taker_fee = 4_000_000; // 0.4%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 10_000 * constants::deep_unit(); // 10,000 DEEP

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has high stake and volume
    let active_stake = 15_000 * constants::deep_unit();
    let volume_in_deep = 20_000 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get reduced taker fee (halved)
    assert_eq!(user_taker_fee, taker_fee / 2);
}

#[test]
fun test_taker_fee_for_user_odd_taker_fee() {
    let taker_fee = 3_500_000; // 0.35%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 50 * constants::deep_unit();

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User qualifies for reduced fee
    let active_stake = 100 * constants::deep_unit();
    let volume_in_deep = 100 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get reduced taker fee (halved)
    assert_eq!(user_taker_fee, 1_750_000);
}

#[test]
fun test_taker_fee_for_user_zero_stake_requirement() {
    let taker_fee = 1_000_000; // 0.1%
    let maker_fee = 500_000; // 0.05%
    let stake_required = 0; // No stake required

    let params = trade_params::new(taker_fee, maker_fee, stake_required);

    // User has no stake but has volume
    let active_stake = 0;
    let volume_in_deep = 100 * (constants::deep_unit() as u128);

    let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_deep);

    // Should get reduced taker fee since stake_required is 0
    assert_eq!(user_taker_fee, taker_fee / 2);
}
