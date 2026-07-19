// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Empty-cache infinity sentinels for payout-range memo reads.
#[test_only]
module deepbook_predict::scope_mechanics__intent_boundary__price_memo_tests;

use deepbook_predict::{constants, pricing};
use fixed_math::math;
use std::unit_test::assert_eq;

const NEG_INF_TICK: u64 = 0;
const ZERO_PRICE: u64 = 0;

#[test]
fun empty_memo_prices_the_full_sentinel_range_at_one() {
    let memo = pricing::new_price_memo();

    assert_eq!(
        memo.cached_range_price(NEG_INF_TICK, constants::pos_inf_tick!()),
        math::float_scaling!(),
    );
    assert_eq!(memo.cached_range_price(NEG_INF_TICK, NEG_INF_TICK), ZERO_PRICE);
    assert_eq!(
        memo.cached_range_price(constants::pos_inf_tick!(), constants::pos_inf_tick!()),
        ZERO_PRICE,
    );
}
