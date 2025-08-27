// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_manager;

use deepbook::{
    balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap, TradeProof},
    constants,
    math,
    pool::Pool
};
use margin_trading::{
    manager_info::{Self, ManagerInfo},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::Coin, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 1;
const EMarginTradingNotAllowedInPool: u64 = 2;
const EInvalidMarginManagerOwner: u64 = 3;
const ECannotHaveLoanInMoreThanOneMarginPool: u64 = 4;
const EIncorrectDeepBookPool: u64 = 5;
const ERepaymentExceedsTotal: u64 = 6;
const EDeepbookPoolNotAllowedForLoan: u64 = 7;
const EInvalidMarginManager: u64 = 8;
const EBorrowRiskRatioExceeded: u64 = 9;
const EWithdrawRiskRatioExceeded: u64 = 10;
const EInvalidDebtAsset: u64 = 11;
const ECannotLiquidate: u64 = 12;
const EInvalidReturnAmount: u64 = 13;
const ERepaymentNotEnough: u64 = 14;
const EIncorrectMarginPool: u64 = 15;

// === Constants ===
const WITHDRAW: u8 = 0;
const BORROW: u8 = 1;

// === Structs ===
/// A shared object that wraps a `BalanceManager` and provides the necessary capabilities to deposit, withdraw, and trade.
public struct MarginManager<phantom BaseAsset, phantom QuoteAsset> has key, store {
    id: UID,
    owner: address,
    deepbook_pool: ID,
    margin_pool_id: Option<ID>, // If none, margin manager has no current loans in any margin pool
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    trade_cap: TradeCap,
    base_borrowed_shares: u64,
    quote_borrowed_shares: u64,
    active_liquidation: bool, // without this, the margin manager can be liquidated multiple times within the same tx
}

public struct Fulfillment<phantom DebtAsset> {
    manager_id: ID,
    repay_amount: u64,
    pool_reward_amount: u64,
    user_reward_usd: u64,
    default_amount: u64,
    base_exit_amount: u64,
    quote_exit_amount: u64,
    risk_ratio: u64,
}

/// Request_type: 0 for withdraw, 1 for borrow
public struct Request {
    margin_manager_id: ID,
    request_type: u8,
}

// === Events ===
/// Event emitted when a new margin manager is created.
public struct MarginManagerEvent has copy, drop {
    margin_manager_id: ID,
    balance_manager_id: ID,
    owner: address,
}

/// Event emitted when loan is borrowed
public struct LoanBorrowedEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    loan_amount: u64,
}

/// Event emitted when loan is repaid
public struct LoanRepaidEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    repay_amount: u64,
}

/// Event emitted when margin manager is liquidated
public struct LiquidationEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    liquidation_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    user_reward_usd: u64,
    risk_ratio: u64,
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    assert!(pool.margin_trading_enabled(), EMarginTradingNotAllowedInPool);

    let id = object::new(ctx);

    let (
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
    ) = balance_manager::new_with_custom_owner_and_caps(id.to_address(), ctx);

    event::emit(MarginManagerEvent {
        margin_manager_id: id.to_inner(),
        balance_manager_id: object::id(&balance_manager),
        owner: ctx.sender(),
    });

    let manager = MarginManager<BaseAsset, QuoteAsset> {
        id,
        owner: ctx.sender(),
        deepbook_pool: pool.id(),
        margin_pool_id: option::none(),
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
        base_borrowed_shares: 0,
        quote_borrowed_shares: 0,
        active_liquidation: false,
    };

    transfer::share_object(manager)
}

// === Public Functions - Margin Manager ===
/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    coin: Coin<DepositAsset>,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    self.validate_owner(ctx);

    let deposit_asset_type = type_name::get<DepositAsset>();
    let base_asset_type = type_name::get<BaseAsset>();
    let quote_asset_type = type_name::get<QuoteAsset>();
    let deep_asset_type = type_name::get<DEEP>();
    assert!(
        deposit_asset_type == base_asset_type || deposit_asset_type == quote_asset_type || deposit_asset_type == deep_asset_type,
        EInvalidDeposit,
    );

    let balance_manager = &mut self.balance_manager;
    let deposit_cap = &self.deposit_cap;

    balance_manager.deposit_with_cap<DepositAsset>(deposit_cap, coin, ctx);
}

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit. This is restricted through the Request.
/// Request must be destroyed using prove_and_destroy_request
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): (Coin<WithdrawAsset>, Request) {
    registry.load_inner();
    self.validate_owner(ctx);

    let balance_manager = &mut self.balance_manager;
    let withdraw_cap = &self.withdraw_cap;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        withdraw_cap,
        withdraw_amount,
        ctx,
    );

    let withdrawal_request = Request {
        margin_manager_id: self.id(),
        request_type: WITHDRAW,
    };

    (coin, withdrawal_request)
}

