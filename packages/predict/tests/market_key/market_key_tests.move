// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_key_tests;

use deepbook_predict::{market_key, oracle::OracleSVI, oracle_helper};
use std::unit_test::assert_eq;
use sui::test_scenario::{Self as test_scenario, begin, end, return_shared};

const ALICE: address = @0xA;

const STRIKE_50K: u64 = 50_000_000_000;
const STRIKE_60K: u64 = 60_000_000_000;
const STRIKE_70K: u64 = 70_000_000_000;
const STRIKE_80K: u64 = 80_000_000_000;

const EXPIRY_1: u64 = 1000;
const EXPIRY_2: u64 = 2000;
const EXPIRY_3: u64 = 3000;
const EXPIRY_4: u64 = 4000;
const EXPIRY_5: u64 = 5000;

const ORACLE_1: address = @0x1;
const ORACLE_2: address = @0x2;
const ORACLE_3: address = @0x3;
const ORACLE_4: address = @0x4;

fun setup_oracle(expiry: u64, test: &mut test_scenario::Scenario): ID {
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        expiry,
        test,
    );
    oracle_id
}

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
fun assert_matches_oracle_succeeds_when_matching() {
    let mut test = begin(ALICE);
    let oracle_id = setup_oracle(EXPIRY_5, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let key = market_key::up(oracle_id, EXPIRY_5, STRIKE_50K);
        market_key::assert_matches_oracle(&key, &oracle_state);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = market_key::EOracleMismatch)]
fun assert_matches_oracle_aborts_on_wrong_oracle_id() {
    let mut test = begin(ALICE);
    let oracle_id_1 = setup_oracle(EXPIRY_5, &mut test);
    let oracle_id_2 = setup_oracle(EXPIRY_5, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id_2);
        let key = market_key::up(oracle_id_1, EXPIRY_5, STRIKE_50K);
        market_key::assert_matches_oracle(&key, &oracle_state);
    };

    abort
}

#[test, expected_failure(abort_code = market_key::EExpiryMismatch)]
fun assert_matches_oracle_aborts_on_wrong_expiry() {
    let mut test = begin(ALICE);
    let oracle_id = setup_oracle(EXPIRY_5, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let key = market_key::up(oracle_id, 9999, STRIKE_50K);
        market_key::assert_matches_oracle(&key, &oracle_state);
    };

    abort
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
