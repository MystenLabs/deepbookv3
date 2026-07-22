// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-cash policy defaults and setter endpoints.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__expiry_cash_config_tests;

use deepbook_predict::{config_constants, expiry_cash_config};
use std::unit_test::{assert_eq, destroy};

#[test]
fun defaults_and_rate_endpoints_are_exact() {
    let mut config = expiry_cash_config::new();
    assert_eq!(
        config.trading_loss_rebate_rate(),
        config_constants::default_trading_loss_rebate_rate!(),
    );
    config.set_trading_loss_rebate_rate(config_constants::min_trading_loss_rebate_rate!());
    assert_eq!(
        config.trading_loss_rebate_rate(),
        config_constants::min_trading_loss_rebate_rate!(),
    );
    config.set_trading_loss_rebate_rate(config_constants::max_trading_loss_rebate_rate!());
    assert_eq!(
        config.trading_loss_rebate_rate(),
        config_constants::max_trading_loss_rebate_rate!(),
    );
    destroy(config);
}
