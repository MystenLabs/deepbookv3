// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Typed wrapper around a packed Predict order ID.
///
/// Order IDs are the canonical protocol key stored by managers and emitted at
/// flow boundaries. `Order` keeps that packed ID as the single source of truth
/// while exposing validated accessors for its immutable terms. Concrete oracle
/// strike grids are interpreted by `StrikeExposure`.
module deepbook_predict::order;

use deepbook::math as deepbook_math;
use deepbook_predict::{constants, math};

const EInvalidExpiry: u64 = 0;
const EInvalidOpenedAt: u64 = 1;
const EInvalidStrikeIndex: u64 = 2;
const EInvalidLeverage: u64 = 3;
const EInvalidStrikeRange: u64 = 4;
const EInvalidQuantity: u64 = 5;
const EInvalidSequence: u64 = 6;
const EInvalidMintedPrice: u64 = 7;

const EXPIRY_OFFSET: u8 = 208;
const OPENED_AT_OFFSET: u8 = 160;
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

/// Validated typed view over one packed Predict order ID.
public struct Order has copy, drop {
    id: u256,
}

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

/// Validate a packed order ID and return it as an `Order` view.
public fun from_order_id(order_id: u256): Order {
    let order = Order { id: order_id };
    order.assert_valid();
    order
}

