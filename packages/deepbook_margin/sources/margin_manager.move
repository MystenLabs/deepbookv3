// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::margin_manager;

use deepbook::{
    balance_manager::{
        Self,
        BalanceManager,
        TradeCap,
        DepositCap,
        WithdrawCap,
        TradeProof,
        DeepBookPoolReferral
    },
    constants,
    math,
    order_info::OrderInfo,
    pool::Pool,
    registry::Registry
};
use deepbook_margin::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle::{
        calculate_target_currency,
        calculate_target_currency_unsafe,
        get_pyth_price,
        get_pyth_price_unsafe,
        calculate_price,
        calculate_price_unsafe
    },
    tpsl::{Self, TakeProfitStopLoss, PendingOrder, Condition, ConditionalOrder}
};
use pyth::price_info::PriceInfoObject;
use std::{string::String, type_name::{Self, TypeName}};
use sui::{clock::Clock, coin::Coin, event, vec_map::{Self, VecMap}};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 1;
const EMarginTradingNotAllowedInPool: u64 = 2;
const EInvalidMarginManagerOwner: u64 = 3;
const ECannotHaveLoanInMoreThanOneMarginPool: u64 = 4;
const EIncorrectDeepBookPool: u64 = 5;
const EDeepbookPoolNotAllowedForLoan: u64 = 6;
const EBorrowRiskRatioExceeded: u64 = 7;
const EWithdrawRiskRatioExceeded: u64 = 8;
const ECannotLiquidate: u64 = 9;
const EIncorrectMarginPool: u64 = 10;
const EInvalidManagerForSharing: u64 = 11;
const EInvalidDebtAsset: u64 = 12;
const ERepayAmountTooLow: u64 = 13;
const ERepaySharesTooLow: u64 = 14;
const EPoolNotEnabledForMarginTrading: u64 = 15;
const EConditionalOrderNotFound: u64 = 16;
const EOutstandingDebt: u64 = 17;

// === Structs ===
/// Witness type for authorizing MarginManager to call protected features of the DeepBook
public struct MarginApp has drop {}

/// A shared object that wraps a `BalanceManager` and provides the necessary capabilities to deposit, withdraw, and trade.
public struct MarginManager<phantom BaseAsset, phantom QuoteAsset> has key {
    id: UID,
    owner: address,
    deepbook_pool: ID,
    margin_pool_id: Option<ID>, // If none, margin manager has no current loans in any margin pool
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    trade_cap: TradeCap,
    borrowed_base_shares: u64,
    borrowed_quote_shares: u64,
    take_profit_stop_loss: TakeProfitStopLoss,
    extra_fields: VecMap<String, u64>,
}

/// Hot potato to ensure manager is shared during creation
public struct ManagerInitializer {
    margin_manager_id: ID,
}

// === Events ===
/// Event emitted when a new margin manager is created.
public struct MarginManagerCreatedEvent has copy, drop {
    margin_manager_id: ID,
    balance_manager_id: ID,
    deepbook_pool_id: ID,
    owner: address,
    timestamp: u64,
}

/// Event emitted when loan is borrowed
public struct LoanBorrowedEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    loan_amount: u64,
    loan_shares: u64,
    timestamp: u64,
}

/// Event emitted when loan is repaid
public struct LoanRepaidEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    repay_amount: u64,
    repay_shares: u64,
    timestamp: u64,
}

/// Event emitted when margin manager is liquidated
public struct LiquidationEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    liquidation_amount: u64,
    pool_reward: u64,
    pool_default: u64,
    risk_ratio: u64,
    remaining_base_asset: u64,
    remaining_quote_asset: u64,
    remaining_base_debt: u64,
    remaining_quote_debt: u64,
    base_pyth_price: u64,
    base_pyth_decimals: u8,
    quote_pyth_price: u64,
    quote_pyth_decimals: u8,
    timestamp: u64,
}

/// Event emitted when user deposits collateral asset (either base or quote) into margin manager
public struct DepositCollateralEvent has copy, drop {
    margin_manager_id: ID,
    amount: u64,
    asset: TypeName,
    pyth_price: u64,
    pyth_decimals: u8,
    timestamp: u64,
}

/// Event emitted when user withdraws collateral asset (either base or quote) from margin manager
public struct WithdrawCollateralEvent has copy, drop {
    margin_manager_id: ID,
    amount: u64,
    asset: TypeName,
    withdraw_base_asset: bool,
    remaining_base_asset: u64,
    remaining_quote_asset: u64,
    remaining_base_debt: u64,
    remaining_quote_debt: u64,
    base_pyth_price: u64,
    base_pyth_decimals: u8,
    quote_pyth_price: u64,
    quote_pyth_decimals: u8,
    timestamp: u64,
}

// === Functions - Take Profit Stop Loss ===
/// Add a conditional order.
/// Specifies the conditions under which the order is triggered and the pending order to be placed.
public fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    conditional_order_id: u64,
    condition: Condition,
    pending_order: PendingOrder,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    let manager_id = self.id();
    assert!(pool.id() == self.deepbook_pool(), EIncorrectDeepBookPool);
    self
        .take_profit_stop_loss
        .add_conditional_order<BaseAsset, QuoteAsset>(
            pool,
            manager_id,
            base_price_info_object,
            quote_price_info_object,
            registry,
            conditional_order_id,
            condition,
            pending_order,
            clock,
        );
}

