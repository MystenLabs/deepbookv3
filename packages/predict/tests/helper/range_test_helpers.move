// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-valid flat-variance feed for finite-range trade tests. Both
/// boundaries at ticks 90, 100 and 110 remain inside mint probability bounds.
#[test_only]
module deepbook_predict::range_test_helpers;

use deepbook_predict::{flow_test_helpers::{Fixture, MarketBundle}, test_constants};

const RANGE_VARIANCE: u64 = 40_000_000;
const ONE_MS: u64 = 1;

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
