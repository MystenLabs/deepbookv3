// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry rebate-reserve last-zero/first-positive floor rounding.
#[test_only]
module deepbook_predict::scope_mechanics__intent_rounding__expiry_cash_config_tests;

use deepbook_predict::expiry_cash_config;
use std::unit_test::{assert_eq, destroy};

const HALF_RATE: u64 = 500_000_000;
const ZERO_BASIS: u64 = 0;
const ONE_UNIT_BASIS: u64 = 1;
const TWO_UNIT_BASIS: u64 = 2;
const THREE_UNIT_BASIS: u64 = 3;
const ZERO_RESERVE: u64 = 0;
const ONE_UNIT_RESERVE: u64 = 1;

#[test]
fun half_rate_rounds_one_to_zero_and_two_to_one() {
    let mut config = expiry_cash_config::new();
    config.set_trading_loss_rebate_rate(HALF_RATE);
    assert_eq!(config.rebate_reserve_for_fee_basis(ZERO_BASIS), ZERO_RESERVE);
    assert_eq!(config.rebate_reserve_for_fee_basis(ONE_UNIT_BASIS), ZERO_RESERVE);
    assert_eq!(config.rebate_reserve_for_fee_basis(TWO_UNIT_BASIS), ONE_UNIT_RESERVE);
    assert_eq!(config.rebate_reserve_for_fee_basis(THREE_UNIT_BASIS), ONE_UNIT_RESERVE);
    destroy(config);
}
