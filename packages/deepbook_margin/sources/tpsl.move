// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::tpsl;

use deepbook::constants;
use deepbook::math;
use deepbook::order_info::OrderInfo;
use deepbook::pool::Pool;
use deepbook_margin::margin_manager::MarginManager;
use deepbook_margin::margin_registry::{
    MarginRegistry,
    MaintainerCap,
    MarginAdminCap,
    MarginPoolCap
};
use deepbook_margin::margin_state::{Self, State};
use deepbook_margin::oracle::calculate_oracle_usd_price;
use deepbook_margin::pool_proxy::{place_limit_order_conditional, place_market_order_conditional};
use deepbook_margin::position_manager::{Self, PositionManager};
use deepbook_margin::protocol_config::{InterestConfig, MarginPoolConfig, ProtocolConfig};
use deepbook_margin::protocol_fees::{Self, ProtocolFees, SupplyReferral};
use pyth::price_info::PriceInfoObject;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// === Errors ===
const EIncorrectPool: u64 = 1;

// === Structs ===
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

/// Price of the base asset in the quote asset.
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

public fun execute_pending_orders<BaseAsset, QuoteAsset>(
    self: &mut TakeProfitStopLoss<BaseAsset, QuoteAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &TxContext,
): vector<OrderInfo> {
    let current_price = current_price<BaseAsset, QuoteAsset>(
        base_price_info_object,
        quote_price_info_object,
        registry,
        clock,
    );
    let (keys, values) = self.pending_orders.into_keys_values();
    let valid_indices = values.find_indices!(|value| {
        (value.condition.trigger_is_below && current_price < value.condition.trigger_price) ||
        (!value.condition.trigger_is_below && current_price > value.condition.trigger_price)
    });

    let mut order_infos = vector[];
    valid_indices.do!(|index| {
        let pending_order = values[index].pending_order;
        let order_info = place_pending_limit_order<BaseAsset, QuoteAsset>(
            registry,
            margin_manager,
            pool,
            &pending_order,
            clock,
            ctx,
        );
        order_infos.push_back(order_info);
    });

    // remove the pending orders
    valid_indices.do!(|index| {
        let pending_order_identifier = keys[index];
        self.pending_orders.remove(&pending_order_identifier);
    });

    order_infos
}

fun place_pending_limit_order<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    pending_order: &PendingOrder,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    assert!(pending_order.pool_id == pool.id(), EIncorrectPool);

    if (pending_order.is_limit_order) {
        place_limit_order_conditional<BaseAsset, QuoteAsset>(
            registry,
            margin_manager,
            pool,
            pending_order.client_order_id,
            pending_order.order_type.destroy_some(),
            pending_order.self_matching_option,
            pending_order.price.destroy_some(),
            pending_order.quantity,
            pending_order.is_bid,
            pending_order.pay_with_deep,
            pending_order.expire_timestamp.destroy_some(),
            clock,
            ctx,
        )
    } else {
        place_market_order_conditional<BaseAsset, QuoteAsset>(
            registry,
            margin_manager,
            pool,
            pending_order.client_order_id,
            pending_order.self_matching_option,
            pending_order.quantity,
            pending_order.is_bid,
            pending_order.pay_with_deep,
            clock,
            ctx,
        )
    }
}

fun new_condition(trigger_is_below: bool, trigger_price: u64): Condition {
    Condition {
        trigger_is_below,
        trigger_price,
    }
}
