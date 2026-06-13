// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Settlement-source priority tests for `MarketOracle`.
#[test_only]
module deepbook_predict::market_oracle_settlement_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource
};
use std::unit_test::assert_eq;
use sui::random::{Self, RandomGenerator};

const EXPIRY_MS: u64 = 200_000;
const SAMPLE_START_MS: u64 = 150_000;
const LIVE_PRICE: u64 = 100_000_000_000;
const PYTH_SAMPLE_PRICE: u64 = 111_000_000_000;
const PYTH_POST_EXPIRY_PRICE: u64 = 222_000_000_000;
const SECOND_PYTH_POST_EXPIRY_PRICE: u64 = 333_000_000_000;
const BLOCK_SCHOLES_FALLBACK_PRICE: u64 = 100_000_000_000;
const BLOCK_SCHOLES_POST_EXPIRY_PRICE: u64 = 130_000_000_000;
const SAMPLE_SERIES_BASE_PRICE: u64 = 100_000_000_000;
const SAME_PRICE_STEP: u64 = 0;
const SAMPLE_SERIES_STEP: u64 = 1_000_000_000;
const SEEDED_SAMPLED_AVERAGE_PRICE: u64 = 115_400_000_000;
const EQUAL_SAMPLE_PRICE: u64 = 123_000_000_000;
const POST_EXPIRY_SOURCE_TIMESTAMP_MS: u64 = 201_000;
const POST_EXPIRY_UPDATE_TIMESTAMP_MS: u64 = 202_000;
const SECOND_POST_EXPIRY_SOURCE_TIMESTAMP_MS: u64 = 202_500;
const SECOND_POST_EXPIRY_UPDATE_TIMESTAMP_MS: u64 = 203_000;
const SETTLEMENT_RANDOM_SEED: vector<u8> =
    x"0101010101010101010101010101010101010101010101010101010101010101";

