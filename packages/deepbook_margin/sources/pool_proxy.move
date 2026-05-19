// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::pool_proxy;

use deepbook::{math, order_info::OrderInfo, pool::Pool};
use deepbook_margin::{
    margin_manager::MarginManager,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::clock::Clock;
use token::deep::DEEP;

// === Errors ===
const ECannotStakeWithDeepMarginManager: u64 = 1;
const EPoolNotEnabledForMarginTrading: u64 = 2;
const ENotReduceOnlyOrder: u64 = 3;
const EIncorrectDeepBookPool: u64 = 4;
const ENoLiquidityInOrderbook: u64 = 5;
/// Post-trade risk ratio dropped below `min_borrow_risk_ratio`.
/// Raised by the v2 order placement entries when the manager would be left
/// in a state borrowing would be forbidden from.
const EInsufficientRiskRatioAfterTrade: u64 = 6;
/// Reduce-only fill leaked value to the counterparty: the manager's
/// risk_ratio after the trade is lower than before. Reduce-only orders must
/// monotonically improve (or hold) solvency.
const EReduceOnlyMustImproveRiskRatio: u64 = 7;
/// Deprecated v1 entry was called. Use the `_v2` variant which enforces a
/// post-trade risk_ratio invariant.
const EDeprecatedUseV2: u64 = 8;

// === Public Functions - Price Protection ===
/// Updates the current price for a pool using safe oracle price calculation.
/// Anyone can call this to update the price oracle used for order validation.
public fun update_current_price<BaseAsset, QuoteAsset>(
    registry: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
) {
    // Calculate current price using safe oracle (with staleness, confidence, EWMA checks)
    let price = oracle::calculate_price<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );

    registry.update_current_price(pool.id(), price, clock);
}

// === Public Proxy Functions - Trading (v1 — DEPRECATED) ===
//
// The v1 trading entries below preserve their on-chain signatures so the v5
// package upgrade type-checks against existing dependents, but every body is
// replaced with `abort EDeprecatedUseV2`. Callers must migrate to the `_v2`
// variants further down, which add a post-trade `risk_ratio` invariant that
// prevents an order placement from leaving the manager in a state borrowing
// would already be forbidden from.

/// DEPRECATED. Use `place_limit_order_v2`.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    _registry: &MarginRegistry,
    _margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    _pool: &mut Pool<BaseAsset, QuoteAsset>,
    _client_order_id: u64,
    _order_type: u8,
    _self_matching_option: u8,
    _price: u64,
    _quantity: u64,
    _is_bid: bool,
    _pay_with_deep: bool,
    _expire_timestamp: u64,
    _clock: &Clock,
    _ctx: &TxContext,
): OrderInfo {
    abort EDeprecatedUseV2
}

/// DEPRECATED. Use `place_market_order_v2`.
public fun place_market_order<BaseAsset, QuoteAsset>(
    _registry: &MarginRegistry,
    _margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    _pool: &mut Pool<BaseAsset, QuoteAsset>,
    _client_order_id: u64,
    _self_matching_option: u8,
    _quantity: u64,
    _is_bid: bool,
    _pay_with_deep: bool,
    _clock: &Clock,
    _ctx: &TxContext,
): OrderInfo {
    abort EDeprecatedUseV2
}

/// DEPRECATED. Use `place_reduce_only_limit_order_v2`.
public fun place_reduce_only_limit_order<BaseAsset, QuoteAsset, DebtAsset>(
    _registry: &MarginRegistry,
    _margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    _pool: &mut Pool<BaseAsset, QuoteAsset>,
    _margin_pool: &MarginPool<DebtAsset>,
    _client_order_id: u64,
    _order_type: u8,
    _self_matching_option: u8,
    _price: u64,
    _quantity: u64,
    _is_bid: bool,
    _pay_with_deep: bool,
    _expire_timestamp: u64,
    _clock: &Clock,
    _ctx: &TxContext,
): OrderInfo {
    abort EDeprecatedUseV2
}

/// DEPRECATED. Use `place_reduce_only_market_order_v2`.
public fun place_reduce_only_market_order<BaseAsset, QuoteAsset, DebtAsset>(
    _registry: &MarginRegistry,
    _margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    _pool: &mut Pool<BaseAsset, QuoteAsset>,
    _margin_pool: &MarginPool<DebtAsset>,
    _client_order_id: u64,
    _self_matching_option: u8,
    _quantity: u64,
    _is_bid: bool,
    _pay_with_deep: bool,
    _clock: &Clock,
    _ctx: &TxContext,
): OrderInfo {
    abort EDeprecatedUseV2
}

// === Public Proxy Functions - Trading (v2) ===
//
// Each v2 entry mirrors its v1 counterpart and additionally recomputes
// `risk_ratio` after the order settles (using Pyth via the public
// `MarginManager::risk_ratio` helper). For non-reduce-only entries the
// post-trade ratio must be at least `min_borrow_risk_ratio` — same threshold
// the borrow path enforces, so trading cannot push a manager below where
// borrowing was already forbidden. Skipped when the manager has no debt
// (nothing to be insolvent against).
//
// For reduce-only entries the post-trade ratio must be `>= risk_ratio_before`
// (monotonic improvement). The borrow-floor check would trap users in the
// 1.1–1.25 danger zone (between liquidation and borrow thresholds), who are
// exactly the people who most need to wind down via reduce-only. Monotonic
// avoids that trap and additionally catches within-band value leak that the
// borrow-floor check allows.

/// Places a limit order in the pool.
public fun place_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
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
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);

    registry.assert_price(pool.id(), price, is_bid, clock);
    let expire_timestamp = registry.clamp_expire_timestamp(pool.id(), expire_timestamp, clock);

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    let order_info = pool.place_limit_order(
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
    );

    assert_post_trade_solvent(
        margin_manager,
        registry,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        clock,
    );

    order_info
}

