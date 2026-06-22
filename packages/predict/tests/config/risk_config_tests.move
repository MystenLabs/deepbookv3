// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation bounds for the trade liquidation budget. The value is stored on
/// `ProtocolConfig`; its bounds live in `config_constants` and are asserted by
/// the protocol_config setter.
#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::config_constants;

#[test]
fun trade_budget_accepts_endpoints() {
    config_constants::assert_trade_liquidation_budget(
        config_constants::min_trade_liquidation_budget!(),
    );
    config_constants::assert_trade_liquidation_budget(
        config_constants::max_trade_liquidation_budget!(),
    );
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun trade_budget_below_min_aborts() {
    config_constants::assert_trade_liquidation_budget(
        config_constants::min_trade_liquidation_budget!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun trade_budget_above_max_aborts() {
    config_constants::assert_trade_liquidation_budget(
        config_constants::max_trade_liquidation_budget!() + 1,
    );
    abort 999
}