#[test]
fun pyth_sample_average_wins_over_fresh_post_expiry_pyth() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (mut pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    record_pyth_samples(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        constants::min_settlement_samples!(),
        SAMPLE_SERIES_BASE_PRICE,
        SAMPLE_SERIES_STEP,
    );
    settle_with_pyth(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        PYTH_POST_EXPIRY_PRICE,
    );

    // Seeded Sui shuffle averages indices
    // [5, 20, 22, 14, 1, 28, 12, 9, 26, 15, 23, 24, 7, 4, 21].
    // Their stepped-price mean is 115_400_000_000.
    assert_eq!(oracle.settlement_price(), SEEDED_SAMPLED_AVERAGE_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

#[test]
fun pyth_fresh_post_expiry_price_wins_when_samples_below_minimum() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (mut pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    record_pyth_samples(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        constants::min_settlement_samples!() - 1,
        PYTH_SAMPLE_PRICE,
        SAME_PRICE_STEP,
    );
    settle_with_pyth(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        PYTH_POST_EXPIRY_PRICE,
    );

    assert_eq!(oracle.settlement_price(), PYTH_POST_EXPIRY_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

#[test]
fun block_scholes_sample_average_wins_over_fresh_post_expiry_block_scholes() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    record_block_scholes_samples(
        &mut fx,
        &config,
        &mut oracle,
        constants::min_settlement_samples!(),
        SAMPLE_SERIES_BASE_PRICE,
        SAMPLE_SERIES_STEP,
    );
    fx.set_clock_for_testing(POST_EXPIRY_UPDATE_TIMESTAMP_MS);
    fx.update_block_scholes_prices_for_testing(
        &config,
        &mut oracle,
        BLOCK_SCHOLES_POST_EXPIRY_PRICE,
        BLOCK_SCHOLES_POST_EXPIRY_PRICE,
        POST_EXPIRY_SOURCE_TIMESTAMP_MS,
    );
    settle_with_current_pyth(&fx, &config, &mut oracle, &pyth);

    assert_eq!(oracle.settlement_price(), SEEDED_SAMPLED_AVERAGE_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

#[test]
fun block_scholes_fresh_post_expiry_price_falls_back_when_pyth_unavailable() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (mut pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, LIVE_PRICE);
    fx.set_clock_for_testing(POST_EXPIRY_UPDATE_TIMESTAMP_MS);
    fx.update_block_scholes_prices_for_testing(
        &config,
        &mut oracle,
        BLOCK_SCHOLES_FALLBACK_PRICE,
        BLOCK_SCHOLES_FALLBACK_PRICE,
        POST_EXPIRY_SOURCE_TIMESTAMP_MS,
    );

    settle_with_current_pyth(&fx, &config, &mut oracle, &pyth);

    assert_eq!(oracle.settlement_price(), BLOCK_SCHOLES_FALLBACK_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

#[test]
fun settlement_without_any_fresh_candidate_is_no_op() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    fx.set_clock_for_testing(POST_EXPIRY_UPDATE_TIMESTAMP_MS);
    settle_with_current_pyth(&fx, &config, &mut oracle, &pyth);

    assert_eq!(oracle.is_settled(), false);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

#[test]
fun settled_oracle_ignores_later_settlement_attempts() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (mut pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    settle_with_pyth(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        PYTH_POST_EXPIRY_PRICE,
    );
    set_post_expiry_pyth(
        &mut fx,
        &mut pyth,
        SECOND_PYTH_POST_EXPIRY_PRICE,
        SECOND_POST_EXPIRY_SOURCE_TIMESTAMP_MS,
        SECOND_POST_EXPIRY_UPDATE_TIMESTAMP_MS,
    );
    settle_with_current_pyth(&fx, &config, &mut oracle, &pyth);

    assert_eq!(oracle.settlement_price(), PYTH_POST_EXPIRY_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

/// With exactly `min_settlement_samples` equal Pyth samples, the random-subset
/// mean is that value EXACTLY, independent of the shuffle (mean of equal values).
/// This pins the sampled-average path at the 30-sample threshold without depending
/// on the contract's shuffle output (unlike the stepped-price seeded tests).
#[test]
fun equal_pyth_samples_settle_to_exact_value() {
    let mut fx = helpers::setup_pool_with_pyth();
    let (expiry_id, oracle_id) = fx.create_expiry(EXPIRY_MS);
    let (mut pyth, vault, market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    record_pyth_samples(
        &mut fx,
        &config,
        &mut oracle,
        &mut pyth,
        constants::min_settlement_samples!(),
        EQUAL_SAMPLE_PRICE,
        SAME_PRICE_STEP,
    );
    settle_with_pyth(&mut fx, &config, &mut oracle, &mut pyth, PYTH_POST_EXPIRY_PRICE);

    // Mean of 15 (or any subset of) equal samples is the sample value itself.
    assert_eq!(oracle.settlement_price(), EQUAL_SAMPLE_PRICE);

    helpers::return_market(pyth, vault, market, oracle, config);
    fx.finish();
}

fun record_pyth_samples(
    fx: &mut helpers::Fixture,
    _config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    count: u64,
    base_spot: u64,
    spot_step: u64,
) {
    let mut i = 0;
    while (i < count) {
        let timestamp_ms = SAMPLE_START_MS + i;
        fx.set_clock_for_testing(timestamp_ms);
        let spot = base_spot + i * spot_step;
        pyth.set_state_for_testing(spot, timestamp_ms, timestamp_ms);
        oracle.record_pyth_settlement_observation(pyth, fx.clock());
        i = i + 1;
    }
}

fun record_block_scholes_samples(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    count: u64,
    base_spot: u64,
    spot_step: u64,
) {
    let mut i = 0;
    while (i < count) {
        let timestamp_ms = SAMPLE_START_MS + i;
        let spot = base_spot + i * spot_step;
        fx.set_clock_for_testing(timestamp_ms);
        fx.update_block_scholes_prices_for_testing(config, oracle, spot, spot, timestamp_ms);
        i = i + 1;
    }
}

fun settle_with_pyth(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    spot: u64,
) {
    set_post_expiry_pyth(
        fx,
        pyth,
        spot,
        POST_EXPIRY_SOURCE_TIMESTAMP_MS,
        POST_EXPIRY_UPDATE_TIMESTAMP_MS,
    );
    settle_with_current_pyth(fx, config, oracle, pyth);
}

fun set_post_expiry_pyth(
    fx: &mut helpers::Fixture,
    pyth: &mut PythSource,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    fx.set_clock_for_testing(update_timestamp_ms);
    pyth.set_state_for_testing(spot, source_timestamp_ms, update_timestamp_ms);
}

fun settle_with_current_pyth(
    fx: &helpers::Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &PythSource,
) {
    let mut generator = settlement_generator();
    oracle.settle_with_generator_for_testing(config, pyth, &mut generator, fx.clock());
}

fun settlement_generator(): RandomGenerator {
    random::new_generator_from_seed_for_testing(SETTLEMENT_RANDOM_SEED)
}