/// Borrow the base asset using the margin manager.
/// Request must be destroyed using prove_and_destroy_request
public fun borrow_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.can_borrow(base_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        base_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    base_margin_pool.update_state(clock);
    let loan_shares = base_margin_pool.to_borrow_shares(loan_amount);
    self.increase_borrowed_shares(true, loan_shares);
    self.margin_pool_id = option::some(base_margin_pool.id());

    self.borrow<BaseAsset, QuoteAsset, BaseAsset>(
        registry,
        base_margin_pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Borrow the quote asset using the margin manager.
/// Request must be destroyed using prove_and_destroy_request
public fun borrow_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.can_borrow(quote_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        quote_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    quote_margin_pool.update_state(clock);
    let loan_shares = quote_margin_pool.to_borrow_shares(loan_amount);
    self.increase_borrowed_shares(false, loan_shares);
    self.margin_pool_id = option::some(quote_margin_pool.id());

    self.borrow<BaseAsset, QuoteAsset, QuoteAsset>(
        registry,
        quote_margin_pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Destroys the request to borrow or withdraw if risk ratio conditions are met.
/// This function is called after the borrow or withdraw request is created.
public fun prove_and_destroy_request<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    request: Request,
) {
    let margin_pool_id = margin_pool.id();
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);
    assert!(request.margin_manager_id == self.id(), EInvalidMarginManager);
    assert!(self.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    margin_pool.update_state(clock);
    let manager_info = self.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool.id(),
    );
    let risk_ratio = manager_info.risk_ratio();
    let pool_id = pool.id();
    if (request.request_type == BORROW) {
        assert!(registry.can_borrow(pool_id, risk_ratio), EBorrowRiskRatioExceeded);
    } else if (request.request_type == WITHDRAW) {
        assert!(registry.can_withdraw(pool_id, risk_ratio), EWithdrawRiskRatioExceeded);
    };

    let Request {
        margin_manager_id: _,
        request_type: _,
    } = request;
}

/// Repay the base asset loan using the margin manager.
/// Returns the total amount repaid
public fun repay_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BaseAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        repay_amount,
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
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        repay_amount,
        clock,
        ctx,
    )
}

// === Public Functions - Liquidation - Receive Assets before liquidation ===
/// Liquidates a margin manager. Can source liquidity from anywhere.
/// Returns the fulfillment, base coin, and quote coin.
/// Fulfillment must be destroyed using repay_liquidation or repay_liquidation_in_full
public fun liquidate<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Fulfillment<DebtAsset>, Coin<BaseAsset>, Coin<QuoteAsset>) {
    let pool_id = pool.id();
    let margin_pool_id = margin_pool.id();
    assert!(self.deepbook_pool == pool_id, EIncorrectDeepBookPool);
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);

    margin_pool.update_state(clock);
    let manager_info = self.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool_id,
    );
    assert!(registry.can_liquidate(pool_id, manager_info.risk_ratio()), ECannotLiquidate);
    assert!(!self.active_liquidation, ECannotLiquidate);
    self.active_liquidation = true;

    // cancel all orders. at this point, all available assets are in the balance manager.
    let trade_proof = self.trade_proof(ctx);
    let balance_manager = self.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);

    produce_fulfillment<BaseAsset, QuoteAsset, DebtAsset>(
        self,
        &manager_info,
        ctx,
    )
}

