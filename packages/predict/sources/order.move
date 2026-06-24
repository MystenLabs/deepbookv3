// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable contract terms encoded in a Predict order ID.
///
/// An `Order` represents the durable contract terms needed after mint: the lower
/// and higher strike ticks, quantity, the static floor amount (`floor_shares = F`),
/// and the expiry-local sequence. Mint-only inputs such as entry probability,
/// leverage, net premium, and fee policy intentionally live outside this module.
/// The packed ID is the single source of truth at protocol boundaries; raw strike
/// conversion (through the owning market's `tick_size`) is interpreted by
/// `StrikeExposure`.
module deepbook_predict::order;

use deepbook_predict::constants;

const EInvalidOrderId: u64 = 0;
const EInvalidTick: u64 = 1;
const EInvalidFloorShares: u64 = 2;
const EInvalidRange: u64 = 3;
const EInvalidQuantity: u64 = 4;
const EInvalidSequence: u64 = 5;

// Active order id fields are dense in the low bits. Any unused bits are leading
// bits rejected by ORDER_ID_BITS during decode validation.
const QUANTITY_LOTS_OFFSET: u8 = 152;
const FLOOR_SHARES_OFFSET: u8 = 88;
const LOWER_TICK_OFFSET: u8 = 64;
const HIGHER_TICK_OFFSET: u8 = 40;
const ORDER_ID_BITS: u8 = 184;

const U24_MASK: u256 = (1u256 << 24) - 1;
const U32_MASK: u256 = (1u256 << 32) - 1;
const U40_MASK: u256 = (1u256 << 40) - 1;
const U64_MASK: u256 = (1u256 << 64) - 1;

/// Validated typed view over one packed Predict order ID.
public struct Order has copy, drop {
    id: u256,
}

// === Public-Package Functions ===

/// Validate a packed order ID and return it as an `Order` view.
public(package) fun from_order_id(order_id: u256): Order {
    let order = Order { id: order_id };
    order.assert_valid();
    order
}

/// Return the canonical packed order ID.
public(package) fun id(order: &Order): u256 {
    order.id
}

/// Return the lower strike tick encoded in this order (`0` is the `neg_inf` lower).
public(package) fun lower_tick(order: &Order): u64 {
    decode_u24(order.id, LOWER_TICK_OFFSET)
}

/// Return the higher strike tick encoded in this order (`pos_inf_tick` is the
/// `pos_inf` higher).
public(package) fun higher_tick(order: &Order): u64 {
    decode_u24(order.id, HIGHER_TICK_OFFSET)
}

/// Return the encoded quantity in position lots.
public(package) fun quantity_lots(order: &Order): u64 {
    decode_quantity_lots(order.id)
}

/// Return the immutable quantity encoded in this order.
public(package) fun quantity(order: &Order): u64 {
    order.quantity_lots() * constants::position_lot_size!()
}

/// Return the expiry-local sequence encoded in this order.
public(package) fun sequence(order: &Order): u64 {
    (order.id & U40_MASK) as u64
}

/// Construct an order ID from validated strike ticks.
public(package) fun new_from_ticks(
    lower_tick: u64,
    higher_tick: u64,
    floor_shares: u64,
    quantity: u64,
    sequence: u64,
): Order {
    new(
        lower_tick,
        higher_tick,
        floor_shares,
        quantity_lots_from_quantity(quantity),
        sequence,
    )
}

/// Construct a lower-quantity order that inherits the original floor coverage invariant.
public(package) fun replacement(
    old_order: &Order,
    quantity: u64,
    floor_shares: u64,
    sequence: u64,
): Order {
    assert!(quantity < old_order.quantity(), EInvalidQuantity);
    new_from_ticks(
        old_order.lower_tick(),
        old_order.higher_tick(),
        floor_shares,
        quantity,
        sequence,
    )
}

/// Assert that a user-facing position quantity can be encoded in an order.
public(package) fun assert_valid_quantity(quantity: u64) {
    let lot_size = constants::position_lot_size!();
    assert!(quantity > 0 && quantity % lot_size == 0, EInvalidQuantity);
    assert!(quantity / lot_size <= U32_MASK as u64, EInvalidQuantity);
}

public(package) fun max_quantity_lots(): u64 {
    U32_MASK as u64
}

public(package) fun is_leveraged(order: &Order): bool {
    order.floor_shares() > 0
}

/// Return the static floor amount (`floor_shares = F`) encoded in this order.
public(package) fun floor_shares(order: &Order): u64 {
    decode_floor_shares(order.id)
}

fun new(
    lower_tick: u64,
    higher_tick: u64,
    floor_shares: u64,
    quantity_lots: u64,
    sequence: u64,
): Order {
    assert!(lower_tick <= U24_MASK as u64, EInvalidTick);
    assert!(higher_tick <= U24_MASK as u64, EInvalidTick);
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    let quantity = quantity_lots * constants::position_lot_size!();
    assert!(floor_shares <= quantity, EInvalidFloorShares);
    assert_valid_order_shape(lower_tick, higher_tick);

    let quantity_lots_key = encode_quantity_lots_key(quantity_lots);
    let floor_shares_key = encode_floor_shares_key(floor_shares);
    let id =
        (quantity_lots_key << QUANTITY_LOTS_OFFSET)
        | (floor_shares_key << FLOOR_SHARES_OFFSET)
        | ((lower_tick as u256) << LOWER_TICK_OFFSET)
        | ((higher_tick as u256) << HIGHER_TICK_OFFSET)
        | (sequence as u256);

    Order { id }
}

// === Private Functions ===

fun decode_u24(id: u256, offset: u8): u64 {
    ((id >> offset) & U24_MASK) as u64
}

fun decode_u32(id: u256, offset: u8): u64 {
    ((id >> offset) & U32_MASK) as u64
}

fun decode_quantity_lots(id: u256): u64 {
    (U32_MASK as u64) - decode_u32(id, QUANTITY_LOTS_OFFSET)
}

fun decode_u64(id: u256, offset: u8): u64 {
    ((id >> offset) & U64_MASK) as u64
}

fun decode_floor_shares(id: u256): u64 {
    (U64_MASK as u64) - decode_u64(id, FLOOR_SHARES_OFFSET)
}

fun quantity_lots_from_quantity(quantity: u64): u64 {
    assert_valid_quantity(quantity);
    quantity / constants::position_lot_size!()
}

fun encode_quantity_lots_key(quantity_lots: u64): u256 {
    U32_MASK - (quantity_lots as u256)
}

fun encode_floor_shares_key(floor_shares: u64): u256 {
    U64_MASK - (floor_shares as u256)
}

fun assert_valid(order: &Order) {
    let quantity_lots = order.quantity_lots();
    assert!(order.id >> ORDER_ID_BITS == 0, EInvalidOrderId);
    assert!(quantity_lots > 0, EInvalidQuantity);
    assert!(order.floor_shares() <= order.quantity(), EInvalidFloorShares);
    assert_valid_order_shape(order.lower_tick(), order.higher_tick());
}

fun assert_valid_order_shape(lower_tick: u64, higher_tick: u64) {
    let pos_inf_tick = constants::pos_inf_tick!();
    assert!(lower_tick <= pos_inf_tick, EInvalidTick);
    assert!(higher_tick <= pos_inf_tick, EInvalidTick);
    assert!(lower_tick < higher_tick, EInvalidRange);
    assert!(!(lower_tick == 0 && higher_tick == pos_inf_tick), EInvalidRange);
}
