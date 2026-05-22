// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Packed Predict order identifiers.
///
/// Order IDs encode immutable terms for one minted order: expiry, insertion
/// timestamp, strike indices, leverage code, minted price, immutable quantity
/// lots, and an expiry-local sequence.
module deepbook_predict::predict_order_id;

use deepbook::math as deepbook_math;
use deepbook_predict::{constants, math};

const EInvalidExpiry: u64 = 0;
const EInvalidInsertedAt: u64 = 1;
const EInvalidStrikeIndex: u64 = 2;
const EInvalidLeverage: u64 = 3;
const EInvalidStrikeRange: u64 = 6;
const EInvalidQuantity: u64 = 7;
const EInvalidSequence: u64 = 8;
const EInvalidMintedPrice: u64 = 9;

const EXPIRY_OFFSET: u8 = 208;
const INSERTED_AT_OFFSET: u8 = 160;
const MIN_STRIKE_INDEX_OFFSET: u8 = 136;
const MAX_STRIKE_INDEX_OFFSET: u8 = 112;
const LEVERAGE_OFFSET: u8 = 104;
const MINTED_PRICE_OFFSET: u8 = 72;
const QUANTITY_LOTS_OFFSET: u8 = 40;

const U8_MASK: u256 = (1u256 << 8) - 1;
const U24_MASK: u256 = (1u256 << 24) - 1;
const U32_MASK: u256 = (1u256 << 32) - 1;
const U40_MASK: u256 = (1u256 << 40) - 1;
const U48_MASK: u256 = (1u256 << 48) - 1;

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

/// Return the expiry timestamp embedded in an order ID.
public fun expiry_ms(order_id: u256): u64 {
    ((order_id >> EXPIRY_OFFSET) & U48_MASK) as u64
}

/// Return the insertion timestamp embedded in an order ID.
public fun inserted_at_ms(order_id: u256): u64 {
    ((order_id >> INSERTED_AT_OFFSET) & U48_MASK) as u64
}

/// Return the leverage code embedded in an order ID.
public fun leverage(order_id: u256): u64 {
    ((order_id >> LEVERAGE_OFFSET) & U8_MASK) as u64
}

/// Return the 1e9-scaled contract price embedded in an order ID.
public fun minted_price(order_id: u256): u64 {
    ((order_id >> MINTED_PRICE_OFFSET) & U32_MASK) as u64
}

/// Return the immutable quantity embedded in an order ID.
public fun quantity(order_id: u256): u64 {
    quantity_lots(order_id) * constants::position_lot_size!()
}

// === Public-Package Functions ===

public(package) fun open_strike_index(): u64 {
    constants::oracle_strike_grid_ticks!() + 1
}

/// Encode immutable order terms into a u256 order ID.
public(package) fun encode(
    expiry_ms: u64,
    inserted_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    minted_price: u64,
    quantity: u64,
    sequence: u64,
): u256 {
    assert!(expiry_ms <= U48_MASK as u64, EInvalidExpiry);
    assert!(inserted_at_ms <= U48_MASK as u64, EInvalidInsertedAt);
    assert!(minted_price <= constants::float_scaling!(), EInvalidMintedPrice);
    let quantity_lots = encode_quantity_lots(quantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    assert_valid_order_shape(min_strike_index, max_strike_index, leverage);

    ((expiry_ms as u256) << EXPIRY_OFFSET)
        | ((inserted_at_ms as u256) << INSERTED_AT_OFFSET)
        | ((min_strike_index as u256) << MIN_STRIKE_INDEX_OFFSET)
        | ((max_strike_index as u256) << MAX_STRIKE_INDEX_OFFSET)
        | ((leverage as u256) << LEVERAGE_OFFSET)
        | ((minted_price as u256) << MINTED_PRICE_OFFSET)
        | ((quantity_lots as u256) << QUANTITY_LOTS_OFFSET)
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
    assert_valid_order_shape(min_strike_index, max_strike_index, leverage(order_id));

    (
        decode_strike(min_strike_index, grid_min, grid_tick, grid_max, true),
        decode_strike(max_strike_index, grid_min, grid_tick, grid_max, false),
    )
}

public(package) fun is_leveraged_order(order_id: u256): bool {
    !is_one_x_leverage(leverage(order_id))
}

public(package) fun leverage_multiplier(leverage: u64): u64 {
    assert_valid_leverage(leverage);
    constants::float_scaling!() + leverage * constants::float_scaling!() / 2
}

public(package) fun equity_amount(principal_amount: u64, leverage: u64): u64 {
    math::mul_div_round_up(
        principal_amount,
        constants::float_scaling!(),
        leverage_multiplier(leverage),
    )
}

public(package) fun principal_amount(order_id: u256): u64 {
    deepbook_math::mul(minted_price(order_id), quantity(order_id))
}

public(package) fun borrowed_principal(order_id: u256): u64 {
    let principal_amount = principal_amount(order_id);
    principal_amount - equity_amount(principal_amount, leverage(order_id))
}

// === Private Functions ===

fun min_strike_index(order_id: u256): u64 {
    ((order_id >> MIN_STRIKE_INDEX_OFFSET) & U24_MASK) as u64
}

fun max_strike_index(order_id: u256): u64 {
    ((order_id >> MAX_STRIKE_INDEX_OFFSET) & U24_MASK) as u64
}

fun quantity_lots(order_id: u256): u64 {
    ((order_id >> QUANTITY_LOTS_OFFSET) & U32_MASK) as u64
}

fun encode_quantity_lots(quantity: u64): u64 {
    let lot_size = constants::position_lot_size!();
    assert!(quantity > 0 && quantity % lot_size == 0, EInvalidQuantity);
    let quantity_lots = quantity / lot_size;
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    quantity_lots
}

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

fun assert_valid_leverage(leverage: u64) {
    assert!(leverage <= LEVERAGE_THREE_X, EInvalidLeverage);
}

fun is_one_x_leverage(leverage: u64): bool {
    leverage == LEVERAGE_ONE_X
}

fun assert_valid_order_shape(min_strike_index: u64, max_strike_index: u64, leverage: u64) {
    assert_valid_leverage(leverage);
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
    if (is_one_x_leverage(leverage)) return;

    assert!(min_strike_index == open_index || max_strike_index == open_index, EInvalidStrikeRange);
}
