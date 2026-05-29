// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable contract terms encoded in a Predict order ID.
///
/// An `Order` represents the contract sold to a user: a range, entry
/// probability, quantity, fixed-point leverage multiplier, and original open
/// time. Leverage changes the contract's deterministic floor schedule; 1x is the
/// special case where the floor is zero and the behavior looks like a plain range
/// payout. The packed ID is the single source of truth at protocol boundaries.
/// Its field ordering also acts as liquidation-check priority for active
/// leveraged IDs, while concrete strike grids and floor-index timing are
/// interpreted by `StrikeExposure`.
module deepbook_predict::order;

use deepbook::math as deepbook_math;
use deepbook_predict::{constants, math};

const EInvalidOrderId: u64 = 0;
const EInvalidOpenedAt: u64 = 1;
const EInvalidStrikeIndex: u64 = 2;
const EInvalidLeverage: u64 = 3;
const EInvalidStrikeRange: u64 = 4;
const EInvalidQuantity: u64 = 5;
const EInvalidSequence: u64 = 6;
const EInvalidEntryProbability: u64 = 7;
const EInvalidLeverageTier: u64 = 8;

const LEVERAGE_RANK_OFFSET: u8 = 200;
const INVERSE_QUANTITY_LOTS_OFFSET: u8 = 168;
const OPENED_AT_OFFSET: u8 = 120;
const MIN_STRIKE_INDEX_OFFSET: u8 = 96;
const MAX_STRIKE_INDEX_OFFSET: u8 = 72;
const ENTRY_PROBABILITY_OFFSET: u8 = 40;
const ORDER_ID_BITS: u8 = 232;

const U24_MASK: u256 = (1u256 << 24) - 1;
const U32_MASK: u256 = (1u256 << 32) - 1;
const U40_MASK: u256 = (1u256 << 40) - 1;
const U48_MASK: u256 = (1u256 << 48) - 1;

const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const LEVERAGE_ONE_AND_HALF_X: u64 = 1_500_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const LEVERAGE_TWO_AND_HALF_X: u64 = 2_500_000_000;
const LEVERAGE_THREE_X: u64 = 3_000_000_000;

/// Validated typed view over one packed Predict order ID.
public struct Order has copy, drop {
    id: u256,
}

// === Public Functions ===

/// Return the 1e9-scaled leverage multiplier for a 1x position.
public fun leverage_one_x(): u64 {
    LEVERAGE_ONE_X
}

/// Return the 1e9-scaled leverage multiplier for a 1.5x position.
public fun leverage_one_and_half_x(): u64 {
    LEVERAGE_ONE_AND_HALF_X
}

/// Return the 1e9-scaled leverage multiplier for a 2x position.
public fun leverage_two_x(): u64 {
    LEVERAGE_TWO_X
}

/// Return the 1e9-scaled leverage multiplier for a 2.5x position.
public fun leverage_two_and_half_x(): u64 {
    LEVERAGE_TWO_AND_HALF_X
}

/// Return the 1e9-scaled leverage multiplier for a 3x position.
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

/// Return the 1e9-scaled leverage multiplier encoded in this order.
public fun leverage(order: &Order): u64 {
    leverage_from_rank(decode_u32(order.id, LEVERAGE_RANK_OFFSET))
}

/// Return the 1e9-scaled raw range probability encoded at order entry.
public fun entry_probability(order: &Order): u64 {
    decode_u32(order.id, ENTRY_PROBABILITY_OFFSET)
}

/// Return the encoded quantity in position lots.
public fun quantity_lots(order: &Order): u64 {
    U32_MASK as u64 - decode_u32(order.id, INVERSE_QUANTITY_LOTS_OFFSET)
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
    opened_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    entry_probability: u64,
    quantity: u64,
    sequence: u64,
): Order {
    new(
        opened_at_ms,
        min_strike_index,
        max_strike_index,
        leverage,
        entry_probability,
        quantity_lots_from_quantity(quantity),
        sequence,
    )
}

