// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `snapshot_expiry_pricer_v2`: a market of one flush is marked at the instant
/// its Pyth Lazer price is stamped, at or before the flush's start and at most
/// the Block Scholes price freshness before it, from that price and the Block
/// Scholes inputs signed at exactly the same instant under the market's oracle
/// binding.
#[test_only]
module deepbook_predict::flush_v2_tests;

use deepbook_predict::{
    expiry_market,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle},
    plp,
    signed_data,
    test_constants
};
use deepbook_predict_math::{block_scholes, lazer_price};
use fixed_math::i64;
use std::unit_test::assert_eq;

const IDLE_SEED: u64 = 1_200_000_000_000;
const FLUSH_START_MS: u64 = 125_000;
const ONE_MS: u64 = 1;
const ONE_SECOND_MS: u64 = 1_000;
const US_PER_MS: u64 = 1_000;
const CHANNEL_50MS: u8 = 2;

/// A funded, empty live market with seeded feeds, and the clock at `FLUSH_START_MS`.
fun funded_market(): (Fixture, MarketBundle) {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(IDLE_SEED);
    let e = fx.create_expiry(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(e);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    fx.set_clock_for_testing(FLUSH_START_MS);
    (fx, market)
}

/// The oldest instant a flush started at `FLUSH_START_MS` accepts: the configured
/// Block Scholes price freshness before it.
fun oldest_instant(market: &MarketBundle): u64 {
    FLUSH_START_MS - helpers::config(market).pr_cfg().bs_age()
}

/// Snapshot, seal, and value the market from data stamped at `instant_ms`, and
/// return the flush's pool mark.
fun flush_at(mut fx: Fixture, mut market: MarketBundle, instant_ms: u64): u64 {
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (price, vol) = helpers::flush_data_at(&market, instant_ms);
    fx.snapshot_v2_bundle(&stage, &mut market, price, vol);
    helpers::seal_snapshot_bundle(stage, &mut market);
    assert!(helpers::market(&market).is_pending_valuation(helpers::config(&market)));
    fx.value_expiry_bundle(&mut market);
    let mark = fx.finish_flush_bundle(&mut market);
    helpers::return_market_bundle(market);
    fx.finish();
    mark
}

#[test]
fun the_flush_marks_at_its_own_start() {
    let (fx, market) = funded_market();
    // No orders: the market's NAV is the cash the pool sent it, so the pool mark is
    // the seed.
    assert_eq!(flush_at(fx, market, FLUSH_START_MS), IDLE_SEED);
}

#[test]
fun data_exactly_the_freshness_window_old_marks_the_flush() {
    let (fx, market) = funded_market();
    let instant = oldest_instant(&market);
    assert_eq!(flush_at(fx, market, instant), IDLE_SEED);
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun data_one_ms_older_than_the_window_aborts_the_snapshot() {
    let (fx, market) = funded_market();
    let instant = oldest_instant(&market) - ONE_MS;
    flush_at(fx, market, instant);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun data_stamped_after_the_flush_start_aborts_the_snapshot() {
    let (fx, market) = funded_market();
    flush_at(fx, market, FLUSH_START_MS + ONE_MS);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun a_price_on_another_channel_aborts_the_snapshot() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (_, vol) = helpers::flush_data_at(&market, FLUSH_START_MS);
    let instant_us = FLUSH_START_MS * US_PER_MS;
    let price = option::some(
        lazer_price::new_for_testing(
            test_constants::pyth_feed_id(),
            CHANNEL_50MS,
            instant_us,
            instant_us,
            test_constants::default_live_price(),
        ),
    );
    fx.snapshot_v2_bundle(&stage, &mut market, price, vol);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongVol)]
fun block_scholes_inputs_at_another_instant_abort_the_snapshot() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (price, _) = helpers::flush_data_at(&market, FLUSH_START_MS);
    // Block Scholes inputs one second before the price's instant.
    let (_, vol) = helpers::flush_data_at(&market, FLUSH_START_MS - ONE_SECOND_MS);
    fx.snapshot_v2_bundle(&stage, &mut market, price, vol);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongVol)]
fun block_scholes_inputs_under_another_model_abort_the_snapshot() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (price, vol) = helpers::flush_data_at(&market, FLUSH_START_MS);
    let vol = vol.destroy_some();
    let regime = block_scholes::new_vol_for_testing(
        test_constants::block_scholes_base_asset(),
        b"SVI_REGIME".to_string(),
        vol.svi_decimals(),
        vol.expiry_ms(),
        vol.value_ms(),
        vol.spot(),
        vol.forward(),
        vol.svi_ms(),
        vol.a_magnitude(),
        vol.a_is_negative(),
        vol.b(),
        vol.rho(),
        vol.m(),
        vol.sigma(),
    );
    fx.snapshot_v2_bundle(&stage, &mut market, price, option::some(regime));
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongVol)]
fun a_snapshot_without_block_scholes_inputs_aborts() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (price, _) = helpers::flush_data_at(&market, FLUSH_START_MS);
    fx.snapshot_v2_bundle(&stage, &mut market, price, option::none());
    abort 999
}

/// Inputs that leave the pricing envelope at the instant build no `Pricer`.
#[test, expected_failure(abort_code = expiry_market::EWrongVol)]
fun inputs_outside_the_pricing_envelope_abort_the_snapshot() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    let (price, vol) = helpers::flush_data_at(&market, FLUSH_START_MS);
    let vol = vol.destroy_some();
    // `rho` past 1 leaves `inputs_ok`.
    let bad = block_scholes::new_vol_for_testing(
        test_constants::block_scholes_base_asset(),
        vol.svi_model(),
        vol.svi_decimals(),
        vol.expiry_ms(),
        vol.value_ms(),
        vol.spot(),
        vol.forward(),
        vol.svi_ms(),
        vol.a_magnitude(),
        vol.a_is_negative(),
        vol.b(),
        i64::from_u64(2 * test_constants::float()),
        vol.m(),
        vol.sigma(),
    );
    fx.snapshot_v2_bundle(&stage, &mut market, price, option::some(bad));
    abort 999
}

#[test, expected_failure(abort_code = plp::EUseV2)]
fun snapshot_expiry_pricer_is_retired() {
    let (mut fx, mut market) = funded_market();
    let stage = fx.start_flush_unsnapshotted(&mut market);
    fx.snapshot_v1_bundle(&stage, &mut market);
    abort 999
}