/// Cancel all conditional orders.
public fun cancel_all_conditional_orders<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.validate_owner(ctx);
    let manager_id = self.id();
    self.take_profit_stop_loss.cancel_all_conditional_orders(manager_id, clock);
}

/// Cancel a conditional order.
public fun cancel_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    conditional_order_id: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.validate_owner(ctx);
    let manager_id = self.id();
    self.take_profit_stop_loss.cancel_conditional_order(manager_id, conditional_order_id, clock);
}

/// Execute conditional orders and return the order infos.
/// This is a permissionless function that can be called by anyone.
public fun execute_conditional_orders<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    registry: &MarginRegistry,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &TxContext,
): vector<OrderInfo> {
    assert!(pool.id() == self.deepbook_pool(), EIncorrectDeepBookPool);
    let current_price = calculate_price<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );

    let mut order_infos = vector[];
    let mut executed_ids = vector[];
    let mut expired_ids = vector[];
    let mut insufficient_funds_ids = vector[];

    // Collect orders to process (to avoid borrow conflicts)
    let mut orders_to_process = vector[];

    // Collect trigger_below orders (sorted high to low)
    let mut i = 0;
    while (i < self.take_profit_stop_loss.trigger_below().length()) {
        let conditional_order = &self.take_profit_stop_loss.trigger_below()[i];

        // Break early if price doesn't trigger
        if (current_price >= conditional_order.condition().trigger_price()) {
            break
        };

        orders_to_process.push_back(*conditional_order);
        i = i + 1;
    };

    // Collect trigger_above orders (sorted low to high)
    i = 0;
    while (i < self.take_profit_stop_loss.trigger_above().length()) {
        let conditional_order = &self.take_profit_stop_loss.trigger_above()[i];

        // Break early if price doesn't trigger
        if (current_price <= conditional_order.condition().trigger_price()) {
            break
        };

        orders_to_process.push_back(*conditional_order);
        i = i + 1;
    };

    // Process collected orders
    self.process_collected_orders(
        pool,
        registry,
        orders_to_process,
        &mut order_infos,
        &mut executed_ids,
        &mut expired_ids,
        &mut insufficient_funds_ids,
        max_orders_to_execute,
        clock,
        ctx,
    );

    let manager_id = self.id();
    let pool_id = pool.id();

    insufficient_funds_ids.do!(|id| {
        self.take_profit_stop_loss.emit_insufficient_funds_event(manager_id, id, clock);
    });

    let mut cancelled_ids = expired_ids;
    cancelled_ids.append(insufficient_funds_ids);
    // Canceled orders will include both expired and insufficient funds orders
    cancelled_ids.do!(|id| {
        self.take_profit_stop_loss.cancel_conditional_order(manager_id, id, clock);
    });

    self
        .take_profit_stop_loss
        .remove_executed_conditional_orders(
            manager_id,
            pool_id,
            executed_ids,
            clock,
        );

    order_infos
}

// === Public Functions - Margin Manager ===
/// Creates a new margin manager and shares it.
public fun new<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    margin_registry: &mut MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let manager = new_margin_manager(pool, deepbook_registry, margin_registry, clock, ctx);
    let margin_manager_id = manager.id();
    transfer::share_object(manager);

    margin_manager_id
}

/// Creates a new margin manager and returns it along with an initializer.
/// The initializer is used to ensure the margin manager is shared after creation.
public fun new_with_initializer<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    margin_registry: &mut MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (MarginManager<BaseAsset, QuoteAsset>, ManagerInitializer) {
    let manager = new_margin_manager(pool, deepbook_registry, margin_registry, clock, ctx);
    let initializer = ManagerInitializer {
        margin_manager_id: manager.id(),
    };

    (manager, initializer)
}

/// Shares the margin manager. The initializer is dropped in the process.
public fun share<BaseAsset, QuoteAsset>(
    manager: MarginManager<BaseAsset, QuoteAsset>,
    initializer: ManagerInitializer,
) {
    assert!(manager.id() == initializer.margin_manager_id, EInvalidManagerForSharing);
    transfer::share_object(manager);

    let ManagerInitializer {
        margin_manager_id: _,
    } = initializer;
}

/// Unregister the margin manager from the margin registry.
public fun unregister_margin_manager<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_registry: &mut MarginRegistry,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    assert!(self.borrowed_base_shares == 0, EOutstandingDebt);
    assert!(self.borrowed_quote_shares == 0, EOutstandingDebt);
    assert!(self.margin_pool_id.is_none(), EOutstandingDebt);

    margin_registry.remove_margin_manager(self.id(), ctx);
}

/// Set the referral for the margin manager.
public fun set_margin_manager_referral<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    referral_cap: &DeepBookPoolReferral,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    self.balance_manager.set_balance_manager_referral(referral_cap, &self.trade_cap);
}

/// Unset the referral for the margin manager.
public fun unset_margin_manager_referral<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    self.balance_manager.unset_balance_manager_referral(pool_id, &self.trade_cap);
}

