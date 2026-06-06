// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable contract terms encoded in a Predict order ID.
///
/// An `Order` represents the durable contract terms needed after mint: range
/// boundary indexes, quantity, normalized floor shares, original open time, and
/// expiry-local sequence. Mint-only inputs such as entry probability, leverage,
/// contribution, and fee policy intentionally live outside this module. The
/// packed ID is the single source of truth at protocol boundaries, while concrete
/// strike grids and floor-index timing are interpreted by `StrikeExposure`.
module deepbook_predict::order;

use deepbook_predict::constants;

const EInvalidOrderId: u64 = 0;
const EInvalidOpenedAt: u64 = 1;
const EInvalidBoundaryIndex: u64 = 2;
const EInvalidFloorShares: u64 = 3;
const EInvalidBoundaryRange: u64 = 4;
const EInvalidQuantity: u64 = 5;
const EInvalidSequence: u64 = 6;

const QUANTITY_LOTS_OFFSET: u8 = 200;
const FLOOR_SHARES_OFFSET: u8 = 136;
const OPENED_AT_OFFSET: u8 = 88;
const LOWER_BOUNDARY_INDEX_OFFSET: u8 = 64;
const HIGHER_BOUNDARY_INDEX_OFFSET: u8 = 40;
const ORDER_ID_BITS: u8 = 232;

const U24_MASK: u256 = (1u256 << 24) - 1;
const U32_MASK: u256 = (1u256 << 32) - 1;
const U40_MASK: u256 = (1u256 << 40) - 1;
const U48_MASK: u256 = (1u256 << 48) - 1;
const U64_MASK: u256 = (1u256 << 64) - 1;

/// Validated typed view over one packed Predict order ID.
public struct Order has copy, drop {
    id: u256,
}

// === Public Functions ===

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

/// Return the timestamp in milliseconds when this position was originally opened.
public fun opened_at_ms(order: &Order): u64 {
    decode_u48(order.id, OPENED_AT_OFFSET)
}

/// Return the lower strike boundary index encoded in this order.
public fun lower_boundary_index(order: &Order): u64 {
    decode_u24(order.id, LOWER_BOUNDARY_INDEX_OFFSET)
}

/// Return the higher strike boundary index encoded in this order.
public fun higher_boundary_index(order: &Order): u64 {
    decode_u24(order.id, HIGHER_BOUNDARY_INDEX_OFFSET)
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

/// Construct an order ID from already-normalized strike boundary indices.
public(package) fun new_from_boundary_indices(
    opened_at_ms: u64,
    lower_boundary_index: u64,
    higher_boundary_index: u64,
    floor_shares: u64,
    quantity: u64,
    sequence: u64,
): Order {
    new(
        opened_at_ms,
        lower_boundary_index,
        higher_boundary_index,
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
    new_from_boundary_indices(
        old_order.opened_at_ms(),
        old_order.lower_boundary_index(),
        old_order.higher_boundary_index(),
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

public(package) fun is_leveraged(order: &Order): bool {
    order.floor_shares() > 0
}

/// Return the normalized floor shares encoded in this order.
public(package) fun floor_shares(order: &Order): u64 {
    decode_u64(order.id, FLOOR_SHARES_OFFSET)
}

fun new(
    opened_at_ms: u64,
    lower_boundary_index: u64,
    higher_boundary_index: u64,
    floor_shares: u64,
    quantity_lots: u64,
    sequence: u64,
): Order {
    assert!(opened_at_ms <= U48_MASK as u64, EInvalidOpenedAt);
    assert!(lower_boundary_index <= U24_MASK as u64, EInvalidBoundaryIndex);
    assert!(higher_boundary_index <= U24_MASK as u64, EInvalidBoundaryIndex);
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    let quantity = quantity_lots * constants::position_lot_size!();
    assert!(floor_shares <= quantity, EInvalidFloorShares);
    assert_valid_order_shape(lower_boundary_index, higher_boundary_index, floor_shares > 0);

    let id =
        ((quantity_lots as u256) << QUANTITY_LOTS_OFFSET)
        | ((floor_shares as u256) << FLOOR_SHARES_OFFSET)
        | ((opened_at_ms as u256) << OPENED_AT_OFFSET)
        | ((lower_boundary_index as u256) << LOWER_BOUNDARY_INDEX_OFFSET)
        | ((higher_boundary_index as u256) << HIGHER_BOUNDARY_INDEX_OFFSET)
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

fun decode_u48(id: u256, offset: u8): u64 {
    ((id >> offset) & U48_MASK) as u64
}

fun decode_u64(id: u256, offset: u8): u64 {
    ((id >> offset) & U64_MASK) as u64
}

fun quantity_lots_from_quantity(quantity: u64): u64 {
    assert_valid_quantity(quantity);
    quantity / constants::position_lot_size!()
}

fun assert_valid(order: &Order) {
    let quantity_lots = order.quantity_lots();
    assert!(order.id >> ORDER_ID_BITS == 0, EInvalidOrderId);
    assert!(quantity_lots > 0, EInvalidQuantity);
    assert!(order.floor_shares() <= order.quantity(), EInvalidFloorShares);
    assert_valid_order_shape(
        order.lower_boundary_index(),
        order.higher_boundary_index(),
        order.is_leveraged(),
    );
}

fun assert_valid_order_shape(
    lower_boundary_index: u64,
    higher_boundary_index: u64,
    is_leveraged: bool,
) {
    let max_boundary_index = max_encoded_boundary_index();
    assert!(lower_boundary_index <= max_boundary_index, EInvalidBoundaryIndex);
    assert!(higher_boundary_index <= max_boundary_index, EInvalidBoundaryIndex);
    assert!(lower_boundary_index < higher_boundary_index, EInvalidBoundaryRange);
    assert!(
        !(lower_boundary_index == 0 && higher_boundary_index == max_boundary_index),
        EInvalidBoundaryRange,
    );
    if (!is_leveraged) return;

    assert!(
        lower_boundary_index == 0 || higher_boundary_index == max_boundary_index,
        EInvalidBoundaryRange,
    );
}

/// Highest boundary index the packed order ID can encode for any expiry grid.
///
/// `Order` does not map indexes to concrete strikes; `StrikeGrid` owns runtime
/// boundary mapping for each expiry. This bound only validates that the packed
/// u24 field is within the fixed protocol-wide boundary-index domain.
fun max_encoded_boundary_index(): u64 {
    constants::oracle_strike_grid_ticks!() + 2
}