/// Places a market order in the pool.
public fun place_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);

    let (effective_price, _) = calculate_effective_price(
        pool,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
    );
    registry.assert_price(pool.id(), effective_price, is_bid, clock);

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    let order_info = pool.place_market_order(
        balance_manager,
        &trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    assert_post_trade_solvent(
        margin_manager,
        registry,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        clock,
    );

    order_info
}

/// Places a reduce-only order in the pool. Used when margin trading is disabled.
public fun place_reduce_only_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
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

    registry.assert_price(pool.id(), price, is_bid, clock);
    let expire_timestamp = registry.clamp_expire_timestamp(pool.id(), expire_timestamp, clock);

    let (base_debt, quote_debt) = if (margin_manager.has_base_debt()) {
        margin_manager.calculate_debts(base_margin_pool, clock)
    } else {
        margin_manager.calculate_debts(quote_margin_pool, clock)
    };
    let (base_asset, quote_asset) = margin_manager.calculate_assets<BaseAsset, QuoteAsset>(
        pool,
    );

    assert!(
        (is_bid && base_debt > base_asset && quantity <= base_debt - base_asset) ||
            (!is_bid && quote_debt > quote_asset && math::mul(quantity, price) <= quote_debt - quote_asset),
        ENotReduceOnlyOrder,
    );

    // The reduce-only quantity predicate above already guarantees the manager
    // has debt on the relevant side, so `risk_ratio` is safe to compute (no
    // divide-by-zero in `risk_ratio_int`).
    let risk_ratio_before = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    let order_info = pool.place_limit_order(
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
    );

    assert_reduce_only_monotonic(
        margin_manager,
        registry,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        clock,
        risk_ratio_before,
    );

    order_info
}

/// Places a reduce-only market order in the pool. Used when margin trading is disabled.
public fun place_reduce_only_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
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

    let (base_debt, quote_debt) = if (margin_manager.has_base_debt()) {
        margin_manager.calculate_debts(base_margin_pool, clock)
    } else {
        margin_manager.calculate_debts(quote_margin_pool, clock)
    };
    let (base_asset, quote_asset) = margin_manager.calculate_assets<BaseAsset, QuoteAsset>(
        pool,
    );

    let (effective_price, quote_quantity) = calculate_effective_price(
        pool,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
    );

    // The order is a bid, and quantity is less than the net base debt.
    // The order is a ask, and quote quantity is less than the net quote debt.
    assert!(
        (is_bid && base_debt > base_asset && quantity <= base_debt - base_asset) ||
            (!is_bid && quote_debt > quote_asset && quote_quantity <= quote_debt - quote_asset),
        ENotReduceOnlyOrder,
    );

    registry.assert_price(pool.id(), effective_price, is_bid, clock);

    // The reduce-only quantity predicate above already guarantees the manager
    // has debt on the relevant side, so `risk_ratio` is safe to compute (no
    // divide-by-zero in `risk_ratio_int`).
    let risk_ratio_before = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );

    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_trading_mut(ctx);

    let order_info = pool.place_market_order(
        balance_manager,
        &trade_proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    assert_reduce_only_monotonic(
        margin_manager,
        registry,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_oracle,
        quote_oracle,
        clock,
        risk_ratio_before,
    );

    order_info
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

/// Withdraw settled amounts to balance_manager permissionlessly.
/// Anyone can call this function to settle balances for a margin manager.
public fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
) {
    registry.load_inner();
    margin_manager.withdraw_settled_amounts_permissionless_int(pool);
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

// === Internal Functions ===

/// Calculates the effective price for a market order by querying the pool.
/// Returns (effective_price, quote_amount) where quote_amount is quote_in for bids and quote_out for asks.
fun calculate_effective_price<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
): (u64, u64) {
    if (is_bid) {
        let (base_out, quote_in, _) = pool.get_quote_quantity_in(quantity, pay_with_deep, clock);
        assert!(base_out > 0, ENoLiquidityInOrderbook);
        (math::div(quote_in, base_out), quote_in)
    } else {
        let (base_out, quote_out, _) = pool.get_quote_quantity_out(quantity, clock);
        let base_used = quantity - base_out;
        assert!(base_used > 0, ENoLiquidityInOrderbook);
        (math::div(quote_out, base_used), quote_out)
    }
}

/// Asserts the manager remains above the borrow-floor risk ratio after a
/// trade. Skipped when the manager has no debt (nothing to be insolvent
/// against). Threshold reuses `min_borrow_risk_ratio` so trading cannot push
/// a manager below the level borrowing is already gated at.
fun assert_post_trade_solvent<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    clock: &Clock,
) {
    if (
        margin_manager.borrowed_base_shares() == 0
        && margin_manager.borrowed_quote_shares() == 0
    ) {
        return
    };

    let risk_ratio_after = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    assert!(
        risk_ratio_after >= registry.min_borrow_risk_ratio(pool.id()),
        EInsufficientRiskRatioAfterTrade,
    );
}

/// Asserts a reduce-only fill did not worsen the manager's risk ratio.
/// Caller is responsible for ensuring the manager had debt at the entry —
/// the reduce-only quantity predicate (`base_debt > base_asset` or
/// `quote_debt > quote_asset`) already aborts the txn for no-debt managers,
/// so `risk_ratio_before` is always a real ratio by the time this fires.
fun assert_reduce_only_monotonic<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    clock: &Clock,
    risk_ratio_before: u64,
) {
    let risk_ratio_after = margin_manager.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    assert!(risk_ratio_after >= risk_ratio_before, EReduceOnlyMustImproveRiskRatio);
}