// === Public Functions - Margin Manager ===
/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    coin: Coin<DepositAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    self.validate_owner(ctx);

    let deposit_amount = coin.value();
    self.deposit_int<BaseAsset, QuoteAsset, DepositAsset>(coin, ctx);

    let deposit_asset_type = type_name::with_defining_ids<DepositAsset>();
    let deposit_base_asset = deposit_asset_type == type_name::with_defining_ids<BaseAsset>();
    let deposit_quote_asset = deposit_asset_type == type_name::with_defining_ids<QuoteAsset>();
    // We return early here, because there is no need to emit a deposit collateral event if neither the base asset
    // nor the quote asset is deposited. This handles the case for DEEP deposits, when DEEP is not part of the base
    // or quote assets.
    if (!deposit_base_asset && !deposit_quote_asset) return;

    let (pyth_price, pyth_decimals) = if (deposit_base_asset) {
        get_pyth_price<BaseAsset>(base_oracle, registry, clock)
    } else {
        get_pyth_price<QuoteAsset>(quote_oracle, registry, clock)
    };

    event::emit(DepositCollateralEvent {
        margin_manager_id: self.id(),
        amount: deposit_amount,
        asset: deposit_asset_type,
        pyth_price,
        pyth_decimals,
        timestamp: clock.timestamp_ms(),
    });
}

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit.
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(pool.id() == self.deepbook_pool(), EIncorrectDeepBookPool);

    let balance_manager = &mut self.balance_manager;
    let withdraw_cap = &self.withdraw_cap;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        withdraw_cap,
        withdraw_amount,
        ctx,
    );

    if (self.margin_pool_id.contains(&base_margin_pool.id())) {
        let risk_ratio = self.risk_ratio_int(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            base_margin_pool,
            clock,
        );
        assert!(registry.can_withdraw(pool.id(), risk_ratio), EWithdrawRiskRatioExceeded);
    } else if (self.margin_pool_id.contains(&quote_margin_pool.id())) {
        let risk_ratio = self.risk_ratio_int(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            quote_margin_pool,
            clock,
        );
        assert!(registry.can_withdraw(pool.id(), risk_ratio), EWithdrawRiskRatioExceeded);
    };

    let withdraw_asset_type = type_name::with_defining_ids<WithdrawAsset>();
    let withdraw_base_asset = withdraw_asset_type == type_name::with_defining_ids<BaseAsset>();
    let withdraw_quote_asset = withdraw_asset_type == type_name::with_defining_ids<QuoteAsset>();
    // We return early here, because there is no need to emit a withdraw collateral event if neither the base asset
    // nor the quote asset is withdrawn. This handles the case for DEEP withdrawals, when DEEP is not part of the base
    // or quote assets.
    if (!withdraw_base_asset && !withdraw_quote_asset) return coin;

    let (
        _,
        _,
        _,
        remaining_base_asset,
        remaining_quote_asset,
        remaining_base_debt,
        remaining_quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        _,
        _,
        _,
    ) = self.manager_state(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );

    event::emit(WithdrawCollateralEvent {
        margin_manager_id: self.id(),
        amount: withdraw_amount,
        asset: withdraw_asset_type,
        withdraw_base_asset,
        remaining_base_asset,
        remaining_quote_asset,
        remaining_base_debt,
        remaining_quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        timestamp: clock.timestamp_ms(),
    });

    coin
}

/// Borrow the base asset using the margin manager.
public fun borrow_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);
    assert!(pool.id() == self.deepbook_pool, EIncorrectDeepBookPool);
    assert!(self.can_borrow(base_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        base_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    let (coin, borrowed_shares) = base_margin_pool.borrow(loan_amount, clock, ctx);
    self.borrowed_base_shares = self.borrowed_base_shares + borrowed_shares;
    self.margin_pool_id = option::some(base_margin_pool.id());
    self.deposit_int<BaseAsset, QuoteAsset, BaseAsset>(coin, ctx);
    let risk_ratio = self.risk_ratio_int(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        clock,
    );
    assert!(registry.can_borrow(pool.id(), risk_ratio), EBorrowRiskRatioExceeded);

    event::emit(LoanBorrowedEvent {
        margin_manager_id: self.id(),
        margin_pool_id: base_margin_pool.id(),
        loan_amount,
        loan_shares: borrowed_shares,
        timestamp: clock.timestamp_ms(),
    });
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(registry.pool_enabled(pool), EPoolNotEnabledForMarginTrading);
    assert!(pool.id() == self.deepbook_pool, EIncorrectDeepBookPool);
    assert!(self.can_borrow(quote_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        quote_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    let (coin, borrowed_shares) = quote_margin_pool.borrow(loan_amount, clock, ctx);
    self.borrowed_quote_shares = self.borrowed_quote_shares + borrowed_shares;
    self.margin_pool_id = option::some(quote_margin_pool.id());
    self.deposit_int<BaseAsset, QuoteAsset, QuoteAsset>(coin, ctx);
    let risk_ratio = self.risk_ratio_int(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        quote_margin_pool,
        clock,
    );
    assert!(registry.can_borrow(pool.id(), risk_ratio), EBorrowRiskRatioExceeded);

    event::emit(LoanBorrowedEvent {
        margin_manager_id: self.id(),
        margin_pool_id: quote_margin_pool.id(),
        loan_amount,
        loan_shares: borrowed_shares,
        timestamp: clock.timestamp_ms(),
    });
}

/// Repay the base asset loan using the margin manager.
/// Returns the total amount repaid
public fun repay_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BaseAsset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        amount,
        clock,
        ctx,
    )
}

/// Repay the quote asset loan using the margin manager.
/// Returns the total amount repaid
public fun repay_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<QuoteAsset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        amount,
        clock,
        ctx,
    )
}

