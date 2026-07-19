// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-cash rebate-rate upper-bound guard.
#[test_only]
module deepbook_predict::mechanics_expiry_cash_config_guard_tests;

use deepbook_predict::{config_constants, expiry_cash_config};

const RAW_UNIT: u64 = 1;

#[test, expected_failure(abort_code = config_constants::EInvalidTradingLossRebateRate)]
fun rebate_rate_one_above_full_aborts() {
    expiry_cash_config::new().set_trading_loss_rebate_rate(
        config_constants::max_trading_loss_rebate_rate!() + RAW_UNIT,
    );
    abort 999
}
