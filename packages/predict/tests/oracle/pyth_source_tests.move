// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pyth_source_tests;

use deepbook_predict::{config_constants, pyth_source};
use std::unit_test::{assert_eq, destroy};

const HOUR_MS: u64 = 3_600_000;
const TWO_X: u64 = 2_000_000_000;

#[test]
fun defaults_disable_the_ramp() {
    let ctx = &mut tx_context::dummy();
    let source = pyth_source::new_for_testing(ctx);

    assert_eq!(source.expiry_fee_window_ms(), config_constants::default_expiry_fee_window_ms!());
    assert_eq!(
        source.expiry_fee_max_multiplier(),
        config_constants::default_expiry_fee_max_multiplier!(),
    );
    destroy(source);
}

#[test]
fun setter_updates_expiry_fee_params() {
    let ctx = &mut tx_context::dummy();
    let mut source = pyth_source::new_for_testing(ctx);

    source.set_expiry_fee_params(HOUR_MS, TWO_X);

    assert_eq!(source.expiry_fee_window_ms(), HOUR_MS);
    assert_eq!(source.expiry_fee_max_multiplier(), TWO_X);
    destroy(source);
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeWindowMs)]
fun window_above_max_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut source = pyth_source::new_for_testing(ctx);
    source.set_expiry_fee_params(config_constants::max_expiry_fee_window_ms!() + 1, TWO_X);

    abort
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun multiplier_below_min_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut source = pyth_source::new_for_testing(ctx);
    source.set_expiry_fee_params(HOUR_MS, config_constants::min_expiry_fee_max_multiplier!() - 1);

    abort
}
