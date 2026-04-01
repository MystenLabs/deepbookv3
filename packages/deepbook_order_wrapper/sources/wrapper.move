// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_order_wrapper::wrapper;

use deepbook::{
    balance_manager::{BalanceManager, TradeProof},
    order_info::OrderInfo,
    pool::Pool,
};
use sui::clock::Clock;

/// Returns true when `order_id` is still open for `balance_manager` in `pool`.
public fun order_exists<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
    order_id: u128,
): bool {
    pool.account_open_orders(balance_manager).contains(&order_id)
}

/// Best-effort cancel. Missing orders do not abort the transaction.
public fun cancel_order_if_exists<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    clock: &Clock,
    ctx: &TxContext,
): bool {
    if (!order_exists(pool, balance_manager, order_id)) {
        return false
    };

    pool.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
    true
}

/// Best-effort batch cancel. Returns the number of orders that were actually canceled.
public fun cancel_orders_if_exist<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let mut i = 0;
    let mut canceled = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        if (cancel_order_if_exists(pool, balance_manager, trade_proof, order_ids[i], clock, ctx)) {
            canceled = canceled + 1;
        };
        i = i + 1;
    };

    canceled
}

/// Best-effort place for limit orders. Insufficient balances return `none()`.
public fun place_limit_order_if_balance_sufficient<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
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
): Option<OrderInfo> {
    if (
        !pool.can_place_limit_order(
            balance_manager,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            clock,
        )
    ) {
        return option::none()
    };

    option::some(
        pool.place_limit_order(
            balance_manager,
            trade_proof,
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
        ),
    )
}

/// Best-effort place for market orders. Insufficient balances return `none()`.
public fun place_market_order_if_balance_sufficient<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): Option<OrderInfo> {
    if (!pool.can_place_market_order(balance_manager, quantity, is_bid, pay_with_deep, clock)) {
        return option::none()
    };

    option::some(
        pool.place_market_order(
            balance_manager,
            trade_proof,
            client_order_id,
            self_matching_option,
            quantity,
            is_bid,
            pay_with_deep,
            clock,
            ctx,
        ),
    )
}

/// Best-effort replace flow for limit orders. Missing cancel targets do not abort,
/// and placement only happens when the post-cancel balance is sufficient.
public fun cancel_order_if_exists_then_place_limit_order_if_possible<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
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
): (bool, Option<OrderInfo>) {
    let canceled = cancel_order_if_exists(
        pool,
        balance_manager,
        trade_proof,
        order_id,
        clock,
        ctx,
    );
    let placed = place_limit_order_if_balance_sufficient(
        pool,
        balance_manager,
        trade_proof,
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
    );

    (canceled, placed)
}

/// Best-effort replace flow for market orders. Missing cancel targets do not abort,
/// and placement only happens when the post-cancel balance is sufficient.
public fun cancel_order_if_exists_then_place_market_order_if_possible<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): (bool, Option<OrderInfo>) {
    let canceled = cancel_order_if_exists(
        pool,
        balance_manager,
        trade_proof,
        order_id,
        clock,
        ctx,
    );
    let placed = place_market_order_if_balance_sufficient(
        pool,
        balance_manager,
        trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    (canceled, placed)
}
