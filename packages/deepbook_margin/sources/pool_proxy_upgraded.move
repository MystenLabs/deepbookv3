// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth's upgraded Core entrypoints for `pool_proxy`.
///
/// Pyth Core is being replaced by a separately published package, so its
/// `PriceInfoObject` is a distinct Move type from the legacy one and the frozen
/// signatures in `pool_proxy` can never accept it. The upgraded surface therefore lives
/// here, under the same function names. Each entry reads the upgraded feed and delegates
/// to the shared core in `pool_proxy`, so both feeds run identical logic.
module deepbook_margin::pool_proxy_upgraded;

use deepbook::{order_info::OrderInfo, pool::Pool};
use deepbook_margin::{
    margin_manager::MarginManager,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle,
    pool_proxy
};
use pyth_upgraded::price_info::PriceInfoObject as PriceInfoObjectUpgraded;
use sui::clock::Clock;

/// Twin: `pool_proxy::update_current_price`. Edit both.
public fun update_current_price<BaseAsset, QuoteAsset>(
    registry: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObjectUpgraded,
    quote_price_info_object: &PriceInfoObjectUpgraded,
    clock: &Clock,
) {
    // Safe reads enforce staleness, feed id, and EWMA. Price conversion enforces confidence.
    let base_reading = oracle::read_price_upgraded<BaseAsset>(
        base_price_info_object,
        registry,
        clock,
    );
    let quote_reading = oracle::read_price_upgraded<QuoteAsset>(
        quote_price_info_object,
        registry,
        clock,
    );

    pool_proxy::update_current_price_core<BaseAsset, QuoteAsset>(
        registry,
        pool,
        base_reading,
        quote_reading,
        clock,
    )
}

/// Twin: `pool_proxy::place_limit_order_v2`. Edit both.
public fun place_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_limit_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_market_order_v2`. Edit both.
public fun place_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_market_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_reduce_only_limit_order_v2`. Edit both.
public fun place_reduce_only_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_limit_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_reduce_only_market_order_v2`. Edit both.
public fun place_reduce_only_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_market_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_reduce_only_market_order_and_repay_loan`. Edit both.
public fun place_reduce_only_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_market_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_reduce_only_limit_order_and_repay_loan`. Edit both.
public fun place_reduce_only_limit_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_limit_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Twin: `pool_proxy::place_market_order_and_repay_loan`. Edit both.
public fun place_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_market_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}
