// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook::math;
use deepbook_margin::margin_registry::MarginRegistry;
use pyth::price_info::PriceInfoObject;
use sui::clock::Clock;
use sui::vec_map::{Self, VecMap};

// === Errors ===
const EInvalidCondition: u64 = 1;

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
    pool_id: ID,
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

// === Public Functions ===
public fun add_conditional_order(
    self: &mut TakeProfitStopLoss,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    pending_order_identifier: u64,
    condition: Condition,
    pending_order: PendingOrder,
    clock: &Clock,
) {
    let current_price = 0;
    // let current_price = current_price(
    //     base_price_info_object,
    //     quote_price_info_object,
    //     registry,
    //     clock,
    // );
    let trigger_below_price = condition.trigger_below_price;
    let trigger_price = condition.trigger_price;

    // If order is triggered below trigger_price, trigger_price must be lower than current price
    // If order is triggered above trigger_price, trigger_price must be higher than current price
    assert!(
        (trigger_below_price && trigger_price < current_price) || (!trigger_below_price && trigger_price > current_price),
        EInvalidCondition,
    );

    let conditional_order = ConditionalOrder {
        condition,
        pending_order,
    };
    self.conditional_orders.insert(pending_order_identifier, conditional_order);
}

public fun new_condition(trigger_below_price: bool, trigger_price: u64): Condition {
    Condition {
        trigger_below_price,
        trigger_price,
    }
}

public fun new_pending_limit_order(
    pool_id: ID,
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
        pool_id,
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
    pool_id: ID,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
): PendingOrder {
    PendingOrder {
        pool_id,
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

public fun cancel_conditional_order(self: &mut TakeProfitStopLoss, pending_order_identifier: u64) {
    self.conditional_orders.remove(&pending_order_identifier);
}

public fun new(): TakeProfitStopLoss {
    TakeProfitStopLoss {
        conditional_orders: vec_map::empty(),
    }
}

// === Read-Only Functions ===
public fun conditional_orders_mut(
    self: &mut TakeProfitStopLoss,
): &mut VecMap<u64, ConditionalOrder> {
    &mut self.conditional_orders
}

public fun conditional_orders(self: &TakeProfitStopLoss): VecMap<u64, ConditionalOrder> {
    self.conditional_orders
}

public fun conditional_order(
    conditional_orders: &VecMap<u64, ConditionalOrder>,
    pending_order_identifier: u64,
): ConditionalOrder {
    *conditional_orders.get(&pending_order_identifier)
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

public fun pool_id(pending_order: &PendingOrder): ID {
    pending_order.pool_id
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
