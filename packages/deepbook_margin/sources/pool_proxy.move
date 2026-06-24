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
/// Post-trade risk ratio dropped below `min_open_risk_ratio` (the opening
/// solvency floor between liquidation and the borrow floor). Raised by the v2
/// order placement entries when an opening trade would leave the manager in the
/// liquidatable zone.
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
// post-trade ratio must be at least `min_open_risk_ratio` — a floor between
// liquidation and the borrow floor, so a max-leverage open can absorb the
// opening trade's spread (which lands the ratio just under `min_borrow`)
// without aborting, while staying above the liquidatable zone. Skipped when
// the manager has no debt (nothing to be insolvent against).
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
    let (base_asset, _) = margin_manager.calculate_assets<BaseAsset, QuoteAsset>(pool);
    let (_, _, min_size) = pool.pool_book_params();

    // Reduce-only. The ask (closing a long) may sell up to the full base the
    // manager holds, so a long can be fully unwound — selling base can only
    // shrink base exposure, never flip it short. The bid (covering a short) is
    // capped at the net short (`base_debt - base_asset`), but never below one
    // `min_size` order, so a sub-lot net debt (e.g. accrued-interest dust) can
    // still be covered instead of leaving the position stuck. The monotonic
    // risk-ratio check below guards value leak.
    assert!(
        (is_bid && base_debt > base_asset && quantity <= (base_debt - base_asset).max(min_size)) ||
            (!is_bid && quote_debt > 0 && quantity <= base_asset),
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

/// Places a reduce-only market order in the pool. Used when margin trading is
/// disabled.
///
/// Superseded by `place_reduce_only_market_order_and_repay_loan`. A market
/// (taker) fill always pays the spread, which lowers the oracle-valued
/// `risk_ratio` while the debt is unchanged, so the swap-only monotonic check
/// here rejects essentially every taker fill. The `_and_repay` variant
/// deleverages with the proceeds so the net-state ratio actually improves. Kept
/// callable for existing integrators; its symmetric net-debt cap is retained as
/// legacy (the live entries cap the ask on gross base held instead).
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

    // Reduce-only (legacy net-debt cap on both sides). The bid is never capped
    // below one `min_size` order, so a sub-lot net debt can still be covered.
    // This entry is superseded for closing (see the doc above); the floor only
    // keeps it consistent with the live reduce-only entries.
    let (_, _, min_size) = pool.pool_book_params();
    assert!(
        (is_bid && base_debt > base_asset && quantity <= (base_debt - base_asset).max(min_size)) ||
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

/// Atomically winds down a leveraged position: places a reduce-only market
/// order, repays the loan with the proceeds, then requires the net (post-repay)
/// risk ratio to be at least the pre-trade ratio.
///
/// The post-repay check is the point. A market close pays the spread, which
/// alone lowers the oracle-valued ratio (debt is unchanged until repay) and
/// would abort the plain reduce-only path. Repaying first deleverages and
/// absorbs the slippage (still bounded by the `assert_price` band), and lets a
/// manager in the `liquidation..min_borrow` band climb out — it cannot reach
/// the borrow floor in a single swap.
public fun place_reduce_only_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    registry.load_inner();
    assert!(margin_manager.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);

    let (base_debt, quote_debt) = if (margin_manager.has_base_debt()) {
        margin_manager.calculate_debts(base_margin_pool, clock)
    } else {
        margin_manager.calculate_debts(quote_margin_pool, clock)
    };
    let (base_asset, _) = margin_manager.calculate_assets<BaseAsset, QuoteAsset>(pool);
    let (_, _, min_size) = pool.pool_book_params();

    let (effective_price, _) = calculate_effective_price(
        pool,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
    );

    // Reduce-only. The ask (closing a long) may sell up to the full base the
    // manager holds — selling can only shrink base exposure, never flip it
    // short. The bid (covering a short) is capped at the net short
    // (`base_debt - base_asset`), but never below one `min_size` order, so a
    // sub-lot net debt (e.g. accrued-interest dust) can still be covered instead
    // of leaving the position stuck. The net-state monotonic check below guards
    // value leak.
    assert!(
        (is_bid && base_debt > base_asset && quantity <= (base_debt - base_asset).max(min_size)) ||
            (!is_bid && quote_debt > 0 && quantity <= base_asset),
        ENotReduceOnlyOrder,
    );

    registry.assert_price(pool.id(), effective_price, is_bid, clock);

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

    // place_market_order settles the taker fill into the manager's balance, so
    // the proceeds are drawable. Repay the debt side with that balance.
    if (margin_manager.has_base_debt()) {
        margin_manager.repay_base(registry, base_margin_pool, option::none(), clock, ctx);
    } else {
        margin_manager.repay_quote(registry, quote_margin_pool, option::none(), clock, ctx);
    };

    // Net-state solvency: if debt remains, the close must not have worsened the
    // ratio. A full repay clears the debt, so the check is skipped.
    if (
        margin_manager.borrowed_base_shares() > 0
        || margin_manager.borrowed_quote_shares() > 0
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
    };

    order_info
}

/// Atomically places a market order and repays the loan with the proceeds,
/// gating post-repay solvency on `min_open_risk_ratio`. This is the everyday
/// close / deleverage tool: unlike `place_market_order_v2`, the repay runs
/// *before* the solvency check, so the deleverage credit lets a position close
/// cleanly even in the `liquidation..min_borrow` band — a full close drives debt
/// to 0 (`risk_ratio` MAX), which always passes.
///
/// Not reduce-only: there is no quantity cap, so a close may overshoot the debt
/// (e.g. round past accrued-interest dust that isn't lot-aligned). That is safe
/// — the repay only ever reduces debt, zero debt has no bad-debt risk to the
/// lending pool, any surplus base/quote is the manager's own holding, and
/// `assert_price` still bounds slippage. The repay is the safety mechanism here,
/// not a quantity cap. Requires margin trading enabled; in reduce-only mode use
/// `place_reduce_only_market_order_and_repay_loan`.
public fun place_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    registry.load_inner();
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

    // Repay the debt side with the settled proceeds *before* the solvency check,
    // so a deleveraging close passes where the bare swap would not. Skipped when
    // the manager has no debt.
    if (margin_manager.has_base_debt()) {
        margin_manager.repay_base(registry, base_margin_pool, option::none(), clock, ctx);
    } else if (margin_manager.borrowed_quote_shares() > 0) {
        margin_manager.repay_quote(registry, quote_margin_pool, option::none(), clock, ctx);
    };

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

/// Asserts the manager remains solvent after an opening (risk-increasing)
/// trade. Skipped when the manager has no debt (nothing to be insolvent
/// against). Threshold is `min_open_risk_ratio` — between liquidation and the
/// borrow floor — so a max-leverage open can absorb the opening trade's spread
/// (which lands the ratio just under `min_borrow`) without aborting, while
/// staying above the liquidatable zone.
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
        risk_ratio_after >= registry.min_open_risk_ratio(pool.id()),
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