// === Public Functions - Liquidation - Receive Assets After Liquidation ===
public fun liquidate<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    mut repay_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    // 1. Check that we can liquidate, cancel all open orders.
    assert!(self.deepbook_pool == pool.id(), EIncorrectDeepBookPool);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);
    let risk_ratio = self.risk_ratio_int(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        margin_pool,
        clock,
    );
    assert!(registry.can_liquidate(pool.id(), risk_ratio), ECannotLiquidate);
    assert!(repay_coin.value() >= margin_constants::min_liquidation_repay(), ERepayAmountTooLow);
    let trade_proof = self.trade_proof(ctx);
    pool.withdraw_settled_amounts(&mut self.balance_manager, &trade_proof);
    pool.cancel_all_orders(&mut self.balance_manager, &trade_proof, clock, ctx);

    // 2. Calculate the maximum debt that can be repaid. The margin manager can be in three scenarios:
    // a) Assets <= Debt + user_reward: Full liquidation, repay as much debt as possible, lending pool may incur bad debt.
    // b) Debt + user_reward < Assets <= Debt + user_reward + pool_reward: There are enough assets to cover the debt, but pool may not get full rewards.
    // c) Debt + user_reward + pool_reward < Assets: There are enough assets to cover everything. We may not need to liquidate the full position.
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let debt = margin_pool.borrow_shares_to_amount(borrowed_shares, clock); // 350 USDC debt
    let debt_is_base =
        type_name::with_defining_ids<DebtAsset>() == type_name::with_defining_ids<BaseAsset>();
    let (assets_in_debt_unit, base_asset, quote_asset) = self.assets_in_debt_unit(
        registry,
        pool,
        base_oracle,
        quote_oracle,
        clock,
    ); // SUI/USDC pool. We have 90 SUI and 40 USDC, 350 USDC debt. This should be 400 USDC. (assume 1 SUI = 4 USDC)

    let liquidation_reward_with_user_pool =
        constants::float_scaling() + registry.user_liquidation_reward(pool.id()) + registry.pool_liquidation_reward(pool.id()); // 1.05

    let target_ratio = registry.target_liquidation_risk_ratio(pool.id()); // 1.25
    let numerator = math::mul(target_ratio, debt) - assets_in_debt_unit; // 1.25 * 350 - 400 = 437.5 - 400 = 37.5
    let denominator = target_ratio - liquidation_reward_with_user_pool; // 1.25 - 1.05 = 0.2
    let debt_repay = math::div(numerator, denominator); // 37.5 / 0.2 = 187.5
    // We have to pay the minimum between our current debt and the debt required to reach the target ratio.
    // In other words, if our assets are low, we pay off all debt (full liquidation)
    // if our assets are high, we pay off some of the debt (partial liquidation)
    let debt_repay = debt_repay.min(debt); // 187.5
    let debt_with_reward = math::mul(debt_repay, liquidation_reward_with_user_pool); // 187.5 * 1.05 = 196.875
    let debt_can_repay_with_rewards = debt_with_reward.min(assets_in_debt_unit); // 196.875
    let max_repay = math::div(debt_can_repay_with_rewards, liquidation_reward_with_user_pool); // 196.875 / 1.05 = 187.5
    let liquidation_reward_with_pool =
        constants::float_scaling() + registry.pool_liquidation_reward(pool.id()); // 1.03 (assume 3% pool reward, 2% user reward)

    let input_coin_without_pool_reward = math::div(
        repay_coin.value(),
        liquidation_reward_with_pool,
    ); // 100 / 1.03 = 97.087
    let repay_amount = max_repay.min(input_coin_without_pool_reward); // 97.087
    let repay_amount_with_pool_reward = math::mul(repay_amount, liquidation_reward_with_pool); // 97.087 * 1.03 = 100

    let repay_shares = if (risk_ratio < constants::float_scaling() && repay_amount == max_repay) {
        borrowed_shares
    } else {
        math::mul(
            borrowed_shares,
            math::div(repay_amount, debt),
        )
    }; // Assume index 2, so borrowed_shares = 350/2 = 175. 97.087 / 350 = 0.2774 * 175 = 48.545 shares being repaid (97.087 USDC is repayment)
    assert!(repay_shares > 0, ERepaySharesTooLow);
    let (debt_repaid, pool_reward, pool_default) = margin_pool.repay_liquidation(
        repay_shares,
        repay_coin.split(repay_amount_with_pool_reward, ctx),
        clock,
    );
    // 97.087 debt repaid, pool reward is 100 - 97.087 = 2.913 (3%), pool_default is 0
    // We only default if this is a full liquidation

    if (debt_is_base) {
        self.borrowed_base_shares = self.borrowed_base_shares - repay_shares;
    } else {
        self.borrowed_quote_shares = self.borrowed_quote_shares - repay_shares;
    };

    // Clear margin_pool_id if fully liquidated
    if (self.borrowed_base_shares == 0 && self.borrowed_quote_shares == 0) {
        self.margin_pool_id = option::none();
    };

    // repay_amount * 1.05 is what the user should receive back, since the user provided both the repayment and pool reward
    // user should receive as much assets possible in the debt asset first, then the collateral asset

    let mut out_amount = math::mul(repay_amount, liquidation_reward_with_user_pool); // 97.087 * 1.05 = 101.941

    let (base_coin, quote_coin) = if (debt_is_base) {
        let base_out = out_amount.min(base_asset);
        out_amount = out_amount - base_out;
        let max_quote_out = calculate_target_currency<BaseAsset, QuoteAsset>(
            registry,
            base_oracle,
            quote_oracle,
            out_amount,
            clock,
        );
        let quote_out = max_quote_out.min(quote_asset);
        let base_coin = self.liquidation_withdraw(
            base_out,
            ctx,
        );
        let quote_coin = self.liquidation_withdraw(
            quote_out,
            ctx,
        );
        (base_coin, quote_coin)
    } else {
        let quote_out = out_amount.min(quote_asset);
        out_amount = out_amount - quote_out; // 101.941 - 40 = 61.941
        let max_base_out = calculate_target_currency<QuoteAsset, BaseAsset>(
            registry,
            quote_oracle,
            base_oracle,
            out_amount,
            clock,
        );
        let base_out = max_base_out.min(base_asset);
        let base_coin = self.liquidation_withdraw(
            base_out,
            ctx,
        );
        let quote_coin = self.liquidation_withdraw(
            quote_out,
            ctx,
        );
        (base_coin, quote_coin)
    };
    // We have 40 USDC which is used first in the second loop. Then SUI to reach the total of 101.941 USDC.

    let (remaining_base_asset, remaining_quote_asset) = self.calculate_assets(pool);
    let (remaining_base_debt, remaining_quote_debt) = if (self.margin_pool_id.is_some()) {
        self.calculate_debts(margin_pool, clock)
    } else {
        (0, 0)
    };
    let (base_pyth_price, base_pyth_decimals) = get_pyth_price<BaseAsset>(
        base_oracle,
        registry,
        clock,
    );
    let (quote_pyth_price, quote_pyth_decimals) = get_pyth_price<QuoteAsset>(
        quote_oracle,
        registry,
        clock,
    );

    event::emit(LiquidationEvent {
        margin_manager_id: self.id(),
        margin_pool_id: margin_pool.id(),
        liquidation_amount: debt_repaid,
        pool_reward,
        pool_default,
        risk_ratio,
        remaining_base_asset,
        remaining_quote_asset,
        remaining_base_debt,
        remaining_quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        timestamp: clock.timestamp_ms(),
    });

    (base_coin, quote_coin, repay_coin)
}

