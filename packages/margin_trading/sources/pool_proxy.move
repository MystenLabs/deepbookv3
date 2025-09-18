// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::pool_proxy;

use deepbook::{order_info::OrderInfo, pool::Pool};
use margin_trading::{
    margin_manager::MarginManager,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry
};
use std::type_name;
use sui::clock::Clock;
use token::deep::DEEP;

// === Errors ===
const ECannotStakeWithDeepMarginManager: u64 = 1;
const EPoolNotEnabledForMarginTrading: u64 = 2;
const EIncorrectDeepBookPool: u64 = 4;

// === Public Proxy Functions - Trading ===
/// Places a limit order in the pool.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
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
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);

    pool.place_limit_order(
        balance_manager,
        &trade_proof,
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

/// Places a market order in the pool.
public fun place_market_order<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);

    pool.place_market_order(
        balance_manager,
        &trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Places a reduce-only order in the pool. Used when margin trading is disabled.
public fun place_reduce_only_limit_order<BaseAsset, QuoteAsset, DebtAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
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
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    margin_manager.assert_place_reduce_only(margin_pool, is_bid);

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.place_limit_order(
        balance_manager,
        &trade_proof,
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

/// Places a reduce-only market order in the pool. Used when margin trading is disabled.
public fun place_reduce_only_market_order<BaseAsset, QuoteAsset, DebtAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    margin_manager.assert_place_reduce_only(margin_pool, is_bid);

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.place_market_order(
        balance_manager,
        &trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Modifies an order
public fun modify_order<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
    new_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.modify_order(
        balance_manager,
        &trade_proof,
        order_id,
        new_quantity,
        clock,
        ctx,
    )
}

/// Cancels an order
public fun cancel_order<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.cancel_order(
        balance_manager,
        &trade_proof,
        order_id,
        clock,
        ctx,
    );
}

/// Cancel multiple orders within a vector.
public fun cancel_orders<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.cancel_orders(
        balance_manager,
        &trade_proof,
        order_ids,
        clock,
        ctx,
    );
}

/// Cancels all orders for the given account.
public fun cancel_all_orders<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.cancel_all_orders(
        balance_manager,
        &trade_proof,
        clock,
        ctx,
    );
}

/// Withdraw settled amounts to balance_manager.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.withdraw_settled_amounts(
        balance_manager,
        &trade_proof,
    );
}

/// Stake DEEP tokens to the pool.
public fun stake<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    amount: u64,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let base_asset_type = type_name::with_defining_ids<BaseAsset>();
    let quote_asset_type = type_name::with_defining_ids<QuoteAsset>();
    let deep_asset_type = type_name::with_defining_ids<DEEP>();
    assert!(
        base_asset_type != deep_asset_type && quote_asset_type != deep_asset_type,
        ECannotStakeWithDeepMarginManager,
    );

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.stake(
        balance_manager,
        &trade_proof,
        amount,
        ctx,
    );
}

/// Unstake DEEP tokens from the pool.
public fun unstake<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.unstake(
        balance_manager,
        &trade_proof,
        ctx,
    );
}

/// Submit proposal using the margin manager.
public fun submit_proposal<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.submit_proposal(
        balance_manager,
        &trade_proof,
        taker_fee,
        maker_fee,
        stake_required,
        ctx,
    );
}

/// Vote on a proposal using the margin manager.
public fun vote<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    proposal_id: ID,
    ctx: &TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.vote(
        balance_manager,
        &trade_proof,
        proposal_id,
        ctx,
    );
}

public fun claim_rebates<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    pool.claim_rebates(balance_manager, &trade_proof, ctx);
}
