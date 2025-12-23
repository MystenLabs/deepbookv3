// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook::{constants, pool::Pool};
use deepbook_margin::{margin_constants, margin_registry::MarginRegistry, oracle::calculate_price};
use pyth::price_info::PriceInfoObject;
use sui::{clock::Clock, event};

// === Errors ===
const EInvalidCondition: u64 = 1;
const EConditionalOrderNotFound: u64 = 2;
const EMaxConditionalOrdersReached: u64 = 3;
const EInvalidTPSLOrderType: u64 = 4;
const EDuplicateConditionalOrderIdentifier: u64 = 5;
const EInvalidOrderParams: u64 = 6;

// === Structs ===
/// Stores conditional orders in two sorted vectors for efficient execution.
/// trigger_below: Orders that trigger when price < trigger_price (sorted high to low)
/// trigger_above: Orders that trigger when price > trigger_price (sorted low to high)
public struct TakeProfitStopLoss has drop, store {
    trigger_below: vector<ConditionalOrder>,
    trigger_above: vector<ConditionalOrder>,
}

public struct ConditionalOrder has copy, drop, store {
    conditional_order_id: u64,
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
    conditional_order_id: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

public struct ConditionalOrderCancelled has copy, drop {
    manager_id: ID,
    conditional_order_id: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

public struct ConditionalOrderExecuted has copy, drop {
    manager_id: ID,
    pool_id: ID,
    conditional_order_id: u64,
    conditional_order: ConditionalOrder,
    timestamp: u64,
}

public struct ConditionalOrderInsufficientFunds has copy, drop {
    manager_id: ID,
    conditional_order_id: u64,
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
public fun trigger_below_orders(self: &TakeProfitStopLoss): &vector<ConditionalOrder> {
    &self.trigger_below
}

public fun trigger_above_orders(self: &TakeProfitStopLoss): &vector<ConditionalOrder> {
    &self.trigger_above
}

public fun num_conditional_orders(self: &TakeProfitStopLoss): u64 {
    (self.trigger_below.length() + self.trigger_above.length()) as u64
}

public fun conditional_order_id(conditional_order: &ConditionalOrder): u64 {
    conditional_order.conditional_order_id
}

public fun get_conditional_order(
    self: &TakeProfitStopLoss,
    conditional_order_id: u64,
): Option<ConditionalOrder> {
    let mut i = 0;
    while (i < self.trigger_below.length()) {
        let order = &self.trigger_below[i];
        if (order.conditional_order_id == conditional_order_id) {
            return option::some(*order)
        };
        i = i + 1;
    };

    i = 0;
    while (i < self.trigger_above.length()) {
        let order = &self.trigger_above[i];
        if (order.conditional_order_id == conditional_order_id) {
            return option::some(*order)
        };
        i = i + 1;
    };

    option::none()
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
        trigger_below: vector::empty(),
        trigger_above: vector::empty(),
    }
}

public(package) fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut TakeProfitStopLoss,
    pool: &Pool<BaseAsset, QuoteAsset>,
    manager_id: ID,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    conditional_order_id: u64,
    condition: Condition,
    pending_order: PendingOrder,
    clock: &Clock,
) {
    // Validate order parameters
    if (pending_order.is_limit_order()) {
        let price = *pending_order.price.borrow();
        let expire_timestamp = *pending_order.expire_timestamp.borrow();
        assert!(
            pool.check_limit_order_params(price, pending_order.quantity, expire_timestamp, clock),
            EInvalidOrderParams,
        );
    } else {
        assert!(pool.check_market_order_params(pending_order.quantity), EInvalidOrderParams);
    };

    let current_price = calculate_price<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );

    let trigger_below_price = condition.trigger_below_price;
    let trigger_price = condition.trigger_price;

    // Validate trigger condition (use <= and >= for consistency with execute_conditional_orders)
    assert!(
        (trigger_below_price && trigger_price <= current_price) ||
            (!trigger_below_price && trigger_price >= current_price),
        EInvalidCondition,
    );

    assert!(
        self.num_conditional_orders() < margin_constants::max_conditional_orders(),
        EMaxConditionalOrdersReached,
    );

    assert!(
        self.get_conditional_order(conditional_order_id).is_none(),
        EDuplicateConditionalOrderIdentifier,
    );

    let conditional_order = ConditionalOrder {
        conditional_order_id,
        condition,
        pending_order,
    };

    // Insert in sorted order (using >= and <= for stable sort)
    if (trigger_below_price) {
        self.trigger_below.push_back(conditional_order);
        self
            .trigger_below
            .insertion_sort_by!(|a, b| a.condition.trigger_price >= b.condition.trigger_price);
    } else {
        self.trigger_above.push_back(conditional_order);
        self
            .trigger_above
            .insertion_sort_by!(|a, b| a.condition.trigger_price <= b.condition.trigger_price);
    };