/// Repays the loan as the liquidator.
/// Must input additional assets if it's not a full liquidation.
/// Returns the extra base and quote assets.
public fun repay_liquidation<BaseAsset, QuoteAsset, RepayAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<RepayAsset>,
    repay_coin: Coin<RepayAsset>,
    mut return_base: Coin<BaseAsset>,
    mut return_quote: Coin<QuoteAsset>,
    fulfillment: Fulfillment<RepayAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    registry.load_inner();
    assert!(fulfillment.manager_id == self.id(), EInvalidMarginManager);
    margin_pool.update_state(clock);
    assert!(self.active_liquidation, ECannotLiquidate);
    self.active_liquidation = false;

    let margin_manager_id = self.id();
    let margin_pool_id = margin_pool.id();
    let repay_coin_amount = repay_coin.value();

    let total_fulfillment_amount = fulfillment.repay_amount + fulfillment.pool_reward_amount;
    let repay_percentage = math::div(repay_coin_amount, total_fulfillment_amount);
    assert!(repay_percentage <= constants::float_scaling(), ERepaymentExceedsTotal);
    let return_percentage = constants::float_scaling() - repay_percentage;

    let repay_is_base = self.has_base_debt();
    let repay_amount = math::mul(fulfillment.repay_amount, repay_percentage);
    let full_repayment = repay_percentage == constants::float_scaling();
    let mut default_amount = if (full_repayment) fulfillment.default_amount else 0;
    let mut pool_reward_amount = repay_coin_amount - repay_amount;

    let cancel_amount = pool_reward_amount.min(default_amount);
    pool_reward_amount = pool_reward_amount - cancel_amount;
    default_amount = default_amount - cancel_amount;

    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    self.decrease_borrowed_shares(repay_is_base, repay_shares);
    let default_shares = margin_pool.to_borrow_shares(default_amount);
    self.decrease_borrowed_shares(repay_is_base, default_shares);
    self.reset_margin_pool_id();

    let base_to_return = math::mul(fulfillment.base_exit_amount, return_percentage);
    let quote_to_return = math::mul(fulfillment.quote_exit_amount, return_percentage);

    if (base_to_return > 0) {
        assert!(return_base.value() >= base_to_return, EInvalidReturnAmount);
        let base_coin = return_base.split(base_to_return, ctx);
        self.liquidation_deposit_base(base_coin, ctx);
    };

    if (quote_to_return > 0) {
        assert!(return_quote.value() >= quote_to_return, EInvalidReturnAmount);
        let quote_coin = return_quote.split(quote_to_return, ctx);
        self.liquidation_deposit_quote(quote_coin, ctx);
    };

    let user_reward_usd = fulfillment.user_reward_usd;
    let risk_ratio = fulfillment.risk_ratio;

    margin_pool.repay_with_reward(
        repay_coin,
        repay_amount,
        pool_reward_amount,
        default_amount,
        clock,
    );

    event::emit(LoanRepaidEvent {
        margin_manager_id,
        margin_pool_id,
        repay_amount,
    });

    event::emit(LiquidationEvent {
        margin_manager_id,
        margin_pool_id,
        liquidation_amount: repay_amount,
        pool_reward_amount,
        user_reward_usd,
        default_amount,
        risk_ratio,
    });

    let Fulfillment {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        user_reward_usd: _,
        default_amount: _,
        base_exit_amount: _,
        quote_exit_amount: _,
        risk_ratio: _,
    } = fulfillment;

    (return_base, return_quote)
}

