// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook::math;
use deepbook_margin::{margin_registry::MarginRegistry, oracle::calculate_oracle_usd_price};
use pyth::price_info::PriceInfoObject;
use std::string::String;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

// === Errors ===

// === Structs ===
// TODO: instead of key being a String, could be a u64 or client order id?
public struct TakeProfitStopLoss<phantom BaseAsset, phantom QuoteAsset> has drop, store {
    pending_orders: VecMap<String, ConditionalOrder<BaseAsset, QuoteAsset>>,
}

public struct ConditionalOrder<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    condition: Condition,
    pending_order: PendingOrder,
}

public struct Condition has copy, drop, store {
    trigger_is_below: bool,
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
public fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut TakeProfitStopLoss<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    pending_order_identifier: String,
    trigger_price: u64,
    pending_order: PendingOrder,
    clock: &Clock,
) {
    let current_price = current_price<BaseAsset, QuoteAsset>(
        base_price_info_object,
        quote_price_info_object,
        registry,
        clock,
    );
    let trigger_is_below = trigger_price < current_price;
    let condition = new_condition(trigger_is_below, trigger_price);
    let pending_order = ConditionalOrder {
        condition,
        pending_order,
    };
    self.pending_orders.insert(pending_order_identifier, pending_order);
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

public fun cancel_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut TakeProfitStopLoss<BaseAsset, QuoteAsset>,
    pending_order_identifier: String,
) {
    self.pending_orders.remove(&pending_order_identifier);
}

public fun new<BaseAsset, QuoteAsset>(): TakeProfitStopLoss<BaseAsset, QuoteAsset> {
    TakeProfitStopLoss {
        pending_orders: vec_map::empty(),
    }
}

/// Price of the base asset in the quote asset.
/// TODO: account for decimals, so price matches the deepbook pool price, not just hardcoded to 9 decimals
public fun current_price<BaseAsset, QuoteAsset>(
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    clock: &Clock,
): u64 {
    let base_usd_price = calculate_oracle_usd_price<BaseAsset>(
        base_price_info_object,
        registry,
        clock,
    );
    let quote_usd_price = calculate_oracle_usd_price<QuoteAsset>(
        quote_price_info_object,
        registry,
        clock,
    );

    math::div(base_usd_price, quote_usd_price)
}

// === Read-Only Functions ===
public fun trigger_is_below<BaseAsset, QuoteAsset>(
    self: &ConditionalOrder<BaseAsset, QuoteAsset>,
): bool {
    self.condition.trigger_is_below
}

public fun trigger_price<BaseAsset, QuoteAsset>(
    self: &ConditionalOrder<BaseAsset, QuoteAsset>,
): u64 {
    self.condition.trigger_price
}

public fun pending_orders<BaseAsset, QuoteAsset>(
    self: &TakeProfitStopLoss<BaseAsset, QuoteAsset>,
): VecMap<String, ConditionalOrder<BaseAsset, QuoteAsset>> {
    self.pending_orders
}

public fun pending_order<BaseAsset, QuoteAsset>(
    self: &ConditionalOrder<BaseAsset, QuoteAsset>,
): &PendingOrder {
    &self.pending_order
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

// === Private Functions ===
fun new_condition(trigger_is_below: bool, trigger_price: u64): Condition {
    Condition {
        trigger_is_below,
        trigger_price,
    }
}
