// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Packed Predict order identifiers.
///
/// Order IDs encode immutable routing facts for one minted order: encoding
/// version, expiry, insertion timestamp, strike indices, leverage code, and an
/// expiry-local sequence. Position quantities and accounting amounts live in
/// PredictManager position state, not in the identifier.
module deepbook_predict::predict_order_id;

use deepbook_predict::constants;

const EInvalidExpiry: u64 = 0;
const EInvalidInsertedAt: u64 = 1;
const EInvalidStrikeIndex: u64 = 2;
const EInvalidLeverage: u64 = 3;
const EInvalidVersion: u64 = 4;
const EUnsupportedLeverage: u64 = 5;
const EInvalidStrikeRange: u64 = 6;

const ORDER_ID_VERSION: u64 = 1;

const VERSION_OFFSET: u8 = 248;
const EXPIRY_OFFSET: u8 = 200;
const INSERTED_AT_OFFSET: u8 = 152;
const MIN_STRIKE_INDEX_OFFSET: u8 = 128;
const MAX_STRIKE_INDEX_OFFSET: u8 = 104;
const LEVERAGE_OFFSET: u8 = 96;

const U8_MASK: u256 = (1u256 << 8) - 1;
const U24_MASK: u256 = (1u256 << 24) - 1;
const U48_MASK: u256 = (1u256 << 48) - 1;
const U64_MASK: u256 = (1u256 << 64) - 1;

const LEVERAGE_ONE_X: u64 = 0;
const LEVERAGE_ONE_AND_HALF_X: u64 = 1;
const LEVERAGE_TWO_X: u64 = 2;
const LEVERAGE_TWO_AND_HALF_X: u64 = 3;
const LEVERAGE_THREE_X: u64 = 4;

// === Public Functions ===

/// Return the leverage code for a 1x position.
public fun leverage_one_x(): u64 {
    LEVERAGE_ONE_X
}

/// Return the leverage code for a 1.5x position.
public fun leverage_one_and_half_x(): u64 {
    LEVERAGE_ONE_AND_HALF_X
}

/// Return the leverage code for a 2x position.
public fun leverage_two_x(): u64 {
    LEVERAGE_TWO_X
}

/// Return the leverage code for a 2.5x position.
public fun leverage_two_and_half_x(): u64 {
    LEVERAGE_TWO_AND_HALF_X
}

/// Return the leverage code for a 3x position.
public fun leverage_three_x(): u64 {
    LEVERAGE_THREE_X
}

/// Return the endpoint code used for an open strike boundary.
public fun open_strike_index(): u64 {
    constants::oracle_strike_grid_ticks!() + 1
}

/// Return the encoding version embedded in an order ID.
public fun version(order_id: u256): u64 {
    ((order_id >> VERSION_OFFSET) & U8_MASK) as u64
}

/// Return the expiry timestamp embedded in an order ID.
public fun expiry_ms(order_id: u256): u64 {
    assert_valid_version(order_id);
    ((order_id >> EXPIRY_OFFSET) & U48_MASK) as u64
}

/// Return the insertion timestamp embedded in an order ID.
public fun inserted_at_ms(order_id: u256): u64 {
    assert_valid_version(order_id);
    ((order_id >> INSERTED_AT_OFFSET) & U48_MASK) as u64
}

/// Return the encoded lower strike index.
public fun min_strike_index(order_id: u256): u64 {
    assert_valid_version(order_id);
    ((order_id >> MIN_STRIKE_INDEX_OFFSET) & U24_MASK) as u64
}

/// Return the encoded upper strike index.
public fun max_strike_index(order_id: u256): u64 {
    assert_valid_version(order_id);
    ((order_id >> MAX_STRIKE_INDEX_OFFSET) & U24_MASK) as u64
}

/// Return the leverage code embedded in an order ID.
public fun leverage(order_id: u256): u64 {
    assert_valid_version(order_id);
    ((order_id >> LEVERAGE_OFFSET) & U8_MASK) as u64
}

/// Return the expiry-local sequence embedded in an order ID.
public fun sequence(order_id: u256): u64 {
    assert_valid_version(order_id);
    (order_id & U64_MASK) as u64
}

// === Public-Package Functions ===

/// Encode immutable order routing facts into a u256 order ID.
public(package) fun encode(
    expiry_ms: u64,
    inserted_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    sequence: u64,
): u256 {
    assert!(expiry_ms <= U48_MASK as u64, EInvalidExpiry);
    assert!(inserted_at_ms <= U48_MASK as u64, EInvalidInsertedAt);
    assert_valid_strike_index_range(min_strike_index, max_strike_index);
    assert_valid_leverage(leverage);

    ((ORDER_ID_VERSION as u256) << VERSION_OFFSET)
        | ((expiry_ms as u256) << EXPIRY_OFFSET)
        | ((inserted_at_ms as u256) << INSERTED_AT_OFFSET)
        | ((min_strike_index as u256) << MIN_STRIKE_INDEX_OFFSET)
        | ((max_strike_index as u256) << MAX_STRIKE_INDEX_OFFSET)
        | ((leverage as u256) << LEVERAGE_OFFSET)
        | (sequence as u256)
}

/// Decode order strike indices against a concrete strike grid.
public(package) fun strike_range(
    order_id: u256,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
): (u64, u64) {
    let min_strike_index = min_strike_index(order_id);
    let max_strike_index = max_strike_index(order_id);
    assert_valid_strike_index_range(min_strike_index, max_strike_index);

    (
        decode_strike(min_strike_index, grid_min, grid_tick, grid_max, true),
        decode_strike(max_strike_index, grid_min, grid_tick, grid_max, false),
    )
}

/// Abort unless the requested leverage is currently enabled.
public(package) fun assert_one_x_leverage(leverage: u64) {
    assert!(leverage == LEVERAGE_ONE_X, EUnsupportedLeverage);
}

// === Private Functions ===

fun decode_strike(
    strike_index: u64,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    is_lower: bool,
): u64 {
    if (strike_index == open_strike_index()) {
        return if (is_lower) constants::neg_inf!() else constants::pos_inf!()
    };
    assert!(strike_index < open_strike_index(), EInvalidStrikeIndex);
    let strike = grid_min + strike_index * grid_tick;
    assert!(strike <= grid_max, EInvalidStrikeIndex);
    strike
}

fun assert_valid_version(order_id: u256) {
    assert!(version(order_id) == ORDER_ID_VERSION, EInvalidVersion);
}

fun assert_valid_leverage(leverage: u64) {
    assert!(leverage <= LEVERAGE_THREE_X, EInvalidLeverage);
}

fun assert_valid_strike_index_range(min_strike_index: u64, max_strike_index: u64) {
    let open_index = open_strike_index();
    assert!(min_strike_index <= open_index, EInvalidStrikeIndex);
    assert!(max_strike_index <= open_index, EInvalidStrikeIndex);
    assert!(
        !(min_strike_index == open_index && max_strike_index == open_index),
        EInvalidStrikeRange,
    );
    assert!(
        min_strike_index == open_index
            || max_strike_index == open_index
            || min_strike_index < max_strike_index,
        EInvalidStrikeRange,
    );
}