/// Repays the loan as the liquidator.
/// Returns the extra coin not required for repayment.
public fun repay_liquidation_in_full<BaseAsset, QuoteAsset, RepayAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<RepayAsset>,
    mut coin: Coin<RepayAsset>,
    fulfillment: Fulfillment<RepayAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<RepayAsset>) {
    registry.load_inner();
    assert!(fulfillment.manager_id == self.id(), EInvalidMarginManager);
    margin_pool.update_state(clock);
    assert!(self.active_liquidation, ECannotLiquidate);
    self.active_liquidation = false;

    let margin_manager_id = self.id();
    let margin_pool_id = margin_pool.id();
    let coin_amount = coin.value();
    let repay_amount = fulfillment.repay_amount;

    let total_fulfillment_amount = repay_amount + fulfillment.pool_reward_amount;
    assert!(coin_amount >= total_fulfillment_amount, ERepaymentNotEnough);

    let repay_is_base = self.has_base_debt();
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    self.decrease_borrowed_shares(repay_is_base, repay_shares);
    let default_shares = margin_pool.to_borrow_shares(fulfillment.default_amount);
    self.decrease_borrowed_shares(repay_is_base, default_shares);
    self.reset_margin_pool_id();

    let cancel_amount = fulfillment.pool_reward_amount.min(fulfillment.default_amount);
    let pool_reward_amount = fulfillment.pool_reward_amount - cancel_amount;
    let default_amount = fulfillment.default_amount - cancel_amount;

    let repay_coin = coin.split(total_fulfillment_amount, ctx);

    margin_pool.repay_with_reward(
        repay_coin,
        repay_amount,
        pool_reward_amount,
        default_amount,
        clock,
    );

    event::emit(LoanRepaidEvent {
        margin_manager_id,
        margin_pool_id,
        repay_amount,
    });

    let user_reward_usd = fulfillment.user_reward_usd;
    let risk_ratio = fulfillment.risk_ratio;

    event::emit(LiquidationEvent {
        margin_manager_id,
        margin_pool_id,
        liquidation_amount: repay_amount,
        pool_reward_amount,
        user_reward_usd,
        default_amount,
        risk_ratio,
    });

    let Fulfillment {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        user_reward_usd: _,
        default_amount: _,
        base_exit_amount: _,
        quote_exit_amount: _,
        risk_ratio: _,
    } = fulfillment;

    coin
}

// === Public Functions - Liquidation - Receive rewards after liquidation ===
/// Liquidates the base asset loan for the margin manager.
/// Returns a mix of base and quote assets as the user liquidation reward.
public fun liquidate_base_loan<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BaseAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    liquidation_coin: Coin<BaseAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (mut base_coin, quote_coin, liquidation_coin) = self.liquidate_loan<
        BaseAsset,
        QuoteAsset,
        BaseAsset,
    >(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        liquidation_coin,
        clock,
        ctx,
    );
    base_coin.join(liquidation_coin);

    (base_coin, quote_coin)
}

/// Liquidates the quote asset loan for the margin manager.
/// Returns a mix of base and quote assets as the user liquidation reward.
public fun liquidate_quote_loan<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    liquidation_coin: Coin<QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (base_coin, mut quote_coin, liquidation_coin) = self.liquidate_loan<
        BaseAsset,
        QuoteAsset,
        QuoteAsset,
    >(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        liquidation_coin,
        clock,
        ctx,
    );
    quote_coin.join(liquidation_coin);

    (base_coin, quote_coin)
}

/// Liquidator submits a coin, repays on the manager's behalf, and receives base and quote assets as reward.
public fun liquidate_loan<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    mut liquidation_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    // Example calculation flow:
    // - USDT loan is repaid: 679 USDT
    // - User inputs: $700, receives: $713.59, profit = 13.59 / 679 = 2%
    // - Pool receives liquidation reward: 21 USDT (3%)
    // - Remaining manager assets: 1100 - 713.59 = 386.41
    // - Remaining debt: 1000 - 679 = 321
    // - New risk ratio: 386.41 / 321 = 1.203 (partial liquidation, not fully to 1.25)

    let pool_id = pool.id();
    let margin_pool_id = margin_pool.id();
    assert!(self.deepbook_pool == pool_id, EIncorrectDeepBookPool);
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);

    margin_pool.update_state(clock);
    let manager_info = self.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool_id,
    );
    let risk_ratio = manager_info.risk_ratio();
    assert!(registry.can_liquidate(pool_id, risk_ratio), ECannotLiquidate);
    assert!(!self.active_liquidation, ECannotLiquidate);

    // Cancel all orders to make assets available for liquidation
    let trade_proof = self.trade_proof(ctx);
    let balance_manager = self.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);

    // Step 1: Calculate liquidation amounts
    let amounts = manager_info.calculate_liquidation_amounts<DebtAsset>(
        &liquidation_coin,
    );
    let (
        debt_is_base,
        repay_amount,
        mut pool_reward_amount,
        mut default_amount,
        repay_usd,
        repay_amount_with_pool_reward,
    ) = amounts.liquidation_amounts_info();

    // Step 2: Repay the user's loan
    let repay_coin = liquidation_coin.split(repay_amount_with_pool_reward, ctx);
    self.repay_user_loan<BaseAsset, QuoteAsset, DebtAsset>(
        margin_pool,
        repay_coin,
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        clock,
    );

    // Step 3: Calculate and withdraw exit assets
    let (base_coin, quote_coin) = self.calculate_exit_assets<BaseAsset, QuoteAsset>(
        &manager_info,
        repay_usd,
        ctx,
    );

    let margin_manager_id = self.id();
    let margin_pool_id = margin_pool.id();
    let user_reward_usd = manager_info.to_user_liquidation_reward(repay_usd);

    let cancel_amount = pool_reward_amount.min(default_amount);
    pool_reward_amount = pool_reward_amount - cancel_amount;
    default_amount = default_amount - cancel_amount;

    // Emit events
    event::emit(LoanRepaidEvent {
        margin_manager_id,
        margin_pool_id,
        repay_amount,
    });

    event::emit(LiquidationEvent {
        margin_manager_id,
        margin_pool_id,
        liquidation_amount: repay_amount,
        pool_reward_amount,
        default_amount,
        user_reward_usd,
        risk_ratio,
    });

    (base_coin, quote_coin, liquidation_coin)
}

