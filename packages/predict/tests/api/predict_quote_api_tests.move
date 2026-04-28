// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
#[allow(unused_function)]
module deepbook_predict::predict_quote_api_tests;

use deepbook_predict::{
    market_key::MarketKey,
    oracle::OracleSVI,
    predict::{Self, Predict},
    range_key::RangeKey
};
use sui::clock::Clock;

fun compile_trade_price_and_fee_api(
    predict: &Predict,
    oracle: &OracleSVI,
    key: MarketKey,
    clock: &Clock,
) {
    let (fair_price, fee_rate): (u64, u64) = predict::trade_quote(predict, oracle, key, clock);
    assert!(fair_price == fair_price, 0);
    assert!(fee_rate == fee_rate, 0);
}

fun compile_range_trade_price_and_fee_api(
    predict: &Predict,
    oracle: &OracleSVI,
    key: RangeKey,
    clock: &Clock,
) {
    let (fair_price, fee_rate): (u64, u64) = predict::range_trade_quote(
        predict,
        oracle,
        key,
        clock,
    );
    assert!(fair_price == fair_price, 0);
    assert!(fee_rate == fee_rate, 0);
}