// Returns the risk ratio of the margin manager given the corresponding margin pools.
public fun risk_ratio<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    let debt_is_base = self.borrowed_base_shares > 0;
    if (debt_is_base) {
        self.risk_ratio_int(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            base_margin_pool,
            clock,
        )
    } else {
        self.risk_ratio_int(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            quote_margin_pool,
            clock,
        )
    }
}

/// Returns the risk ratio without validating oracle price staleness or confidence.
/// Use for read-only queries where stale prices are acceptable.
public fun risk_ratio_unsafe<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    let debt_is_base = self.borrowed_base_shares > 0;
    if (debt_is_base) {
        self.risk_ratio_int_unsafe(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            base_margin_pool,
            clock,
        )
    } else {
        self.risk_ratio_int_unsafe(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            quote_margin_pool,
            clock,
        )
    }
}

// === Public Functions - Read Only ===
public fun balance_manager<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): &BalanceManager {
    &self.balance_manager
}

public fun base_balance<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): u64 {
    self.balance_manager.balance<BaseAsset>()
}

public fun quote_balance<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): u64 {
    self.balance_manager.balance<QuoteAsset>()
}

public fun deep_balance<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): u64 {
    self.balance_manager.balance<DEEP>()
}

/// Returns (base_asset, quote_asset) for margin manager.
public fun calculate_assets<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = self.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

public fun calculate_debts<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    clock: &Clock,
): (u64, u64) {
    let margin_pool_id = margin_pool.id();
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);

    let debt_is_base = self.has_base_debt();
    let debt_shares = if (debt_is_base) {
        self.borrowed_base_shares
    } else {
        self.borrowed_quote_shares
    };

    let base_debt = if (debt_is_base) {
        assert!(
            type_name::with_defining_ids<DebtAsset>() == type_name::with_defining_ids<BaseAsset>(),
            EInvalidDebtAsset,
        );
        margin_pool.borrow_shares_to_amount(debt_shares, clock)
    } else {
        0
    };
    let quote_debt = if (debt_is_base) {
        0
    } else {
        assert!(
            type_name::with_defining_ids<DebtAsset>() == type_name::with_defining_ids<QuoteAsset>(),
            EInvalidDebtAsset,
        );
        margin_pool.borrow_shares_to_amount(debt_shares, clock)
    };

    (base_debt, quote_debt)
}

