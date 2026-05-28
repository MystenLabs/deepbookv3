// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::fee_config_tests;

use deepbook_predict::{config_constants, constants::float_scaling as float, fee_config};
use std::unit_test::{assert_eq, destroy};

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = fee_config::new();

    assert_eq!(config.lp_fee_share(), config_constants::default_lp_fee_share!());
    assert_eq!(config.protocol_fee_share(), config_constants::default_protocol_fee_share!());
    assert_eq!(config.insurance_fee_share(), config_constants::default_insurance_fee_share!());
    assert_eq!(
        config.trading_loss_rebate_rate(),
        config_constants::default_trading_loss_rebate_rate!(),
    );
    // Defaults must sum to 1.0 — otherwise `set_fee_shares` would reject the
    // default state itself.
    assert_eq!(
        config.lp_fee_share() + config.protocol_fee_share() + config.insurance_fee_share(),
        float!(),
    );
    destroy(config);
}

// === set_fee_shares ===

#[test]
fun set_fee_shares_updates_all_three_when_sum_is_one() {
    let mut config = fee_config::new();
    let lp = 700_000_000;
    let proto = 200_000_000;
    let insurance = 100_000_000;

    config.set_fee_shares(lp, proto, insurance);

    assert_eq!(config.lp_fee_share(), lp);
    assert_eq!(config.protocol_fee_share(), proto);
    assert_eq!(config.insurance_fee_share(), insurance);
    destroy(config);
}

#[test]
fun set_fee_shares_accepts_full_lp_only() {
    // Boundary: lp = 1.0, others = 0. Per-share max is `float!()`, so this is
    // the maximum allowed lp value that still satisfies the sum check.
    let mut config = fee_config::new();
    config.set_fee_shares(float!(), 0, 0);
    assert_eq!(config.lp_fee_share(), float!());
    assert_eq!(config.protocol_fee_share(), 0);
    assert_eq!(config.insurance_fee_share(), 0);
    destroy(config);
}

#[test, expected_failure(abort_code = fee_config::EInvalidFeeSplit)]
fun set_fee_shares_sum_below_one_aborts() {
    let mut config = fee_config::new();
    config.set_fee_shares(400_000_000, 200_000_000, 200_000_000); // sum = 0.8
    abort 999
}

#[test, expected_failure(abort_code = fee_config::EInvalidFeeSplit)]
fun set_fee_shares_sum_above_one_aborts() {
    let mut config = fee_config::new();
    config.set_fee_shares(500_000_000, 300_000_000, 300_000_000); // sum = 1.1
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidLpFeeShare)]
fun set_fee_shares_lp_above_float_aborts() {
    // Per-share max is `float!()`. Caught by `assert_lp_fee_share` before the
    // sum check, so the test fixes a code-specific abort even though the sum
    // would also be wrong.
    let mut config = fee_config::new();
    config.set_fee_shares(float!() + 1, 0, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolFeeShare)]
fun set_fee_shares_protocol_above_float_aborts() {
    let mut config = fee_config::new();
    config.set_fee_shares(0, float!() + 1, 0);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidInsuranceFeeShare)]
fun set_fee_shares_insurance_above_float_aborts() {
    let mut config = fee_config::new();
    config.set_fee_shares(0, 0, float!() + 1);
    abort 999
}

// === set_trading_loss_rebate_rate ===

#[test]
fun set_trading_loss_rebate_rate_updates_value() {
    let mut config = fee_config::new();
    config.set_trading_loss_rebate_rate(100_000_000); // 10%
    assert_eq!(config.trading_loss_rebate_rate(), 100_000_000);
    destroy(config);
}

#[test]
fun set_trading_loss_rebate_rate_accepts_boundaries() {
    let mut config = fee_config::new();
    config.set_trading_loss_rebate_rate(0);
    assert_eq!(config.trading_loss_rebate_rate(), 0);
    config.set_trading_loss_rebate_rate(float!());
    assert_eq!(config.trading_loss_rebate_rate(), float!());
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradingLossRebateRate)]
fun set_trading_loss_rebate_rate_above_float_aborts() {
    let mut config = fee_config::new();
    config.set_trading_loss_rebate_rate(float!() + 1);
    abort 999
}