// === Public Functions - Read Only ===
/// Risk ratio = total asset in USD / (total debt and interest in USD)
/// Risk ratio above 2.0 allows for withdrawal from balance manager, borrowing, and trading
/// Risk ratio between 1.25 and 2.0 allows for borrowing and trading
/// Risk ratio between 1.1 and 1.25 allows for trading only
/// Risk ratio below 1.1 allows for liquidation
/// These numbers can be updated by the admin. 1.25 is the default borrow risk ratio, this is equivalent to 5x leverage.
/// Returns asset, debt, and risk ratio information for the margin manager.
public fun manager_info<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &MarginPool<DebtAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    pool_id: ID,
): ManagerInfo {
    let margin_pool_id = margin_pool.id();
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);
    assert!(self.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    let (base_debt, quote_debt) = self.calculate_debts<BaseAsset, QuoteAsset, DebtAsset>(
        margin_pool,
    );

    let (base_asset, quote_asset) = self.calculate_assets<BaseAsset, QuoteAsset>(
        pool,
    );

    // Delegate all USD calculations and risk ratio computation to manager_info module
    manager_info::new_manager_info<BaseAsset, QuoteAsset>(
        base_asset,
        quote_asset,
        base_debt,
        quote_debt,
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool_id,
    )
}

public fun deepbook_pool<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    self.deepbook_pool
}

/// Returns fulfillment repay amount
public fun repay_amount<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.repay_amount
}

/// Returns fulfillment pool reward amount
public fun pool_reward_amount<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.pool_reward_amount
}

public fun user_reward_usd<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.user_reward_usd
}

public fun default_amount<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.default_amount
}

public fun base_exit_amount<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.base_exit_amount
}

public fun quote_exit_amount<DebtAsset>(fulfillment: &Fulfillment<DebtAsset>): u64 {
    fulfillment.quote_exit_amount
}

// === Public-Package Functions ===
public(package) fun balance_manager<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): &BalanceManager {
    &self.balance_manager
}

public(package) fun balance_manager_mut<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
): &mut BalanceManager {
    &mut self.balance_manager
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun balance_manager_trading_mut<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): &mut BalanceManager {
    assert!(self.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &mut self.balance_manager
}

public(package) fun base_borrowed_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    self.base_borrowed_shares
}

public(package) fun quote_borrowed_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    self.quote_borrowed_shares
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun trade_proof<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): TradeProof {
    self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx)
}

public(package) fun id<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    object::id(self)
}

/// Returns (base_asset, quote_asset) for margin manager.
public(package) fun calculate_assets<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = self.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

/// General helper for debt calculation and asset totals.
/// Returns (base_debt, quote_debt)
public(package) fun calculate_debts<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
): (u64, u64) {
    let margin_pool_id = margin_pool.id();
    assert!(self.margin_pool_id.contains(&margin_pool_id), EIncorrectMarginPool);

    let debt_is_base = self.has_base_debt();
    let debt_shares = if (debt_is_base) {
        self.base_borrowed_shares
    } else {
        self.quote_borrowed_shares
    };

    let base_debt = if (debt_is_base) {
        assert!(type_name::get<DebtAsset>() == type_name::get<BaseAsset>(), EInvalidDebtAsset);
        margin_pool.to_borrow_amount(debt_shares)
    } else {
        0
    };
    let quote_debt = if (debt_is_base) {
        0
    } else {
        assert!(type_name::get<DebtAsset>() == type_name::get<QuoteAsset>(), EInvalidDebtAsset);
        margin_pool.to_borrow_amount(debt_shares)
    };

    (base_debt, quote_debt)
}

