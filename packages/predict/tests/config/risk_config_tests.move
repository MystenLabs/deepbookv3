// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation bounds for two `ProtocolConfig` scalars: the trade liquidation budget
/// and the LP request attempt count. Both values are stored on `ProtocolConfig`; their
/// bounds live in `config_constants` and are asserted by the protocol_config setters.
#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::config_constants;
use std::unit_test::assert_eq;

/// The shipped `lp_request_limit_flush_attempts` envelope, written out by hand so a
/// change to either bound has to be made here too: one attempt is fill-or-kill, and
/// three is the widest head-of-line window RP-12 accounts for.
const MIN_LP_REQUEST_ATTEMPTS: u64 = 1;
const MAX_LP_REQUEST_ATTEMPTS: u64 = 3;

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
    assert_eq!(config_constants::min_lp_request_limit_flush_attempts!(), MIN_LP_REQUEST_ATTEMPTS);
    assert_eq!(config_constants::max_lp_request_limit_flush_attempts!(), MAX_LP_REQUEST_ATTEMPTS);

    config_constants::assert_lp_request_limit_flush_attempts(MIN_LP_REQUEST_ATTEMPTS);
    config_constants::assert_lp_request_limit_flush_attempts(MAX_LP_REQUEST_ATTEMPTS);
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

#[test]
fun max_lp_pool_value_accepts_endpoints() {
    config_constants::assert_max_lp_pool_value(config_constants::min_max_lp_pool_value!());
    config_constants::assert_max_lp_pool_value(config_constants::max_max_lp_pool_value!());
}

/// The floor is the genesis lock plus one minimum supply — the smallest cap that
/// still leaves a minimally-bootstrapped pool able to admit a deposit. A cap at the
/// lock itself would leave zero headroom forever, which is what this rejects.
/// 10 DUSDC genesis lock + 10 DUSDC minimum supply = 20 DUSDC, hand-derived from the
/// two protocol floors rather than from the expression under test.
#[test]
fun max_lp_pool_value_floor_leaves_room_for_one_minimum_supply() {
    assert_eq!(config_constants::min_max_lp_pool_value!(), 20_000_000);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxLpPoolValue)]
fun max_lp_pool_value_below_floor_aborts() {
    config_constants::assert_max_lp_pool_value(config_constants::min_max_lp_pool_value!() - 1);
    abort 999
}