/// Return the canonical packed order ID.
public fun id(order: &Order): u256 {
    order.id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry_ms(order: &Order): u64 {
    decode_u48(order.id, EXPIRY_OFFSET)
}

/// Return the timestamp in milliseconds when this position was originally opened.
public fun opened_at_ms(order: &Order): u64 {
    decode_u48(order.id, OPENED_AT_OFFSET)
}

/// Return the lower strike index encoded in this order.
public fun min_strike_index(order: &Order): u64 {
    decode_u24(order.id, MIN_STRIKE_INDEX_OFFSET)
}

/// Return the upper strike index encoded in this order.
public fun max_strike_index(order: &Order): u64 {
    decode_u24(order.id, MAX_STRIKE_INDEX_OFFSET)
}

/// Return the leverage code encoded in this order.
public fun leverage(order: &Order): u64 {
    decode_u8(order.id, LEVERAGE_OFFSET)
}

/// Return the 1e9-scaled mint price encoded in this order.
public fun minted_price(order: &Order): u64 {
    decode_u32(order.id, MINTED_PRICE_OFFSET)
}

/// Return the encoded quantity in position lots.
public fun quantity_lots(order: &Order): u64 {
    decode_u32(order.id, QUANTITY_LOTS_OFFSET)
}

/// Return the immutable quantity encoded in this order.
public fun quantity(order: &Order): u64 {
    order.quantity_lots() * constants::position_lot_size!()
}

/// Return the expiry-local sequence encoded in this order.
public fun sequence(order: &Order): u64 {
    (order.id & U40_MASK) as u64
}

// === Public-Package Functions ===

/// Construct an order ID from already-normalized strike indices.
public(package) fun new_from_strike_indices(
    expiry_ms: u64,
    opened_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    minted_price: u64,
    quantity: u64,
    sequence: u64,
): Order {
    new(
        expiry_ms,
        opened_at_ms,
        min_strike_index,
        max_strike_index,
        leverage,
        minted_price,
        quantity_lots_from_quantity(quantity),
        sequence,
    )
}

/// Construct a replacement order that preserves range, leverage, original mint price, and accrual start.
public(package) fun replacement(old_order: &Order, quantity: u64, sequence: u64): Order {
    new_from_strike_indices(
        old_order.expiry_ms(),
        old_order.opened_at_ms(),
        old_order.min_strike_index(),
        old_order.max_strike_index(),
        old_order.leverage(),
        old_order.minted_price(),
        quantity,
        sequence,
    )
}

/// Return the sentinel index for an unbounded order side.
public(package) fun open_strike_index(): u64 {
    constants::oracle_strike_grid_ticks!() + 1
}

/// Assert that a user-facing position quantity can be encoded in an order.
public(package) fun assert_valid_quantity(quantity: u64) {
    let lot_size = constants::position_lot_size!();
    assert!(quantity > 0 && quantity % lot_size == 0, EInvalidQuantity);
    assert!(quantity / lot_size <= U32_MASK as u64, EInvalidQuantity);
}

public(package) fun is_leveraged(order: &Order): bool {
    order.leverage() != LEVERAGE_ONE_X
}

/// Return the 1e9-scaled leverage multiplier for a supported leverage code.
public(package) fun leverage_multiplier(leverage: u64): u64 {
    assert_valid_leverage(leverage);
    constants::float_scaling!() + leverage * constants::float_scaling!() / 2
}

/// Return full notional principal implied by mint price and quantity.
public(package) fun principal_amount(order: &Order): u64 {
    deepbook_math::mul(order.minted_price(), order.quantity())
}

/// Return user-funded equity, rounded up so leverage never exceeds its code.
public(package) fun equity_amount(order: &Order): u64 {
    equity_amount_from_principal(order.principal_amount(), order.leverage())
}

/// Return LP-funded principal implied by this order's leverage.
public(package) fun borrowed_principal(order: &Order): u64 {
    let principal_amount = order.principal_amount();
    principal_amount - equity_amount_from_principal(principal_amount, order.leverage())
}

fun new(
    expiry_ms: u64,
    opened_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    minted_price: u64,
    quantity_lots: u64,
    sequence: u64,
): Order {
    assert!(expiry_ms <= U48_MASK as u64, EInvalidExpiry);
    assert!(opened_at_ms <= U48_MASK as u64, EInvalidOpenedAt);
    assert!(min_strike_index <= U24_MASK as u64, EInvalidStrikeIndex);
    assert!(max_strike_index <= U24_MASK as u64, EInvalidStrikeIndex);
    assert!(minted_price <= constants::float_scaling!(), EInvalidMintedPrice);
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    assert_valid_order_shape(min_strike_index, max_strike_index, leverage);

    let id =
        ((expiry_ms as u256) << EXPIRY_OFFSET)
        | ((opened_at_ms as u256) << OPENED_AT_OFFSET)
        | ((min_strike_index as u256) << MIN_STRIKE_INDEX_OFFSET)
        | ((max_strike_index as u256) << MAX_STRIKE_INDEX_OFFSET)
        | ((leverage as u256) << LEVERAGE_OFFSET)
        | ((minted_price as u256) << MINTED_PRICE_OFFSET)
        | ((quantity_lots as u256) << QUANTITY_LOTS_OFFSET)
        | (sequence as u256);

    Order { id }
}

// === Private Functions ===

fun decode_u8(id: u256, offset: u8): u64 {
    ((id >> offset) & U8_MASK) as u64
}

fun decode_u24(id: u256, offset: u8): u64 {
    ((id >> offset) & U24_MASK) as u64
}

fun decode_u32(id: u256, offset: u8): u64 {
    ((id >> offset) & U32_MASK) as u64
}

fun decode_u48(id: u256, offset: u8): u64 {
    ((id >> offset) & U48_MASK) as u64
}

fun quantity_lots_from_quantity(quantity: u64): u64 {
    assert_valid_quantity(quantity);
    quantity / constants::position_lot_size!()
}

fun assert_valid(order: &Order) {
    let quantity_lots = order.quantity_lots();
    assert!(order.minted_price() <= constants::float_scaling!(), EInvalidMintedPrice);
    assert!(quantity_lots > 0, EInvalidQuantity);
    assert_valid_order_shape(order.min_strike_index(), order.max_strike_index(), order.leverage());
}

fun equity_amount_from_principal(principal_amount: u64, leverage: u64): u64 {
    math::mul_div_round_up(
        principal_amount,
        constants::float_scaling!(),
        leverage_multiplier(leverage),
    )
}

fun assert_valid_leverage(leverage: u64) {
    assert!(leverage <= LEVERAGE_THREE_X, EInvalidLeverage);
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
    if (leverage == LEVERAGE_ONE_X) return;

    assert!(min_strike_index == open_index || max_strike_index == open_index, EInvalidStrikeRange);
}
