// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook_margin::margin_constants;
use deepbook_margin::margin_registry::MarginRegistry;
use deepbook_margin::oracle::calculate_price;
use pyth::price_info::PriceInfoObject;
use sui::clock::Clock;
use sui::event;
use sui::vec_map::VecMap;

// === Errors ===
const EInvalidCondition: u64 = 1;
const EConditionalOrderNotFound: u64 = 2;
const EMaxConditionalOrdersReached: u64 = 3;

// === Structs ===
public struct TakeProfitStopLoss has drop, store {
    conditional_orders: vector<ConditionalOrder>,
}

public struct ConditionalOrder has copy, drop, store {
    conditional_order_identifier: u64,
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
public fun conditional_orders_mut(self: &mut TakeProfitStopLoss): &mut vector<ConditionalOrder> {
    &mut self.conditional_orders
}

public fun conditional_orders(self: &TakeProfitStopLoss): vector<ConditionalOrder> {
    self.conditional_orders
}

public fun conditional_order(
    conditional_orders: &VecMap<u64, ConditionalOrder>,
    pending_order_identifier: u64,
): ConditionalOrder {
    *conditional_orders.get(&pending_order_identifier)
}

public fun conditional_order_identifier(conditional_order: &ConditionalOrder): u64 {
    conditional_order.conditional_order_identifier
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
        conditional_orders: vector[],
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
    clock: &Clock,
) {
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
        (trigger_below_price && trigger_price < current_price) || (!trigger_below_price && trigger_price > current_price),
        EInvalidCondition,
    );

    let conditional_order = ConditionalOrder {
        conditional_order_identifier,
        condition,
        pending_order,
    };
    assert!(
        self.conditional_orders.length() < margin_constants::max_conditional_orders(),
        EMaxConditionalOrdersReached,
    );
    self.conditional_orders.push_back(conditional_order);

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
    let index = self.conditional_orders.find_index!(|conditional_order| {
        conditional_order.conditional_order_identifier == conditional_order_identifier
    });
    assert!(index.is_some(), EConditionalOrderNotFound);
    let conditional_order_index = index.destroy_some();
    let conditional_order = self.conditional_orders[conditional_order_index];

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

    self.conditional_orders.remove(conditional_order_index);
}
