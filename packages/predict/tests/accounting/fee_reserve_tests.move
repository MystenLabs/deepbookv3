// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::fee_reserve_tests;

use deepbook_predict::{constants, fee_reserve};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{balance, coin};

const PREDICT_ID: address = @0x42;
const EVEN_FEE: u64 = 100;
const ROUNDED_FEE: u64 = 101;
const CUSTOM_LP_SHARE: u64 = 700_000_000;
const CUSTOM_PROTOCOL_SHARE: u64 = 100_000_000;
const CUSTOM_INSURANCE_SHARE: u64 = 200_000_000;
const INVALID_PROTOCOL_SHARE: u64 = 300_000_000;

#[test]
fun new_starts_with_default_fee_shares() {
    let reserve = fee_reserve::new();

    assert_eq!(reserve.lp_fee_share(), constants::default_lp_fee_share!());
    assert_eq!(reserve.protocol_fee_share(), constants::default_protocol_fee_share!());
    assert_eq!(reserve.insurance_fee_share(), constants::default_insurance_fee_share!());

    reserve.destroy_empty_for_testing();
}

#[test]
fun accrue_fee_splits_sixty_twenty_twenty() {
    let ctx = &mut tx_context::dummy();
    let mut reserve = fee_reserve::new();
    let fee = coin::mint_for_testing<DUSDC>(EVEN_FEE, ctx).into_balance();

    let lp_fee = reserve.accrue_fee(fee, object::id_from_address(PREDICT_ID));

    // 100 fee units -> 60 LP, 20 protocol, 20 insurance.
    assert_eq!(lp_fee.value(), 60);
    assert_eq!(reserve.protocol_asset_balance(), 20);
    assert_eq!(reserve.insurance_asset_balance(), 20);
    assert_eq!(reserve.total_fees_accrued(), 100);
    assert_eq!(reserve.lp_fees_accrued(), 60);
    assert_eq!(reserve.protocol_fees_accrued(), 20);
    assert_eq!(reserve.insurance_fees_accrued(), 20);

    lp_fee.into_coin(ctx).burn_for_testing();
    reserve.drain_protocol_for_testing().into_coin(ctx).burn_for_testing();
    reserve.drain_insurance_for_testing().into_coin(ctx).burn_for_testing();
    reserve.destroy_empty_for_testing();
}

#[test]
fun set_fee_shares_changes_future_fee_split() {
    let ctx = &mut tx_context::dummy();
    let mut reserve = fee_reserve::new();
    reserve.set_fee_shares(
        CUSTOM_LP_SHARE,
        CUSTOM_PROTOCOL_SHARE,
        CUSTOM_INSURANCE_SHARE,
    );
    let fee = coin::mint_for_testing<DUSDC>(EVEN_FEE, ctx).into_balance();

    let lp_fee = reserve.accrue_fee(fee, object::id_from_address(PREDICT_ID));

    // 100 fee units at 70/10/20 -> 70 LP, 10 protocol, 20 insurance.
    assert_eq!(lp_fee.value(), 70);
    assert_eq!(reserve.protocol_asset_balance(), 10);
    assert_eq!(reserve.insurance_asset_balance(), 20);
    assert_eq!(reserve.total_fees_accrued(), 100);
    assert_eq!(reserve.lp_fees_accrued(), 70);
    assert_eq!(reserve.protocol_fees_accrued(), 10);
    assert_eq!(reserve.insurance_fees_accrued(), 20);

    lp_fee.into_coin(ctx).burn_for_testing();
    reserve.drain_protocol_for_testing().into_coin(ctx).burn_for_testing();
    reserve.drain_insurance_for_testing().into_coin(ctx).burn_for_testing();
    reserve.destroy_empty_for_testing();
}

#[test, expected_failure(abort_code = fee_reserve::EInvalidFeeSplit)]
fun set_fee_shares_rejects_sum_above_one() {
    let mut reserve = fee_reserve::new();

    reserve.set_fee_shares(
        CUSTOM_LP_SHARE,
        INVALID_PROTOCOL_SHARE,
        CUSTOM_INSURANCE_SHARE,
    );
    abort 999
}

#[test]
fun accrue_fee_assigns_rounding_dust_to_lp() {
    let ctx = &mut tx_context::dummy();
    let mut reserve = fee_reserve::new();
    let fee = coin::mint_for_testing<DUSDC>(ROUNDED_FEE, ctx).into_balance();

    let lp_fee = reserve.accrue_fee(fee, object::id_from_address(PREDICT_ID));

    // 20% of 101 rounds down to 20 for protocol and 20 for insurance;
    // the one unit of dust remains in the LP share.
    assert_eq!(lp_fee.value(), 61);
    assert_eq!(reserve.protocol_asset_balance(), 20);
    assert_eq!(reserve.insurance_asset_balance(), 20);
    assert_eq!(reserve.total_fees_accrued(), 101);
    assert_eq!(reserve.lp_fees_accrued(), 61);
    assert_eq!(reserve.protocol_fees_accrued(), 20);
    assert_eq!(reserve.insurance_fees_accrued(), 20);

    lp_fee.into_coin(ctx).burn_for_testing();
    reserve.drain_protocol_for_testing().into_coin(ctx).burn_for_testing();
    reserve.drain_insurance_for_testing().into_coin(ctx).burn_for_testing();
    reserve.destroy_empty_for_testing();
}

#[test]
fun accrue_zero_fee_does_not_update_counters() {
    let ctx = &mut tx_context::dummy();
    let mut reserve = fee_reserve::new();
    let fee = balance::zero<DUSDC>();

    let lp_fee = reserve.accrue_fee(fee, object::id_from_address(PREDICT_ID));

    assert_eq!(lp_fee.value(), 0);
    assert_eq!(reserve.protocol_asset_balance(), 0);
    assert_eq!(reserve.insurance_asset_balance(), 0);
    assert_eq!(reserve.total_fees_accrued(), 0);
    assert_eq!(reserve.lp_fees_accrued(), 0);
    assert_eq!(reserve.protocol_fees_accrued(), 0);
    assert_eq!(reserve.insurance_fees_accrued(), 0);

    lp_fee.into_coin(ctx).burn_for_testing();
    reserve.destroy_empty_for_testing();
}