// === Private Functions ===
/// calculate quantity of debt that must be removed to reach target risk ratio.
/// amount_to_repay is only for the loan, not including liquidation rewards.
/// amount_to_repay = (target_ratio × debt_value - asset) / (target_ratio - (1 + total_liquidation_reward)))
fun produce_fulfillment<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    manager_info: &ManagerInfo,
    ctx: &mut TxContext,
): (Fulfillment<DebtAsset>, Coin<BaseAsset>, Coin<QuoteAsset>) {
    let risk_ratio = manager_info.risk_ratio();
    let in_default = risk_ratio < constants::float_scaling(); // false
    // Manager is in default if asset / debt < 1
    let (default_amount_to_repay, default_amount) = manager_info.default_info(in_default); // (0, 0)

    let usd_amount_to_repay = if (in_default) {
        manager_info.calculate_usd_amount_to_repay_in_default()
    } else {
        manager_info.calculate_usd_amount_to_repay()
    }; // 750

    let (base_exit_amount, quote_exit_amount) = manager_info.calculate_quantity_to_exit(
        usd_amount_to_repay,
    ); // (550, 237.5)

    let base = self.liquidation_withdraw_base(
        base_exit_amount,
        ctx,
    );
    let quote = self.liquidation_withdraw_quote(
        quote_exit_amount,
        ctx,
    );

    // If manager is in default, we repay as much as possible
    let repay_amount = if (in_default) {
        default_amount_to_repay
    } else {
        manager_info.calculate_debt_repay_amount(
            self.has_base_debt(),
            usd_amount_to_repay,
        )
    }; // 750 USDT

    let manager_id = self.id();
    let pool_reward_amount = manager_info.to_pool_liquidation_reward(repay_amount); // 750 * 0.03 = 22.5 USDT
    let user_reward_usd = manager_info.to_user_liquidation_reward(usd_amount_to_repay); // $750 * 0.02 = $15
    (
        Fulfillment<DebtAsset> {
            manager_id,
            repay_amount,
            pool_reward_amount,
            user_reward_usd,
            default_amount,
            base_exit_amount,
            quote_exit_amount,
            risk_ratio,
        },
        base,
        quote,
    )

    // User receives 550 USDT, 237.5 USDC. User has to repay 750 USDT, and 22.5 USDT to the pool.
    // User reward at the end is 550 + 237.5 - 750 - 22.5 = 15
    // Manager now has:
    // - 0 USDT
    // - 550 - 237.5 = 312.5 USDC
    // - 250 USDT debt
    // Risk ratio is 312.5 / 250 = 1.25
}

fun validate_owner<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == self.owner, EInvalidMarginManagerOwner);
}

fun borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BorrowAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let manager_id = self.id();
    let coin = margin_pool.borrow(loan_amount, clock, ctx);

    self.deposit<BaseAsset, QuoteAsset, BorrowAsset>(registry, coin, ctx);

    event::emit(LoanBorrowedEvent {
        margin_manager_id: manager_id,
        margin_pool_id: margin_pool.id(),
        loan_amount,
    });

    Request {
        margin_manager_id: manager_id,
        request_type: BORROW,
    }
}

/// Repays the loan using the margin manager.
/// Returns the total amount repaid
/// TODO: Can the conversion here cause a rounding error?
fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_pool.update_state(clock);

    let repay_is_base = self.has_base_debt();
    let repay_amount = if (repay_amount.is_some()) {
        repay_amount.destroy_some()
    } else {
        if (repay_is_base) {
            margin_pool.to_borrow_amount(self.base_borrowed_shares)
        } else {
            margin_pool.to_borrow_amount(self.quote_borrowed_shares)
        }
    };
    let available_balance = self.balance_manager().balance<RepayAsset>();
    let repay_amount = repay_amount.min(available_balance);
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    self.decrease_borrowed_shares(repay_is_base, repay_shares);
    self.reset_margin_pool_id();

    let coin = self.repay_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repay_amount,
        ctx,
    );

    margin_pool.repay(
        coin,
        clock,
    );

    event::emit(LoanRepaidEvent {
        margin_manager_id: self.id(),
        margin_pool_id: margin_pool.id(),
        repay_amount,
    });

    repay_amount
}

