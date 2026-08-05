// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pyth Pro entrypoints for `margin_manager`.
///
/// Pyth Core is being replaced by a separately published package, so its
/// `PriceInfoObject` is a distinct Move type from the legacy one and the frozen
/// signatures in `margin_manager` can never accept it. The Pyth Pro surface therefore lives
/// here, under the same function names. Each entry reads the Pro feed and delegates
/// to the shared core in `margin_manager`, so both feeds run identical logic.
module deepbook_margin::margin_manager_pro;

use deepbook::{order_info::OrderInfo, pool::Pool};
use deepbook_margin::{
    margin_constants,
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle,
    tpsl::{Condition, PendingOrder}
};
use pyth_pro::price_info::PriceInfoObject as PriceInfoObjectPro;
use std::type_name;
use sui::{clock::Clock, coin::Coin};

public fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObjectPro,
    quote_price_info_object: &PriceInfoObjectPro,
    registry: &MarginRegistry,
    conditional_order_id: u64,
    condition: Condition,
    pending_order: PendingOrder,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.add_conditional_order_core(
        pool,
        oracle::read_price_pro<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        conditional_order_id,
        condition,
        pending_order,
        clock,
        ctx,
    )
}

public fun execute_conditional_orders_v2<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_price_info_object: &PriceInfoObjectPro,
    quote_price_info_object: &PriceInfoObjectPro,
    registry: &MarginRegistry,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &TxContext,
): vector<OrderInfo> {
    self.execute_conditional_orders_v2_core(
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_pro<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        max_orders_to_execute,
        clock,
        ctx,
    )
}

public fun execute_conditional_orders_v3<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_price_info_object: &PriceInfoObjectPro,
    quote_price_info_object: &PriceInfoObjectPro,
    registry: &MarginRegistry,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<OrderInfo> {
    self.execute_conditional_orders_v3_core(
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_pro<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        max_orders_to_execute,
        clock,
        ctx,
    )
}

public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    coin: Coin<DepositAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let event_reading = if (
        !margin_manager::emits_collateral_event<BaseAsset, QuoteAsset, DepositAsset>()
    ) {
        option::none()
    } else if (
        type_name::with_defining_ids<DepositAsset>() == type_name::with_defining_ids<BaseAsset>()
    ) {
        option::some(oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock))
    } else {
        option::some(oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock))
    };

    self.deposit_core(
        registry,
        event_reading,
        coin,
        clock,
        ctx,
    )
}

public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let (risk_base_reading, risk_quote_reading) = if (
        self.withdraw_needs_risk_check(base_margin_pool, quote_margin_pool)
    ) {
        (
            option::some(oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };
    let (event_base_reading, event_quote_reading) = if (
        margin_manager::emits_collateral_event<BaseAsset, QuoteAsset, WithdrawAsset>()
    ) {
        (
            option::some(oracle::read_price_pro_unsafe<BaseAsset>(base_oracle, registry)),
            option::some(oracle::read_price_pro_unsafe<QuoteAsset>(quote_oracle, registry)),
        )
    } else {
        (option::none(), option::none())
    };

    self.withdraw_core(
        registry,
        base_margin_pool,
        quote_margin_pool,
        risk_base_reading,
        risk_quote_reading,
        event_base_reading,
        event_quote_reading,
        pool,
        withdraw_amount,
        clock,
        ctx,
    )
}

public fun borrow_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.borrow_base_core(
        registry,
        base_margin_pool,
        oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        loan_amount,
        clock,
        ctx,
    )
}

public fun borrow_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.borrow_quote_core(
        registry,
        quote_margin_pool,
        oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        loan_amount,
        clock,
        ctx,
    )
}

public fun liquidate<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    mut repay_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    self.liquidate_core(
        registry,
        oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock),
        margin_pool,
        pool,
        repay_coin,
        clock,
        ctx,
    )
}

public fun risk_ratio<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    // No debt means no oracle is needed: `assets_in_debt_unit` short-circuits and the
    // ratio is MAX regardless of price. Returning here keeps a stale feed from
    // breaking a read-only query, as it did before Pyth Pro.
    if (self.has_no_margin_pool()) return margin_constants::max_risk_ratio();

    self.risk_ratio_core(
        registry,
        oracle::read_price_pro<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_pro<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

public fun risk_ratio_unsafe<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    // No debt means no oracle is needed: `assets_in_debt_unit` short-circuits and the
    // ratio is MAX regardless of price. Returning here keeps a stale feed from
    // breaking a read-only query, as it did before Pyth Pro.
    if (self.has_no_margin_pool()) return margin_constants::max_risk_ratio();

    self.risk_ratio_core(
        registry,
        oracle::read_price_pro_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_pro_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

public fun manager_state<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): (ID, ID, u64, u64, u64, u64, u64, u64, u8, u64, u8, u64, u64, u64) {
    self.manager_state_core(
        registry,
        oracle::read_price_pro_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_pro_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

public fun manager_states<BaseAsset, QuoteAsset>(
    margin_managers: &vector<MarginManager<BaseAsset, QuoteAsset>>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectPro,
    quote_oracle: &PriceInfoObjectPro,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): (
    vector<ID>,
    vector<ID>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u8>,
    vector<u64>,
    vector<u8>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
) {
    margin_manager::manager_states_core<BaseAsset, QuoteAsset>(
        margin_managers,
        registry,
        oracle::read_price_pro_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_pro_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}
