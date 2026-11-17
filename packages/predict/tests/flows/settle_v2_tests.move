// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `try_settle_v2`: settlement from the signed observation at exactly expiry under
/// the market's oracle binding. The Pyth Lazer price is primary from expiry, and a Block
/// Scholes spot stamped at expiry settles only once the fallback grace has passed.
/// Anything else leaves the market unsettled and retryable.
#[test_only]
module deepbook_predict::settle_v2_tests;

use deepbook_predict::{
    config_events::MarketSettled,
    constants,
    expiry_market,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle},
    signed_data,
    test_constants,
    test_helpers
};
use deepbook_predict_math::{block_scholes, lazer_price::{Self, LazerPrice}};
use std::unit_test::assert_eq;
use sui::event;

const US_PER_MS: u64 = 1_000;
const ONE_MS: u64 = 1;
const TICK_200_MS: u64 = 200;
const CHANNEL_50MS: u8 = 2;
const OTHER_FEED_ID: u32 = 2;
/// `constants::max_settlement_carry_ms!()`.
const MAX_CARRY_MS: u64 = 2_000;
/// Two positive settlement prices at 1e9.
const PYTH_PRICE: u64 = 101_000_000_000;
const BS_PRICE: u64 = 99_000_000_000;
const SVI_DECIMALS: u8 = 9;

fun expiry(): u64 { test_constants::default_expiry_ms() }

fun settle_at(clock_ms: u64): (Fixture, MarketBundle) {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(expiry());
    fx.set_clock_for_testing(clock_ms);
    fx.scenario_mut().next_tx(test_constants::admin());
    let market = fx.take_market_bundle(expiry_id);
    (fx, market)
}

fun try_settle(
    fx: &Fixture,
    market: &mut MarketBundle,
    price: Option<LazerPrice>,
    spot: Option<block_scholes::BsSpot>,
): bool {
    fx.try_settle_v2_bundle(market, price, spot)
}

fun finish(fx: Fixture, market: MarketBundle) {
    helpers::return_market_bundle(market);
    fx.finish();
}

fun bs_spot(source_ms: u64, spot: u64): block_scholes::BsSpot {
    block_scholes::new_spot_for_testing(test_constants::block_scholes_base_asset(), source_ms, spot)
}

fun price_with(feed_id: u32, channel: u8, envelope_ms: u64, carry_ms: u64): LazerPrice {
    lazer_price::new_for_testing(
        feed_id,
        channel,
        envelope_ms * US_PER_MS,
        (envelope_ms - carry_ms) * US_PER_MS,
        PYTH_PRICE,
    )
}

#[test]
fun pyth_at_expiry_settles_and_reports_its_source() {
    let (fx, mut market) = settle_at(expiry());
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(signed_data::lazer_at(expiry(), PYTH_PRICE)),
            option::none(),
        ),
    );
    assert_eq!(helpers::market(&market).settlement_price(), PYTH_PRICE);
    let settled = event::events_by_type<MarketSettled>();
    assert_eq!(settled.length(), 1);
    finish(fx, market);
}

#[test]
fun settlement_is_first_valid_wins_and_idempotent() {
    let (fx, mut market) = settle_at(expiry());
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(signed_data::lazer_at(expiry(), PYTH_PRICE)),
            option::none(),
        ),
    );
    // A later call with another price, or with nothing, changes nothing.
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(signed_data::lazer_at(expiry(), BS_PRICE)),
            option::none(),
        ),
    );
    assert!(try_settle(&fx, &mut market, option::none(), option::none()));
    assert_eq!(helpers::market(&market).settlement_price(), PYTH_PRICE);
    finish(fx, market);
}

#[test]
fun nothing_settles_before_expiry() {
    let (fx, mut market) = settle_at(expiry() - ONE_MS);
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(signed_data::lazer_at(expiry(), PYTH_PRICE)),
            option::none(),
        ),
    );
    assert!(!helpers::market(&market).is_settled());
    finish(fx, market);
}

