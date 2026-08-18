// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable contract terms encoded in a Predict order ID.
///
/// An `Order` represents the durable contract terms needed after mint: the lower
/// and higher strike ticks, quantity, and the expiry-local sequence. Mint-only
/// inputs such as entry probability, premium, and fee policy intentionally
/// live outside this module. The packed ID is the single source of truth at
/// protocol boundaries; raw strike conversion (through the owning market's
/// `tick_size`) is interpreted by `StrikeExposure`.
module deepbook_predict::order;

use deepbook_predict::constants;

const EInvalidOrderId: u64 = 0;
const EInvalidTick: u64 = 1;
const EInvalidRange: u64 = 2;
const EInvalidQuantity: u64 = 3;
const EInvalidSequence: u64 = 4;

// Fields are dense in the low bits; higher bits are rejected during validation.
const QUANTITY_LOTS_OFFSET: u8 = 100;
const LOWER_TICK_OFFSET: u8 = 70;
const HIGHER_TICK_OFFSET: u8 = 40;
const ORDER_ID_BITS: u8 = 132;

const U32_MASK: u256 = (1u256 << 32) - 1;
const U40_MASK: u256 = (1u256 << 40) - 1;

/// u256 mask for the `tick_bits!()`-wide tick fields in the packed order id.
/// Derived from `constants::tick_bits!()` so it can't drift from the tick width.
macro fun tick_mask(): u256 {
    (1u256 << constants::tick_bits!()) - 1
}

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
    decode_tick(order.id, LOWER_TICK_OFFSET)
}

/// Return the higher strike tick encoded in this order (`pos_inf_tick` is the
/// `pos_inf` higher).
public(package) fun higher_tick(order: &Order): u64 {
    decode_tick(order.id, HIGHER_TICK_OFFSET)
}

/// Return the immutable quantity encoded in this order.
public(package) fun quantity(order: &Order): u64 {
    order.quantity_lots() * constants::position_lot_size!()
}

/// Construct an order ID from validated strike ticks.
public(package) fun new_from_ticks(
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    sequence: u64,
): Order {
    new(lower_tick, higher_tick, quantity_lots_from_quantity(quantity), sequence)
}

/// Construct a lower-quantity order with the same range and a new sequence.
public(package) fun replacement(old_order: &Order, quantity: u64, sequence: u64): Order {
    assert!(quantity < old_order.quantity(), EInvalidQuantity);
    new_from_ticks(old_order.lower_tick(), old_order.higher_tick(), quantity, sequence)
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

fun new(lower_tick: u64, higher_tick: u64, quantity_lots: u64, sequence: u64): Order {
    assert!(lower_tick <= tick_mask!() as u64, EInvalidTick);
    assert!(higher_tick <= tick_mask!() as u64, EInvalidTick);
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    assert_valid_order_shape(lower_tick, higher_tick);

    let id =
        ((quantity_lots as u256) << QUANTITY_LOTS_OFFSET)
        | ((lower_tick as u256) << LOWER_TICK_OFFSET)
        | ((higher_tick as u256) << HIGHER_TICK_OFFSET)
        | (sequence as u256);

    Order { id }
}

// === Private Functions ===

fun decode_tick(id: u256, offset: u8): u64 {
    ((id >> offset) & tick_mask!()) as u64
}

fun quantity_lots_from_quantity(quantity: u64): u64 {
    assert_valid_quantity(quantity);
    quantity / constants::position_lot_size!()
}

fun assert_valid(order: &Order) {
    assert!(order.id >> ORDER_ID_BITS == 0, EInvalidOrderId);
    assert!(order.quantity_lots() > 0, EInvalidQuantity);
    assert_valid_order_shape(order.lower_tick(), order.higher_tick());
}

fun quantity_lots(order: &Order): u64 {
    ((order.id >> QUANTITY_LOTS_OFFSET) & U32_MASK) as u64
}

fun assert_valid_order_shape(lower_tick: u64, higher_tick: u64) {
    let pos_inf_tick = constants::pos_inf_tick!();
    assert!(lower_tick <= pos_inf_tick, EInvalidTick);
    assert!(higher_tick <= pos_inf_tick, EInvalidTick);
    assert!(lower_tick < higher_tick, EInvalidRange);
    assert!(!(lower_tick == 0 && higher_tick == pos_inf_tick), EInvalidRange);
}
