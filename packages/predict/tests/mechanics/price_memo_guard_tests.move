// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Missing finite-boundary guards for empty payout-range memo reads.
#[test_only]
module deepbook_predict::scope_mechanics__intent_guard__price_memo_tests;

use deepbook_predict::{constants, pricing};

const NEG_INF_TICK: u64 = 0;
const FINITE_TICK: u64 = 3;

#[test, expected_failure(abort_code = pricing::ETickNotInPriceMemo)]
fun missing_finite_lower_tick_aborts() {
    let memo = pricing::new_price_memo();
    memo.cached_range_price(FINITE_TICK, constants::pos_inf_tick!());
    abort 999
}

#[test, expected_failure(abort_code = pricing::ETickNotInPriceMemo)]
fun missing_finite_higher_tick_aborts() {
    let memo = pricing::new_price_memo();
    memo.cached_range_price(NEG_INF_TICK, FINITE_TICK);
    abort 999
}