#[test]
fun a_price_off_the_binding_or_off_expiry_leaves_the_market_retryable() {
    let (fx, mut market) = settle_at(expiry() + constants::settlement_fallback_grace_ms!());
    let feed = test_constants::pyth_feed_id();
    let channel = test_helpers::binding_channel();
    // Another feed, another channel, the next tick, and a carry past 2 s.
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(price_with(OTHER_FEED_ID, channel, expiry(), 0)),
            option::none(),
        ),
    );
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(price_with(feed, CHANNEL_50MS, expiry(), 0)),
            option::none(),
        ),
    );
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(price_with(feed, channel, expiry() + TICK_200_MS, 0)),
            option::none(),
        ),
    );
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(price_with(feed, channel, expiry(), MAX_CARRY_MS + 1)),
            option::none(),
        ),
    );
    assert!(!helpers::market(&market).is_settled());
    // A carry of exactly 2 s settles.
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(price_with(feed, channel, expiry(), MAX_CARRY_MS)),
            option::none(),
        ),
    );
    assert_eq!(helpers::market(&market).settlement_price(), PYTH_PRICE);
    finish(fx, market);
}

#[test]
fun block_scholes_settles_only_once_the_grace_has_passed() {
    let (mut fx, mut market) = settle_at(
        expiry() + constants::settlement_fallback_grace_ms!() - ONE_MS,
    );
    assert!(
        !try_settle(&fx, &mut market, option::none(), option::some(bs_spot(expiry(), BS_PRICE))),
    );
    assert!(!helpers::market(&market).is_settled());
    fx.set_clock_for_testing(expiry() + constants::settlement_fallback_grace_ms!());
    assert!(
        try_settle(&fx, &mut market, option::none(), option::some(bs_spot(expiry(), BS_PRICE))),
    );
    assert_eq!(helpers::market(&market).settlement_price(), BS_PRICE);
    finish(fx, market);
}

#[test]
fun block_scholes_off_the_binding_or_off_expiry_does_not_settle() {
    let (fx, mut market) = settle_at(expiry() + constants::settlement_fallback_grace_ms!());
    let foreign = block_scholes::new_spot_for_testing(
        test_constants::foreign_block_scholes_base_asset(),
        expiry(),
        BS_PRICE,
    );
    assert!(!try_settle(&fx, &mut market, option::none(), option::some(foreign)));
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::none(),
            option::some(bs_spot(expiry() - ONE_MS, BS_PRICE)),
        ),
    );
    assert!(!helpers::market(&market).is_settled());
    finish(fx, market);
}

#[test]
fun pyth_wins_over_block_scholes_after_the_grace() {
    let (fx, mut market) = settle_at(expiry() + constants::settlement_fallback_grace_ms!());
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(signed_data::lazer_at(expiry(), PYTH_PRICE)),
            option::some(bs_spot(expiry(), BS_PRICE)),
        ),
    );
    assert_eq!(helpers::market(&market).settlement_price(), PYTH_PRICE);
    finish(fx, market);
}

/// After the admin moves the binding to another feed, only that feed's price settles.
#[test]
fun a_new_binding_settles_from_its_own_feed() {
    let (fx, mut market) = settle_at(expiry());
    helpers::config_mut(&mut market).set_oracle_binding(
        fx.admin_cap(),
        test_constants::propbook_underlying_id(),
        OTHER_FEED_ID,
        test_helpers::binding_channel(),
        test_constants::block_scholes_base_asset(),
        test_helpers::binding_svi_model(),
        SVI_DECIMALS,
        fx.clock(),
    );
    let channel = test_helpers::binding_channel();
    assert!(
        !try_settle(
            &fx,
            &mut market,
            option::some(price_with(test_constants::pyth_feed_id(), channel, expiry(), 0)),
            option::none(),
        ),
    );
    assert!(
        try_settle(
            &fx,
            &mut market,
            option::some(price_with(OTHER_FEED_ID, channel, expiry(), 0)),
            option::none(),
        ),
    );
    assert_eq!(helpers::market(&market).settlement_price(), PYTH_PRICE);
    finish(fx, market);
}

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun try_settle_is_retired() {
    let (mut fx, mut market) = settle_at(expiry());
    fx.insert_exact_settlement_spot_bundle(&mut market, PYTH_PRICE);
    fx.try_settle_v1_bundle(&mut market);
    abort 999
}