fun reset_margin_pool_id<BaseAsset, QuoteAsset>(self: &mut MarginManager<BaseAsset, QuoteAsset>) {
    if (self.base_borrowed_shares == 0 && self.quote_borrowed_shares == 0) {
        self.margin_pool_id = option::none();
    };
}

/// Deposit base asset to margin manager during liquidation
fun liquidation_deposit_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<BaseAsset>,
    ctx: &TxContext,
) {
    self.liquidation_deposit<BaseAsset, QuoteAsset, BaseAsset>(
        coin,
        ctx,
    )
}

/// Deposit quote asset to margin manager during liquidation
fun liquidation_deposit_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<QuoteAsset>,
    ctx: &TxContext,
) {
    self.liquidation_deposit<BaseAsset, QuoteAsset, QuoteAsset>(
        coin,
        ctx,
    )
}

fun liquidation_deposit<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &TxContext,
) {
    let balance_manager = &mut self.balance_manager;

    balance_manager.deposit_with_cap<DepositAsset>(
        &self.deposit_cap,
        coin,
        ctx,
    )
}

fun liquidation_withdraw_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<BaseAsset> {
    self.liquidation_withdraw<BaseAsset, QuoteAsset, BaseAsset>(
        withdraw_amount,
        ctx,
    )
}

fun liquidation_withdraw_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<QuoteAsset> {
    self.liquidation_withdraw<BaseAsset, QuoteAsset, QuoteAsset>(
        withdraw_amount,
        ctx,
    )
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

/// Helper function for Step 2: Repay the user's loan
fun repay_user_loan<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<DebtAsset>,
    repay_coin: Coin<DebtAsset>,
    debt_is_base: bool,
    repay_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    clock: &Clock,
) {
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    self.decrease_borrowed_shares(debt_is_base, repay_shares);
    let default_shares = margin_pool.to_borrow_shares(default_amount);
    self.decrease_borrowed_shares(debt_is_base, default_shares);
    self.reset_margin_pool_id();

    margin_pool.repay_with_reward(
        repay_coin,
        repay_amount,
        pool_reward_amount,
        default_amount,
        clock,
    );
}

/// Helper function for Step 3: Calculate assets that exit the manager
fun calculate_exit_assets<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    manager_info: &ManagerInfo,
    repay_usd: u64,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    // Calculate total USD to exit including all rewards
    let total_usd_to_exit = manager_info.with_liquidation_reward_ratio(repay_usd);
    let (base_usd, quote_usd) = manager_info.calculate_usd_exit_amounts(total_usd_to_exit);

    // Convert USD to asset amounts and withdraw in parallel
    let (base_to_exit, quote_to_exit) = manager_info.calculate_asset_amounts(
        base_usd,
        quote_usd,
    );

    (
        self.liquidation_withdraw_base(base_to_exit, ctx),
        self.liquidation_withdraw_quote(quote_to_exit, ctx),
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

fun has_base_debt<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): bool {
    self.base_borrowed_shares > 0
}

/// Helper function to determine if margin manager can borrow from a margin pool
fun can_borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<BorrowAsset>,
): bool {
    let no_current_loan = self.margin_pool_id.is_none();

    self.margin_pool_id.contains(&margin_pool.id()) || no_current_loan
}

fun increase_borrowed_shares<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    debt_is_base: bool,
    shares: u64,
) {
    if (debt_is_base) {
        self.base_borrowed_shares = self.base_borrowed_shares + shares;
    } else {
        self.quote_borrowed_shares = self.quote_borrowed_shares + shares;
    };
}

fun decrease_borrowed_shares<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    debt_is_base: bool,
    shares: u64,
) {
    if (debt_is_base) {
        self.base_borrowed_shares = self.base_borrowed_shares - shares;
    } else {
        self.quote_borrowed_shares = self.quote_borrowed_shares - shares;
    };
}
