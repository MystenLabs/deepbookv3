// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation bounds for the trade liquidation budget. The value is stored on
/// `ProtocolConfig`; its bounds live in `config_constants` and are asserted by
/// the protocol_config setter.
#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::config_constants;
use std::unit_test::assert_eq;

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

/// Predict ships fill-or-kill: one attempt, so a limit miss refunds at the flush that
/// reaches it and no request can hold the queue head. The shipped value is asserted
/// against stored config state in `protocol_config_tests::new_config_ships_with_no_retry`;
/// here only the envelope is pinned.
#[test]
fun lp_request_attempts_accepts_endpoints() {
    config_constants::assert_lp_request_limit_flush_attempts(
        config_constants::min_lp_request_limit_flush_attempts!(),
    );
    config_constants::assert_lp_request_limit_flush_attempts(
        config_constants::max_lp_request_limit_flush_attempts!(),
    );
}

/// Zero attempts would refund a request the mark could actually have filled.
#[test, expected_failure(abort_code = config_constants::EInvalidLpRequestLimitFlushAttempts)]
fun lp_request_attempts_below_min_aborts() {
    config_constants::assert_lp_request_limit_flush_attempts(
        config_constants::min_lp_request_limit_flush_attempts!() - 1,
    );
    abort 999
}

/// The ceiling bounds how long one unfillable request can hold a queue, so an
/// operator cannot widen the blocking window past what RP-12 accounts for.
#[test, expected_failure(abort_code = config_constants::EInvalidLpRequestLimitFlushAttempts)]
fun lp_request_attempts_above_max_aborts() {
    config_constants::assert_lp_request_limit_flush_attempts(
        config_constants::max_lp_request_limit_flush_attempts!() + 1,
    );
    abort 999
}