/// Returns comprehensive state information for a margin manager.
/// Returns (manager_id, deepbook_pool_id, risk_ratio, base_asset, quote_asset,
///          base_debt, quote_debt, base_pyth_price, base_pyth_decimals,
///          quote_pyth_price, quote_pyth_decimals, current_price,
///          lowest_trigger_above_price, highest_trigger_below_price)
public fun manager_state<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): (ID, ID, u64, u64, u64, u64, u64, u64, u8, u64, u8, u64, u64, u64) {
    let manager_id = self.id();
    let deepbook_pool_id = self.deepbook_pool;
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    let (base_debt, quote_debt) = if (self.margin_pool_id.is_some()) {
        if (self.has_base_debt()) {
            self.calculate_debts(base_margin_pool, clock)
        } else {
            self.calculate_debts(quote_margin_pool, clock)
        }
    } else {
        (0, 0)
    };
    let risk_ratio = self.risk_ratio_unsafe(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    );

    let (base_pyth_price, base_pyth_decimals) = get_pyth_price_unsafe<BaseAsset>(
        base_oracle,
        registry,
    );
    let (quote_pyth_price, quote_pyth_decimals) = get_pyth_price_unsafe<QuoteAsset>(
        quote_oracle,
        registry,
    );

    let current_price = calculate_price_unsafe<BaseAsset, QuoteAsset>(
        registry,
        base_oracle,
        quote_oracle,
    );

    // Get the lowest trigger above price and highest trigger below price
    let lowest_trigger_above_price = self.lowest_trigger_above_price();
    let highest_trigger_below_price = self.highest_trigger_below_price();

    (
        manager_id,
        deepbook_pool_id,
        risk_ratio,
        base_asset,
        quote_asset,
        base_debt,
        quote_debt,
        base_pyth_price,
        base_pyth_decimals,
        quote_pyth_price,
        quote_pyth_decimals,
        current_price,
        lowest_trigger_above_price,
        highest_trigger_below_price,
    )
}

public fun id<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    self.id.to_inner()
}

public fun owner<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): address {
    self.owner
}

public fun deepbook_pool<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    self.deepbook_pool
}

public fun margin_pool_id<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): Option<ID> {
    self.margin_pool_id
}

public fun borrowed_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): (u64, u64) {
    (self.borrowed_base_shares, self.borrowed_quote_shares)
}

public fun borrowed_base_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    self.borrowed_base_shares
}

public fun borrowed_quote_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    self.borrowed_quote_shares
}

public fun has_base_debt<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): bool {
    self.borrowed_base_shares > 0
}

public fun conditional_order_ids<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): vector<u64> {
    let mut ids = vector::empty();

    let trigger_below = self.take_profit_stop_loss.trigger_below_orders();
    let mut i = 0;
    while (i < trigger_below.length()) {
        ids.push_back(trigger_below[i].conditional_order_id());
        i = i + 1;
    };

    let trigger_above = self.take_profit_stop_loss.trigger_above_orders();
    i = 0;
    while (i < trigger_above.length()) {
        ids.push_back(trigger_above[i].conditional_order_id());
        i = i + 1;
    };

    ids
}

public fun conditional_order<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    conditional_order_id: u64,
): ConditionalOrder {
    let conditional_order = self.take_profit_stop_loss.get_conditional_order(conditional_order_id);
    assert!(conditional_order.is_some(), EConditionalOrderNotFound);

    conditional_order.destroy_some()
}

/// Returns the lowest trigger price for trigger_above orders
/// Returns constants::max_u64() if there are no trigger_above orders
public fun lowest_trigger_above_price<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    let trigger_above = self.take_profit_stop_loss.trigger_above_orders();
    if (trigger_above.is_empty()) {
        constants::max_u64()
    } else {
        trigger_above[0].condition().trigger_price()
    }
}

/// Returns the highest trigger price for trigger_below orders
/// Returns 0 if there are no trigger_below orders
public fun highest_trigger_below_price<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    let trigger_below = self.take_profit_stop_loss.trigger_below_orders();
    if (trigger_below.is_empty()) {
        0
    } else {
        trigger_below[0].condition().trigger_price()
    }
}

// === Public-Package Functions ===
/// Unwraps balance manager for trading in deepbook.
public(package) fun balance_manager_trading_mut<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): &mut BalanceManager {
    assert!(self.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &mut self.balance_manager
}

/// Withdraws settled amounts from the pool permissionlessly.
/// Anyone can call this via the pool_proxy to settle balances.
public(package) fun withdraw_settled_amounts_permissionless_int<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
) {
    assert!(self.deepbook_pool == pool.id(), EIncorrectDeepBookPool);
    pool.withdraw_settled_amounts_permissionless(&mut self.balance_manager);
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun trade_proof<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): TradeProof {
    self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx)
}

