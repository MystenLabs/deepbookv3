// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for MarketKey construction, field access, and equality semantics.
#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::market_key;
use std::unit_test::assert_eq;

const STRIKE_50K: u64 = 50_000_000_000;
const STRIKE_60K: u64 = 60_000_000_000;
const STRIKE_70K: u64 = 70_000_000_000;
const STRIKE_80K: u64 = 80_000_000_000;

const EXPIRY_1: u64 = 1000;
const EXPIRY_2: u64 = 2000;
const EXPIRY_3: u64 = 3000;
const EXPIRY_4: u64 = 4000;
const ORACLE_1: address = @0x1;
const ORACLE_2: address = @0x2;
const ORACLE_3: address = @0x3;
const ORACLE_4: address = @0x4;

fun oracle_id(addr: address): ID {
    object::id_from_address(addr)
}

#[test]
fun up_creates_correct_key() {
    let oracle_id = oracle_id(ORACLE_1);

    let key = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), EXPIRY_1);
    assert_eq!(market_key::strike(&key), STRIKE_50K);
    assert!(market_key::is_up(&key));
    assert!(!market_key::is_down(&key));
}

#[test]
fun down_creates_correct_key() {
    let oracle_id = oracle_id(ORACLE_2);

    let key = market_key::down(oracle_id, EXPIRY_2, STRIKE_60K);

    assert_eq!(market_key::oracle_id(&key), oracle_id);
    assert_eq!(market_key::expiry(&key), EXPIRY_2);
    assert_eq!(market_key::strike(&key), STRIKE_60K);
    assert!(market_key::is_down(&key));
    assert!(!market_key::is_up(&key));
}

#[test]
fun new_with_is_up_true_matches_up() {
    let oracle_id = oracle_id(ORACLE_3);

    let key_up = market_key::up(oracle_id, EXPIRY_3, STRIKE_70K);
    let key_new = market_key::new(oracle_id, EXPIRY_3, STRIKE_70K, true);

    assert_eq!(key_up, key_new);
}

#[test]
fun new_with_is_up_false_matches_down() {
    let oracle_id = oracle_id(ORACLE_4);

    let key_down = market_key::down(oracle_id, EXPIRY_4, STRIKE_80K);
    let key_new = market_key::new(oracle_id, EXPIRY_4, STRIKE_80K, false);

    assert_eq!(key_down, key_new);
}

#[test]
fun same_fields_are_equal() {
    let oracle_id = oracle_id(ORACLE_1);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);

    assert_eq!(key1, key2);
}

#[test]
fun different_strikes_are_not_equal() {
    let oracle_id = oracle_id(ORACLE_1);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::up(oracle_id, EXPIRY_1, STRIKE_60K);

    assert!(key1 != key2);
}

#[test]
fun different_directions_are_not_equal() {
    let oracle_id = oracle_id(ORACLE_1);

    let key1 = market_key::up(oracle_id, EXPIRY_1, STRIKE_50K);
    let key2 = market_key::down(oracle_id, EXPIRY_1, STRIKE_50K);

    assert!(key1 != key2);
}
