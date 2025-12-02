// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook::constants;
use deepbook_margin::{margin_constants, margin_registry::MarginRegistry, oracle::calculate_price};
use pyth::price_info::PriceInfoObject;
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};

// === Errors ===
const EInvalidCondition: u64 = 1;
const EConditionalOrderNotFound: u64 = 2;
const EMaxConditionalOrdersReached: u64 = 3;
const EInvalidTPSLOrderType: u64 = 4;
const EDuplicateConditionalOrderIdentifier: u64 = 5;
const EInvalidQuantity: u64 = 6;
const EInvalidPrice: u64 = 7;
const EInvalidExpireTimestamp: u64 = 8;

// === Structs ===
public struct TakeProfitStopLoss has drop, store {
    conditional_orders: VecMap<u64, ConditionalOrder>,
}

public struct ConditionalOrder has copy, drop, store {
    condition: Condition,
    pending_order: PendingOrder,
}

public struct Condition has copy, drop, store {
    trigger_below_price: bool,
    trigger_price: u64,
}

public struct PendingOrder has copy, drop, store {
    is_limit_order: bool,
    client_order_id: u64,
    order_type: Option<u8>,
    self_matching_option: u8,
    price: Option<u64>,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: Option<u64>,
}

// === Events ===
public struct ConditionalOrderAdded has copy, drop {
    manager_id: ID,
    conditional_order_identifier: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

public struct ConditionalOrderCancelled has copy, drop {
    manager_id: ID,
    conditional_order_identifier: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

public struct ConditionalOrderExecuted has copy, drop {
    manager_id: ID,
    conditional_order_identifier: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

// === Public Functions ===
public fun new_condition(trigger_below_price: bool, trigger_price: u64): Condition {
    Condition {
        trigger_below_price,
        trigger_price,
    }
}

/// Creates a new pending limit order.
/// Order type must be no restriction or immediate or cancel.
public fun new_pending_limit_order(
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
): PendingOrder {
    assert!(quantity > 0, EInvalidQuantity);
    assert!(
        order_type == constants::no_restriction() || order_type == constants::immediate_or_cancel(),
        EInvalidTPSLOrderType,
    );
    PendingOrder {
        is_limit_order: true,
        client_order_id,
        order_type: option::some(order_type),
        self_matching_option,
        price: option::some(price),
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp: option::some(expire_timestamp),
    }
}

public fun new_pending_market_order(
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
): PendingOrder {
    assert!(quantity > 0, EInvalidQuantity);
    PendingOrder {
        is_limit_order: false,
        client_order_id,
        order_type: option::none(),
        self_matching_option,
        price: option::none(),
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp: option::none(),
    }
}

// === Read-Only Functions ===
public fun conditional_orders(self: &TakeProfitStopLoss): &VecMap<u64, ConditionalOrder> {
    &self.conditional_orders
}

public fun get_conditional_order(
    self: &TakeProfitStopLoss,
    conditional_order_identifier: &u64,
): &ConditionalOrder {
    self.conditional_orders.get(conditional_order_identifier)
}

public fun condition(conditional_order: &ConditionalOrder): Condition {
    conditional_order.condition
}

public fun pending_order(conditional_order: &ConditionalOrder): PendingOrder {
    conditional_order.pending_order
}

public fun trigger_below_price(condition: &Condition): bool {
    condition.trigger_below_price
}

public fun trigger_price(condition: &Condition): u64 {
    condition.trigger_price
}

public fun client_order_id(pending_order: &PendingOrder): u64 {
    pending_order.client_order_id
}

public fun order_type(pending_order: &PendingOrder): Option<u8> {
    pending_order.order_type
}

public fun self_matching_option(pending_order: &PendingOrder): u8 {
    pending_order.self_matching_option
}

public fun price(pending_order: &PendingOrder): Option<u64> {
    pending_order.price
}

public fun quantity(pending_order: &PendingOrder): u64 {
    pending_order.quantity
}

public fun is_bid(pending_order: &PendingOrder): bool {
    pending_order.is_bid
}

public fun pay_with_deep(pending_order: &PendingOrder): bool {
    pending_order.pay_with_deep
}

public fun expire_timestamp(pending_order: &PendingOrder): Option<u64> {
    pending_order.expire_timestamp
}

public fun is_limit_order(pending_order: &PendingOrder): bool {
    pending_order.is_limit_order
}

// === public(package) functions ===
public(package) fun new(): TakeProfitStopLoss {
    TakeProfitStopLoss {
        conditional_orders: vec_map::empty(),
    }
}

public(package) fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    conditional_order_identifier: u64,
    condition: Condition,
    pending_order: PendingOrder,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    clock: &Clock,
) {
    assert!(pending_order.quantity >= min_size, EInvalidQuantity);
    assert!(pending_order.quantity % lot_size == 0, EInvalidQuantity);
    if (pending_order.is_limit_order()) {
        let price = *pending_order.price.borrow();
        assert!(price >= constants::min_price() && price <= constants::max_price(), EInvalidPrice);
        assert!(price % tick_size == 0, EInvalidPrice);
        let expire_timestamp = *pending_order.expire_timestamp.borrow();
        assert!(expire_timestamp > clock.timestamp_ms(), EInvalidExpireTimestamp);
    };
    let current_price = calculate_price<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );

    let trigger_below_price = condition.trigger_below_price;
    let trigger_price = condition.trigger_price;

    // If order is triggered below trigger_price, trigger_price must be lower than current price
    // If order is triggered above trigger_price, trigger_price must be higher than current price
    assert!(
        (trigger_below_price && trigger_price < current_price) ||
            (!trigger_below_price && trigger_price > current_price),
        EInvalidCondition,
    );

    assert!(
        self.conditional_orders.length() < margin_constants::max_conditional_orders(),
        EMaxConditionalOrdersReached,
    );
    assert!(
        !self.conditional_orders.contains(&conditional_order_identifier),
        EDuplicateConditionalOrderIdentifier,
    );

    let conditional_order = ConditionalOrder {
        condition,
        pending_order,
    };
    self.conditional_orders.insert(conditional_order_identifier, conditional_order);

    event::emit(ConditionalOrderAdded {
        manager_id,
        conditional_order_identifier,
        conditional_order,
        timestamp: clock.timestamp_ms(),
    });
}

public(package) fun cancel_conditional_order(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    conditional_order_identifier: u64,
    clock: &Clock,
) {
    self.remove_conditional_order(manager_id, conditional_order_identifier, true, clock);
}

public(package) fun remove_executed_conditional_order(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    conditional_order_identifier: u64,
    clock: &Clock,
) {
    self.remove_conditional_order(manager_id, conditional_order_identifier, false, clock);
}

public(package) fun remove_conditional_order(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    conditional_order_identifier: u64,
    is_cancel: bool,
    clock: &Clock,
) {
    assert!(
        self.conditional_orders.contains(&conditional_order_identifier),
        EConditionalOrderNotFound,
    );
    let (_, conditional_order) = self.conditional_orders.remove(&conditional_order_identifier);

    if (is_cancel) {
        event::emit(ConditionalOrderCancelled {
            manager_id,
            conditional_order_identifier,
            conditional_order,
            timestamp: clock.timestamp_ms(),
        });
    } else {
        event::emit(ConditionalOrderExecuted {
            manager_id,
            conditional_order_identifier,
            conditional_order,
            timestamp: clock.timestamp_ms(),
        });
    };
}