/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public(package) fun deposit_int<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &TxContext,
) {
    let deposit_asset_type = type_name::with_defining_ids<DepositAsset>();
    let base_asset_type = type_name::with_defining_ids<BaseAsset>();
    let quote_asset_type = type_name::with_defining_ids<QuoteAsset>();
    let deep_asset_type = type_name::with_defining_ids<DEEP>();
    assert!(
        deposit_asset_type == base_asset_type || deposit_asset_type == quote_asset_type ||
        deposit_asset_type == deep_asset_type,
        EInvalidDeposit,
    );

    let balance_manager = &mut self.balance_manager;
    let deposit_cap = &self.deposit_cap;

    balance_manager.deposit_with_cap<DepositAsset>(deposit_cap, coin, ctx);
}

// === Private Functions ===
// Get the risk ratio of the margin manager.
fun risk_ratio_int<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    clock: &Clock,
): u64 {
    assert!(
        self.margin_pool_id.contains(&margin_pool.id()) || self.margin_pool_id.is_none(),
        EIncorrectMarginPool,
    );
    let (assets_in_debt_unit, _, _) = self.assets_in_debt_unit(
        registry,
        pool,
        base_oracle,
        quote_oracle,
        clock,
    );
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let debt = margin_pool.borrow_shares_to_amount(borrowed_shares, clock);
    let max_risk_ratio = margin_constants::max_risk_ratio();
    if (assets_in_debt_unit >= math::mul(debt, max_risk_ratio)) {
        max_risk_ratio
    } else {
        math::div(assets_in_debt_unit, debt)
    }
}

fun risk_ratio_int_unsafe<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    clock: &Clock,
): u64 {
    assert!(
        self.margin_pool_id.contains(&margin_pool.id()) || self.margin_pool_id.is_none(),
        EIncorrectMarginPool,
    );
    let (assets_in_debt_unit, _, _) = self.assets_in_debt_unit_unsafe(
        registry,
        pool,
        base_oracle,
        quote_oracle,
    );
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let debt = margin_pool.borrow_shares_to_amount(borrowed_shares, clock);
    let max_risk_ratio = margin_constants::max_risk_ratio();
    if (assets_in_debt_unit >= math::mul(debt, max_risk_ratio)) {
        max_risk_ratio
    } else {
        math::div(assets_in_debt_unit, debt)
    }
}

fun new_margin_manager<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    margin_registry: &mut MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): MarginManager<BaseAsset, QuoteAsset> {
    margin_registry.load_inner();
    assert!(margin_registry.pool_enabled(pool), EMarginTradingNotAllowedInPool);

    let id = object::new(ctx);
    let margin_manager_id = id.to_inner();
    let owner = ctx.sender();

    let (
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
    ) = balance_manager::new_with_custom_owner_caps<MarginApp>(
        deepbook_registry,
        id.to_address(),
        ctx,
    );
    margin_registry.add_margin_manager(id.to_inner(), ctx);

    event::emit(MarginManagerCreatedEvent {
        margin_manager_id,
        balance_manager_id: balance_manager.id(),
        deepbook_pool_id: pool.id(),
        owner,
        timestamp: clock.timestamp_ms(),
    });

    MarginManager<BaseAsset, QuoteAsset> {
        id,
        owner,
        deepbook_pool: pool.id(),
        margin_pool_id: option::none(),
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
        borrowed_base_shares: 0,
        borrowed_quote_shares: 0,
        take_profit_stop_loss: tpsl::new(),
        extra_fields: vec_map::empty(),
    }
}

fun validate_owner<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == self.owner, EInvalidMarginManagerOwner);
}

/// Repays the loan using the margin manager.
/// Returns the total amount repaid
fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let borrowed_amount = margin_pool.borrow_shares_to_amount(borrowed_shares, clock);
    let available_balance = self.balance_manager().balance<RepayAsset>();
    let repay_amount = amount.destroy_with_default(available_balance);
    let repay_amount = repay_amount.min(borrowed_amount);
    let repay_shares = math::mul(borrowed_shares, math::div(repay_amount, borrowed_amount));

    let coin: Coin<RepayAsset> = self.repay_withdraw(repay_amount, ctx);
    margin_pool.repay(repay_shares, coin, clock);

    if (type_name::with_defining_ids<RepayAsset>() == type_name::with_defining_ids<BaseAsset>()) {
        self.borrowed_base_shares = self.borrowed_base_shares - repay_shares;
    } else {
        self.borrowed_quote_shares = self.borrowed_quote_shares - repay_shares;
    };

    if (self.borrowed_base_shares == 0 && self.borrowed_quote_shares == 0) {
        self.margin_pool_id = option::none();
    };

    event::emit(LoanRepaidEvent {
        margin_manager_id: self.id(),
        margin_pool_id: margin_pool.id(),
        repay_amount,
        repay_shares,
        timestamp: clock.timestamp_ms(),
    });

    repay_amount
}

fun liquidation_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let balance_manager = &mut self.balance_manager;

    balance_manager.withdraw_with_cap<WithdrawAsset>(
        &self.withdraw_cap,
        withdraw_amount,
        ctx,
    )
}