/// Construct a lower-quantity order that inherits the original floor coverage invariant.
public(package) fun replacement(old_order: &Order, quantity: u64, sequence: u64): Order {
    assert!(quantity < old_order.quantity(), EInvalidQuantity);
    new_from_strike_indices(
        old_order.opened_at_ms(),
        old_order.min_strike_index(),
        old_order.max_strike_index(),
        old_order.leverage(),
        old_order.entry_probability(),
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

/// Return user contribution, rounded up so effective leverage never exceeds the multiplier.
public(package) fun user_contribution(order: &Order): u64 {
    user_contribution_from_exposure_value(order.entry_exposure_value(), order.leverage())
}

/// Return floor seed amount implied by this order's leverage.
public(package) fun floor_seed_amount(order: &Order): u64 {
    let exposure_value = order.entry_exposure_value();
    exposure_value - user_contribution_from_exposure_value(exposure_value, order.leverage())
}

/// Assert the mint-time leverage tier allowed for an entry probability.
public(package) fun assert_mint_leverage_tier(entry_probability: u64, leverage: u64) {
    assert_valid_leverage(leverage);
    if (entry_probability < constants::leverage_one_x_only_price_threshold!()) {
        assert!(leverage == LEVERAGE_ONE_X, EInvalidLeverageTier);
    } else if (entry_probability < constants::leverage_two_x_max_price_threshold!()) {
        assert!(leverage <= LEVERAGE_TWO_X, EInvalidLeverageTier);
    };
}

fun new(
    opened_at_ms: u64,
    min_strike_index: u64,
    max_strike_index: u64,
    leverage: u64,
    entry_probability: u64,
    quantity_lots: u64,
    sequence: u64,
): Order {
    assert!(opened_at_ms <= U48_MASK as u64, EInvalidOpenedAt);
    assert!(min_strike_index <= U24_MASK as u64, EInvalidStrikeIndex);
    assert!(max_strike_index <= U24_MASK as u64, EInvalidStrikeIndex);
    assert!(entry_probability <= constants::float_scaling!(), EInvalidEntryProbability);
    assert!(quantity_lots > 0 && quantity_lots <= U32_MASK as u64, EInvalidQuantity);
    assert!(sequence <= U40_MASK as u64, EInvalidSequence);
    assert_valid_order_shape(min_strike_index, max_strike_index, leverage);

    let leverage_rank = leverage_rank(leverage);
    let inverse_quantity_lots = U32_MASK as u64 - quantity_lots;
    let id =
        ((leverage_rank as u256) << LEVERAGE_RANK_OFFSET)
        | ((inverse_quantity_lots as u256) << INVERSE_QUANTITY_LOTS_OFFSET)
        | ((opened_at_ms as u256) << OPENED_AT_OFFSET)
        | ((min_strike_index as u256) << MIN_STRIKE_INDEX_OFFSET)
        | ((max_strike_index as u256) << MAX_STRIKE_INDEX_OFFSET)
        | ((entry_probability as u256) << ENTRY_PROBABILITY_OFFSET)
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

fun quantity_lots_from_quantity(quantity: u64): u64 {
    assert_valid_quantity(quantity);
    quantity / constants::position_lot_size!()
}

fun assert_valid(order: &Order) {
    let quantity_lots = order.quantity_lots();
    assert!(order.id >> ORDER_ID_BITS == 0, EInvalidOrderId);
    assert!(order.entry_probability() <= constants::float_scaling!(), EInvalidEntryProbability);
    assert!(quantity_lots > 0, EInvalidQuantity);
    assert_valid_order_shape(order.min_strike_index(), order.max_strike_index(), order.leverage());
}

fun user_contribution_from_exposure_value(exposure_value: u64, leverage: u64): u64 {
    assert_valid_leverage(leverage);
    math::mul_div_round_up(exposure_value, constants::float_scaling!(), leverage)
}

fun entry_exposure_value(order: &Order): u64 {
    deepbook_math::mul(order.entry_probability(), order.quantity())
}

fun assert_valid_leverage(leverage: u64) {
    assert!(
        leverage == LEVERAGE_ONE_X
            || leverage == LEVERAGE_ONE_AND_HALF_X
            || leverage == LEVERAGE_TWO_X
            || leverage == LEVERAGE_TWO_AND_HALF_X
            || leverage == LEVERAGE_THREE_X,
        EInvalidLeverage,
    );
}

fun leverage_rank(leverage: u64): u64 {
    if (leverage == LEVERAGE_THREE_X) {
        0
    } else if (leverage == LEVERAGE_TWO_AND_HALF_X) {
        1
    } else if (leverage == LEVERAGE_TWO_X) {
        2
    } else if (leverage == LEVERAGE_ONE_AND_HALF_X) {
        3
    } else if (leverage == LEVERAGE_ONE_X) {
        4
    } else {
        abort EInvalidLeverage
    }
}

fun leverage_from_rank(rank: u64): u64 {
    if (rank == 0) {
        LEVERAGE_THREE_X
    } else if (rank == 1) {
        LEVERAGE_TWO_AND_HALF_X
    } else if (rank == 2) {
        LEVERAGE_TWO_X
    } else if (rank == 3) {
        LEVERAGE_ONE_AND_HALF_X
    } else if (rank == 4) {
        LEVERAGE_ONE_X
    } else {
        abort EInvalidLeverage
    }
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
