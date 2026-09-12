// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid flat-variance feed for finite-range trade tests. Both
/// boundaries at ticks 90, 100 and 110 remain inside mint probability bounds.
#[test_only]
module deepbook_predict::range_test_helpers;

use deepbook_predict::{
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle},
    pricing::RangePrice,
    range_codec::strike_for_testing as strike,
    test_constants
};

const RANGE_VARIANCE: u64 = 40_000_000;
const ONE_MS: u64 = 1;

public fun range(lower: u64, higher: u64): RangePrice {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    prepare_range(&mut fx, &mut market);
    let pricer = fx.load_pricer_bundle(&market);
    let price = pricer.range_price(strike(lower), strike(higher));
    helpers::return_market_bundle(market);
    fx.finish();
    price
}

public fun prepare_range(fx: &mut Fixture, market: &mut MarketBundle) {
    let timestamp_ms = fx.clock().timestamp_ms() + ONE_MS;
    fx.set_clock_for_testing(timestamp_ms);
    fx.seed_bs_surface_with_svi_bundle(
        market,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        RANGE_VARIANCE,
        false,
        0,
        test_constants::default_svi_sigma(),
        0,
        false,
        0,
        false,
        timestamp_ms,
    );
}