/// This can only be called by the manager owner
fun repay_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    validate_owner(self, ctx);
    let balance_manager = &mut self.balance_manager;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        &self.withdraw_cap,
        withdraw_amount,
        ctx,
    );

    coin
}

/// Helper function to determine if margin manager can borrow from a margin pool
fun can_borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<BorrowAsset>,
): bool {
    let no_current_loan = self.margin_pool_id.is_none();

    self.margin_pool_id.contains(&margin_pool.id()) || no_current_loan
}

/// Returns (assets_in_debt_unit, base_asset, quote_asset)
fun assets_in_debt_unit<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    clock: &Clock,
): (u64, u64, u64) {
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    if (self.margin_pool_id.is_none()) {
        return (0, base_asset, quote_asset)
    };

    let assets_in_debt_unit = if (self.borrowed_base_shares > 0) {
        calculate_target_currency<QuoteAsset, BaseAsset>(registry, quote_oracle, base_oracle, quote_asset, clock) + base_asset
    } else {
        calculate_target_currency<BaseAsset, QuoteAsset>(registry, base_oracle, quote_oracle, base_asset, clock) + quote_asset
    };
    (assets_in_debt_unit, base_asset, quote_asset)
}

fun assets_in_debt_unit_unsafe<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
): (u64, u64, u64) {
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    if (self.margin_pool_id.is_none()) {
        return (0, base_asset, quote_asset)
    };

    let assets_in_debt_unit = if (self.borrowed_base_shares > 0) {
        calculate_target_currency_unsafe<QuoteAsset, BaseAsset>(registry, quote_oracle, base_oracle, quote_asset) + base_asset
    } else {
        calculate_target_currency_unsafe<BaseAsset, QuoteAsset>(registry, base_oracle, quote_oracle, base_asset) + quote_asset
    };
    (assets_in_debt_unit, base_asset, quote_asset)
}

fun place_pending_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    pending_order: &PendingOrder,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    if (pending_order.is_limit_order()) {
        self.place_pending_limit_order<BaseAsset, QuoteAsset>(
            registry,
            pool,
            pending_order.client_order_id(),
            pending_order.order_type().destroy_some(),
            pending_order.self_matching_option(),
            pending_order.price().destroy_some(),
            pending_order.quantity(),
            pending_order.is_bid(),
            pending_order.pay_with_deep(),
            pending_order.expire_timestamp().destroy_some(),
            clock,
            ctx,
        )
    } else {
        self.place_market_order_conditional<BaseAsset, QuoteAsset>(
            registry,
            pool,
            pending_order.client_order_id(),
            pending_order.self_matching_option(),
            pending_order.quantity(),
            pending_order.is_bid(),
            pending_order.pay_with_deep(),
            clock,
            ctx,
        )
    }
}

/// Only used for tpsl pending orders.
fun place_pending_limit_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
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
    assert!(self.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = self.trade_proof(ctx);
    let balance_manager = self.balance_manager_unsafe_mut();
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
/// Only used for tpsl pending orders.
fun place_market_order_conditional<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    assert!(self.deepbook_pool() == pool.id(), EIncorrectDeepBookPool);
    let trade_proof = self.trade_proof(ctx);
    let balance_manager = self.balance_manager_unsafe_mut();
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

/// Helper function to process collected conditional orders
fun process_collected_orders<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    orders: vector<ConditionalOrder>,
    order_infos: &mut vector<OrderInfo>,
    executed_ids: &mut vector<u64>,
    expired_ids: &mut vector<u64>,
    insufficient_funds_ids: &mut vector<u64>,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let mut i = 0;
    while (i < orders.length() && order_infos.length() < max_orders_to_execute) {
        let conditional_order = &orders[i];
        let conditional_order_id = conditional_order.conditional_order_id();
        let pending_order = conditional_order.pending_order();

        let can_place = if (pending_order.is_limit_order()) {
            pool.can_place_limit_order(
                self.balance_manager(),
                pending_order.price().destroy_some(),
                pending_order.quantity(),
                pending_order.is_bid(),
                pending_order.pay_with_deep(),
                pending_order.expire_timestamp().destroy_some(),
                clock,
            )
        } else {
            pool.can_place_market_order(
                self.balance_manager(),
                pending_order.quantity(),
                pending_order.is_bid(),
                pending_order.pay_with_deep(),
                clock,
            )
        };

        if (can_place) {
            let order_info = self.place_pending_order(
                registry,
                pool,
                &pending_order,
                clock,
                ctx,
            );
            order_infos.push_back(order_info);
            executed_ids.push_back(conditional_order_id);
        } else {
            if (pending_order.is_limit_order()) {
                let expire_timestamp = *pending_order.expire_timestamp().borrow();
                if (expire_timestamp <= clock.timestamp_ms()) {
                    expired_ids.push_back(conditional_order_id);
                } else {
                    insufficient_funds_ids.push_back(conditional_order_id);
                }
            } else {
                insufficient_funds_ids.push_back(conditional_order_id);
            }
        };

        i = i + 1;
    }
}

fun balance_manager_unsafe_mut<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
): &mut BalanceManager {
    &mut self.balance_manager
}
