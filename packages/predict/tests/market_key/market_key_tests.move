// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::{constants::float_scaling as float, market_key, oracle};
use std::unit_test::{assert_eq, destroy};

const STRIKE_50K: u64 = 50_000_000_000;
const STRIKE_60K: u64 = 60_000_000_000;
const STRIKE_70K: u64 = 70_000_000_000;
const STRIKE_80K: u64 = 80_000_000_000;

const EXPIRY_1: u64 = 1000;
const EXPIRY_2: u64 = 2000;
const EXPIRY_3: u64 = 3000;
const EXPIRY_4: u64 = 4000;
const EXPIRY_5: u64 = 5000;

fun grid_min_strike(): u64 { 50 * float!() }

fun grid_tick_size(): u64 { 1_000_000 }

// === Helpers ===

fun dummy_svi(): oracle::SVIParams {
    oracle::new_svi_params(0, 0, 0, false, 0, false, 0)
}

fun dummy_prices(): oracle::PriceData {
    oracle::new_price_data(0, 0)
}

fun create_oracle(expiry: u64, ctx: &mut TxContext): oracle::OracleSVI {
    oracle::create_test_oracle(
        b"BTC".to_string(),
        dummy_svi(),
        dummy_prices(),
        0,
        expiry,
        0,
        grid_min_strike(),
        grid_tick_size(),
        ctx,
    )
}

// === Construction: up ===

#[test]
fun up_creates_correct_key() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_1, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), EXPIRY_1);
    assert_eq!(market_key::strike(&key), STRIKE_50K);
    assert!(market_key::is_up(&key));
    assert!(!market_key::is_down(&key));

    destroy(oracle);
}

// === Construction: down ===

#[test]
fun down_creates_correct_key() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_2, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::down(oracle_id, EXPIRY_2, STRIKE_60K);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), EXPIRY_2);
    assert_eq!(market_key::strike(&key), STRIKE_60K);
    assert!(market_key::is_down(&key));
    assert!(!market_key::is_up(&key));

    destroy(oracle);
}

// === Construction: new with is_up=true ===

#[test]
fun new_with_is_up_true_matches_up() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_3, ctx);
    let oracle_id = oracle::id(&oracle);

    let key_up = market_key::up(oracle_id, EXPIRY_3, STRIKE_70K);
    let key_new = market_key::new(oracle_id, EXPIRY_3, STRIKE_70K, true);

    assert_eq!(key_up, key_new);

    destroy(oracle);
}

// === Construction: new with is_up=false ===

#[test]
fun new_with_is_up_false_matches_down() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_4, ctx);
    let oracle_id = oracle::id(&oracle);

    let key_down = market_key::down(oracle_id, EXPIRY_4, STRIKE_80K);
    let key_new = market_key::new(oracle_id, EXPIRY_4, STRIKE_80K, false);

    assert_eq!(key_down, key_new);

    destroy(oracle);
}

// === assert_matches_oracle: success ===

#[test]
fun assert_matches_oracle_succeeds_when_matching() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_5, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::up(oracle_id, EXPIRY_5, STRIKE_50K);
    market_key::assert_matches_oracle(&key, &oracle);

    destroy(oracle);
}

// === assert_matches_oracle: mismatched oracle_id ===

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
fun assert_matches_oracle_aborts_on_wrong_oracle_id() {
    let ctx = &mut tx_context::dummy();
    let oracle1 = create_oracle(EXPIRY_5, ctx);
    let oracle2 = create_oracle(EXPIRY_5, ctx);

    // Key references oracle1, but we pass oracle2
    let key = market_key::up(oracle::id(&oracle1), EXPIRY_5, STRIKE_50K);
    market_key::assert_matches_oracle(&key, &oracle2);

    abort
}

// === assert_matches_oracle: mismatched expiry ===

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
fun assert_matches_oracle_aborts_on_wrong_expiry() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_5, ctx);
    let oracle_id = oracle::id(&oracle);

    // Key has expiry 9999, oracle has EXPIRY_5
    let key = market_key::up(oracle_id, 9999, STRIKE_50K);
    market_key::assert_matches_oracle(&key, &oracle);

    abort
}

// === Equality ===

#[test]
fun same_fields_are_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_1, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);

    assert_eq!(key1, key2);

    destroy(oracle);
}

#[test]
fun different_strikes_are_not_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_1, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::up(oracle_id, EXPIRY_1, STRIKE_60K);

    assert!(key1 != key2);

    destroy(oracle);
}

#[test]
fun different_directions_are_not_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(EXPIRY_1, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::down(oracle_id, EXPIRY_1, STRIKE_50K);

    assert!(key1 != key2);

    destroy(oracle);
}