    event::emit(ConditionalOrderAdded {
        manager_id,
        conditional_order_id,
        conditional_order,
        timestamp: clock.timestamp_ms(),
    });
}

public(package) fun cancel_conditional_order(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    conditional_order_id: u64,
    clock: &Clock,
) {
    let conditional_order = self.find_and_remove_order(conditional_order_id);
    assert!(conditional_order.is_some(), EConditionalOrderNotFound);

    event::emit(ConditionalOrderCancelled {
        manager_id,
        conditional_order_id,
        conditional_order: conditional_order.destroy_some(),
        timestamp: clock.timestamp_ms(),
    });
}

public(package) fun cancel_all_conditional_orders(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    clock: &Clock,
) {
    let timestamp = clock.timestamp_ms();

    // Emit events for all trigger_below orders
    self.trigger_below.do!(|conditional_order| {
        event::emit(ConditionalOrderCancelled {
            manager_id,
            conditional_order_id: conditional_order.conditional_order_id,
            conditional_order,
            timestamp,
        });
    });

    // Emit events for all trigger_above orders
    self.trigger_above.do!(|conditional_order| {
        event::emit(ConditionalOrderCancelled {
            manager_id,
            conditional_order_id: conditional_order.conditional_order_id,
            conditional_order,
            timestamp,
        });
    });

    // Clear both vectors
    self.trigger_below = vector[];
    self.trigger_above = vector[];
}

public(package) fun remove_executed_conditional_order(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    pool_id: ID,
    conditional_order_id: u64,
    clock: &Clock,
) {
    let conditional_order = find_and_remove_order(self, conditional_order_id);
    assert!(conditional_order.is_some(), EConditionalOrderNotFound);

    event::emit(ConditionalOrderExecuted {
        manager_id,
        pool_id,
        conditional_order_id,
        conditional_order: conditional_order.destroy_some(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Batch remove multiple executed orders efficiently
public(package) fun remove_executed_conditional_orders(
    self: &mut TakeProfitStopLoss,
    manager_id: ID,
    pool_id: ID,
    conditional_order_ids: vector<u64>,
    clock: &Clock,
) {
    let timestamp = clock.timestamp_ms();

    // Partition trigger_below into orders to keep vs remove
    let (remove_below, keep_below) = self.trigger_below.partition!(|order| {
        conditional_order_ids.contains(&order.conditional_order_id)
    });
    self.trigger_below = keep_below;

    // Partition trigger_above into orders to keep vs remove
    let (remove_above, keep_above) = self.trigger_above.partition!(|order| {
        conditional_order_ids.contains(&order.conditional_order_id)
    });
    self.trigger_above = keep_above;

    // Emit events for removed orders
    remove_below.do!(|conditional_order| {
        event::emit(ConditionalOrderExecuted {
            manager_id,
            pool_id,
            conditional_order_id: conditional_order.conditional_order_id,
            conditional_order,
            timestamp,
        });
    });

    remove_above.do!(|conditional_order| {
        event::emit(ConditionalOrderExecuted {
            manager_id,
            pool_id,
            conditional_order_id: conditional_order.conditional_order_id,
            conditional_order,
            timestamp,
        });
    });
}

public(package) fun emit_insufficient_funds_event(
    self: &TakeProfitStopLoss,
    manager_id: ID,
    conditional_order_id: u64,
    clock: &Clock,
) {
    let conditional_order = self.get_conditional_order(conditional_order_id);
    if (conditional_order.is_some()) {
        event::emit(ConditionalOrderInsufficientFunds {
            manager_id,
            conditional_order_id,
            conditional_order: conditional_order.destroy_some(),
            timestamp: clock.timestamp_ms(),
        });
    };
}

/// Returns reference to trigger_below vector (sorted high to low by trigger price)
public(package) fun trigger_below(self: &TakeProfitStopLoss): &vector<ConditionalOrder> {
    &self.trigger_below
}

/// Returns reference to trigger_above vector (sorted low to high by trigger price)
public(package) fun trigger_above(self: &TakeProfitStopLoss): &vector<ConditionalOrder> {
    &self.trigger_above
}

/// Find and remove an order by ID from either vector
fun find_and_remove_order(
    self: &mut TakeProfitStopLoss,
    conditional_order_id: u64,
): Option<ConditionalOrder> {
    // Search in trigger_below
    let mut i = 0;
    while (i < self.trigger_below.length()) {
        if (self.trigger_below[i].conditional_order_id == conditional_order_id) {
            return option::some(self.trigger_below.remove(i))
        };
        i = i + 1;
    };

    // Search in trigger_above
    i = 0;
    while (i < self.trigger_above.length()) {
        if (self.trigger_above[i].conditional_order_id == conditional_order_id) {
            return option::some(self.trigger_above.remove(i))
        };
        i = i + 1;
    };

    option::none()
}
