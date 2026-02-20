// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::{market_key, oracle};
use std::unit_test::{assert_eq, destroy};

public struct BTC has drop {}

// === Helpers ===

fun test_oracle_id(ctx: &mut TxContext): (ID, oracle::OracleSVI<BTC>) {
    let svi = oracle::new_svi_params(
        40_000_000,
        100_000_000,
        300_000_000,
        true,
        0,
        false,
        100_000_000,
    );
    let prices = oracle::new_price_data(100_000_000_000_000, 100_500_000_000_000);
    let expiry_ms = 1_000_000_000 + 604_800_000;
    let oracle = oracle::create_test_oracle<BTC>(
        svi,
        prices,
        50_000_000,
        expiry_ms,
        1_000_000_000,
        ctx,
    );
    let id = oracle.id();
    (id, oracle)
}

// === Constructor Tests ===

#[test]
fun up_creates_up_key() {
    let id = object::id_from_address(@0x1);
    let key = market_key::up(id, 1000, 50000);
    assert!(key.is_up());
    assert!(!key.is_down());
    assert_eq!(key.oracle_id(), id);
    assert_eq!(key.expiry(), 1000);
    assert_eq!(key.strike(), 50000);
}

#[test]
fun down_creates_down_key() {
    let id = object::id_from_address(@0x1);
    let key = market_key::down(id, 2000, 60000);
    assert!(key.is_down());
    assert!(!key.is_up());
    assert_eq!(key.oracle_id(), id);
    assert_eq!(key.expiry(), 2000);
    assert_eq!(key.strike(), 60000);
}

#[test]
fun new_with_true_creates_up() {
    let id = object::id_from_address(@0x1);
    let key = market_key::new(id, 1000, 50000, true);
    assert!(key.is_up());
}

#[test]
fun new_with_false_creates_down() {
    let id = object::id_from_address(@0x1);
    let key = market_key::new(id, 1000, 50000, false);
    assert!(key.is_down());
}

// === Equality Tests ===

#[test]
fun same_params_are_equal() {
    let id = object::id_from_address(@0x1);
    let a = market_key::up(id, 1000, 50000);
    let b = market_key::up(id, 1000, 50000);
    assert_eq!(a, b);
}

#[test]
fun different_direction_not_equal() {
    let id = object::id_from_address(@0x1);
    let up = market_key::up(id, 1000, 50000);
    let down = market_key::down(id, 1000, 50000);
    assert!(up != down);
}

#[test]
fun different_strike_not_equal() {
    let id = object::id_from_address(@0x1);
    let a = market_key::up(id, 1000, 50000);
    let b = market_key::up(id, 1000, 60000);
    assert!(a != b);
}

#[test]
fun different_expiry_not_equal() {
    let id = object::id_from_address(@0x1);
    let a = market_key::up(id, 1000, 50000);
    let b = market_key::up(id, 2000, 50000);
    assert!(a != b);
}

#[test]
fun different_oracle_not_equal() {
    let id1 = object::id_from_address(@0x1);
    let id2 = object::id_from_address(@0x2);
    let a = market_key::up(id1, 1000, 50000);
    let b = market_key::up(id2, 1000, 50000);
    assert!(a != b);
}

#[test]
fun new_matches_up_constructor() {
    let id = object::id_from_address(@0x1);
    let from_up = market_key::up(id, 1000, 50000);
    let from_new = market_key::new(id, 1000, 50000, true);
    assert_eq!(from_up, from_new);
}

#[test]
fun new_matches_down_constructor() {
    let id = object::id_from_address(@0x1);
    let from_down = market_key::down(id, 1000, 50000);
    let from_new = market_key::new(id, 1000, 50000, false);
    assert_eq!(from_down, from_new);
}

// === assert_matches_oracle Tests ===

#[test]
fun assert_matches_oracle_passes() {
    let ctx = &mut tx_context::dummy();
    let (id, oracle) = test_oracle_id(ctx);
    let expiry = oracle.expiry();
    let key = market_key::up(id, expiry, 100_000_000_000_000);
    key.assert_matches_oracle(&oracle);
    destroy(oracle);
}

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
fun assert_matches_oracle_wrong_id_aborts() {
    let ctx = &mut tx_context::dummy();
    let (_id, oracle) = test_oracle_id(ctx);
    let wrong_id = object::id_from_address(@0xDEAD);
    let key = market_key::up(wrong_id, oracle.expiry(), 100_000_000_000_000);
    key.assert_matches_oracle(&oracle);

    abort
}

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
fun assert_matches_oracle_wrong_expiry_aborts() {
    let ctx = &mut tx_context::dummy();
    let (id, oracle) = test_oracle_id(ctx);
    let key = market_key::up(id, oracle.expiry() + 1, 100_000_000_000_000);
    key.assert_matches_oracle(&oracle);

    abort
}

#[test]
fun assert_matches_oracle_any_strike_passes() {
    let ctx = &mut tx_context::dummy();
    let (id, oracle) = test_oracle_id(ctx);
    let expiry = oracle.expiry();
    // Any strike should pass — oracle doesn't validate strike
    let key = market_key::up(id, expiry, 999_999_999_999_999);
    key.assert_matches_oracle(&oracle);
    destroy(oracle);
}

#[test]
fun assert_matches_oracle_down_direction_passes() {
    let ctx = &mut tx_context::dummy();
    let (id, oracle) = test_oracle_id(ctx);
    let expiry = oracle.expiry();
    // DOWN direction should also pass
    let key = market_key::down(id, expiry, 100_000_000_000_000);
    key.assert_matches_oracle(&oracle);
    destroy(oracle);
}

// === Edge Cases ===

#[test]
fun zero_strike_and_expiry() {
    let id = object::id_from_address(@0x1);
    let key = market_key::up(id, 0, 0);
    assert_eq!(key.expiry(), 0);
    assert_eq!(key.strike(), 0);
    assert!(key.is_up());
}

#[test]
fun max_strike_and_expiry() {
    let id = object::id_from_address(@0x1);
    let key = market_key::down(id, 18_446_744_073_709_551_615, 18_446_744_073_709_551_615);
    assert_eq!(key.expiry(), 18_446_744_073_709_551_615);
    assert_eq!(key.strike(), 18_446_744_073_709_551_615);
    assert!(key.is_down());
}
