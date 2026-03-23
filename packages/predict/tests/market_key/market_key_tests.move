// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::{market_key, oracle};
use std::unit_test::{assert_eq, destroy};

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
        ctx,
    )
}

// === Construction: up ===

#[test]
fun up_creates_correct_key() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(1000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::up(oracle_id, 1000, 50_000_000_000);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), 1000);
    assert_eq!(market_key::strike(&key), 50_000_000_000);
    assert!(market_key::is_up(&key));
    assert!(!market_key::is_down(&key));

    destroy(oracle);
}

// === Construction: down ===

#[test]
fun down_creates_correct_key() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(2000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::down(oracle_id, 2000, 60_000_000_000);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), 2000);
    assert_eq!(market_key::strike(&key), 60_000_000_000);
    assert!(market_key::is_down(&key));
    assert!(!market_key::is_up(&key));

    destroy(oracle);
}

// === Construction: new with is_up=true ===

#[test]
fun new_with_is_up_true_matches_up() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(3000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key_up = market_key::up(oracle_id, 3000, 70_000_000_000);
    let key_new = market_key::new(oracle_id, 3000, 70_000_000_000, true);

    assert_eq!(key_up, key_new);

    destroy(oracle);
}

// === Construction: new with is_up=false ===

#[test]
fun new_with_is_up_false_matches_down() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(4000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key_down = market_key::down(oracle_id, 4000, 80_000_000_000);
    let key_new = market_key::new(oracle_id, 4000, 80_000_000_000, false);

    assert_eq!(key_down, key_new);

    destroy(oracle);
}

// === assert_matches_oracle: success ===

#[test]
fun assert_matches_oracle_succeeds_when_matching() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(5000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key = market_key::up(oracle_id, 5000, 50_000_000_000);
    market_key::assert_matches_oracle(&key, &oracle);

    destroy(oracle);
}

// === assert_matches_oracle: mismatched oracle_id ===

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
fun assert_matches_oracle_aborts_on_wrong_oracle_id() {
    let ctx = &mut tx_context::dummy();
    let oracle1 = create_oracle(5000, ctx);
    let oracle2 = create_oracle(5000, ctx);

    // Key references oracle1, but we pass oracle2
    let key = market_key::up(oracle::id(&oracle1), 5000, 50_000_000_000);
    market_key::assert_matches_oracle(&key, &oracle2);

    abort
}

// === assert_matches_oracle: mismatched expiry ===

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
fun assert_matches_oracle_aborts_on_wrong_expiry() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(5000, ctx);
    let oracle_id = oracle::id(&oracle);

    // Key has expiry 9999, oracle has 5000
    let key = market_key::up(oracle_id, 9999, 50_000_000_000);
    market_key::assert_matches_oracle(&key, &oracle);

    abort
}

// === Equality ===

#[test]
fun same_fields_are_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(1000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, 1000, 50_000_000_000);
    let key2 = market_key::up(oracle_id, 1000, 50_000_000_000);

    assert_eq!(key1, key2);

    destroy(oracle);
}

#[test]
fun different_strikes_are_not_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(1000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, 1000, 50_000_000_000);
    let key2 = market_key::up(oracle_id, 1000, 60_000_000_000);

    assert!(key1 != key2);

    destroy(oracle);
}

#[test]
fun different_directions_are_not_equal() {
    let ctx = &mut tx_context::dummy();
    let oracle = create_oracle(1000, ctx);
    let oracle_id = oracle::id(&oracle);

    let key1 = market_key::up(oracle_id, 1000, 50_000_000_000);
    let key2 = market_key::down(oracle_id, 1000, 50_000_000_000);

    assert!(key1 != key2);

    destroy(oracle);
}
