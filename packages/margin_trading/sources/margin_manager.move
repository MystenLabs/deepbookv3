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
const EInvalidDeposit: u64 = 0;
const EMarginTradingNotAllowedInPool: u64 = 1;
const EInvalidMarginManagerOwner: u64 = 2;
const ECannotHaveLoanInBothMarginPools: u64 = 3;
const EIncorrectDeepBookPool: u64 = 4;
const ERepaymentExceedsTotal: u64 = 5;
const EDeepbookPoolNotAllowedForLoan: u64 = 6;
const EInvalidMarginManager: u64 = 7;
const EBorrowRiskRatioExceeded: u64 = 8;
const EWithdrawRiskRatioExceeded: u64 = 9;
const EInvalidDebtAsset: u64 = 10;
const ECannotLiquidate: u64 = 11;
const EInvalidReturnAmount: u64 = 12;
const ERepaymentNotEnough: u64 = 13;

// === Constants ===
const WITHDRAW: u8 = 0;
const BORROW: u8 = 1;

// === Structs ===
/// A shared object that wraps a `BalanceManager` and provides the necessary capabilities to deposit, withdraw, and trade.
public struct MarginManager<phantom BaseAsset, phantom QuoteAsset> has key, store {
    id: UID,
    owner: address,
    deepbook_pool: ID,
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
}

/// Request_type: 0 for withdraw, 1 for borrow
public struct Request {
    margin_manager_id: ID,
    request_type: u8,
}

/// Event emitted when a new margin_manager is created.
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
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>, ctx: &mut TxContext) {
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

    let margin_manager = MarginManager<BaseAsset, QuoteAsset> {
        id,
        owner: ctx.sender(),
        deepbook_pool: pool.id(),
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
        base_borrowed_shares: 0,
        quote_borrowed_shares: 0,
        active_liquidation: false,
    };

    transfer::share_object(margin_manager)
}

/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &mut TxContext,
) {
    margin_manager.validate_owner(ctx);

    let deposit_asset_type = type_name::get<DepositAsset>();
    let base_asset_type = type_name::get<BaseAsset>();
    let quote_asset_type = type_name::get<QuoteAsset>();
    let deep_asset_type = type_name::get<DEEP>();
    assert!(
        deposit_asset_type == base_asset_type || deposit_asset_type == quote_asset_type || deposit_asset_type == deep_asset_type,
        EInvalidDeposit,
    );

    let balance_manager = &mut margin_manager.balance_manager;
    let deposit_cap = &margin_manager.deposit_cap;

    balance_manager.deposit_with_cap<DepositAsset>(deposit_cap, coin, ctx);
}

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit. This is restricted through the Request.
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): (Coin<WithdrawAsset>, Request) {
    margin_manager.validate_owner(ctx);

    let balance_manager = &mut margin_manager.balance_manager;
    let withdraw_cap = &margin_manager.withdraw_cap;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        withdraw_cap,
        withdraw_amount,
        ctx,
    );

    let withdrawal_request = Request {
        margin_manager_id: margin_manager.id(),
        request_type: WITHDRAW,
    };

    (coin, withdrawal_request)
}

/// Borrow the base asset using the margin manager.
public fun borrow_base<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    margin_manager.validate_owner(ctx);
    assert!(margin_manager.quote_borrowed_shares == 0, ECannotHaveLoanInBothMarginPools);
    assert!(
        base_margin_pool.deepbook_pool_allowed(margin_manager.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    base_margin_pool.update_state(clock);
    let loan_shares = base_margin_pool.to_borrow_shares(loan_amount);
    margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares + loan_shares;

    margin_manager.borrow<BaseAsset, QuoteAsset, BaseAsset>(
        base_margin_pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    margin_manager.validate_owner(ctx);
    assert!(margin_manager.base_borrowed_shares == 0, ECannotHaveLoanInBothMarginPools);
    assert!(
        quote_margin_pool.deepbook_pool_allowed(margin_manager.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    quote_margin_pool.update_state(clock);
    let loan_shares = quote_margin_pool.to_borrow_shares(loan_amount);
    margin_manager.quote_borrowed_shares = margin_manager.quote_borrowed_shares + loan_shares;

    margin_manager.borrow<BaseAsset, QuoteAsset, QuoteAsset>(
        quote_margin_pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Repay the base asset loan using the margin manager.
/// Returns the total amount repaid
public fun repay_base<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BaseAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.validate_owner(ctx);

    margin_manager.repay<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        repay_amount,
        clock,
        ctx,
    )
}

/// Repay the quote asset loan using the margin manager.
/// Returns the total amount repaid
public fun repay_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.validate_owner(ctx);

    margin_manager.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        repay_amount,
        clock,
        ctx,
    )
}

/// Liquidates a margin manager. Can source liquidity from anywhere.
public fun liquidate<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Fulfillment<DebtAsset>, Coin<BaseAsset>, Coin<QuoteAsset>) {
    let pool_id = pool.id();
    assert!(margin_manager.deepbook_pool == pool_id, EIncorrectDeepBookPool);

    margin_pool.update_state(clock);
    let manager_info = margin_manager.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool_id,
    );
    assert!(registry.can_liquidate(pool_id, manager_info.risk_ratio()), ECannotLiquidate);
    assert!(!margin_manager.active_liquidation, ECannotLiquidate);
    margin_manager.active_liquidation = true;

    // cancel all orders. at this point, all available assets are in the balance manager.
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);

    produce_fulfillment<BaseAsset, QuoteAsset, DebtAsset>(
        margin_manager,
        &manager_info,
        ctx,
    )
}

public fun liquidate_base_loan<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<BaseAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    liquidation_coin: Coin<BaseAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (mut base_coin, quote_coin, liquidation_coin) = margin_manager.liquidate_loan<
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

public fun liquidate_quote_loan<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    liquidation_coin: Coin<QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (base_coin, mut quote_coin, liquidation_coin) = margin_manager.liquidate_loan<
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

/// Liquidator submits a coin, repays on the manager's behalf, and we return base and quote assets accordingly.
///
/// Example calculation flow:
/// - USDT loan is repaid: 679 USDT
/// - User inputs: $700, receives: $713.59, profit = 13.59 / 679 = 2%
/// - Pool receives liquidation reward: 21 USDT (3%)
/// - Remaining manager assets: 1100 - 713.59 = 386.41
/// - Remaining debt: 1000 - 679 = 321
/// - New risk ratio: 386.41 / 321 = 1.203 (partial liquidation, not fully to 1.25)
public fun liquidate_loan<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    mut liquidation_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    let pool_id = pool.id();
    assert!(margin_manager.deepbook_pool == pool_id, EIncorrectDeepBookPool);

    margin_pool.update_state(clock);
    let manager_info = margin_manager.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
        pool_id,
    );
    assert!(registry.can_liquidate(pool_id, manager_info.risk_ratio()), ECannotLiquidate);
    assert!(!margin_manager.active_liquidation, ECannotLiquidate);

    // Cancel all orders to make assets available for liquidation
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);

    // Step 1: Calculate liquidation amounts
    let amounts = manager_info.calculate_liquidation_amounts<DebtAsset>(
        &liquidation_coin,
    );
    let (
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        repay_usd,
        repay_amount_with_pool_reward,
    ) = amounts.liquidation_amounts_info();

    // Step 2: Repay the user's loan
    let repay_coin = liquidation_coin.split(repay_amount_with_pool_reward, ctx);
    margin_manager.repay_user_loan<BaseAsset, QuoteAsset, DebtAsset>(
        margin_pool,
        repay_coin,
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        clock,
    );

    // Step 3: Calculate and withdraw exit assets
    let (base_coin, quote_coin) = margin_manager.calculate_exit_assets<BaseAsset, QuoteAsset>(
        &manager_info,
        repay_usd,
        ctx,
    );

    let margin_manager_id = margin_manager.id();
    let margin_pool_id = margin_pool.id();
    let user_reward_usd = manager_info.to_user_liquidation_reward(repay_usd);

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
    });

    (base_coin, quote_coin, liquidation_coin)
}

/// Repays the loan as the liquidator.
/// Returns the extra base and quote assets
public fun repay_liquidation<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    repay_coin: Coin<RepayAsset>,
    mut return_base: Coin<BaseAsset>,
    mut return_quote: Coin<QuoteAsset>,
    fulfillment: Fulfillment<RepayAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    assert!(fulfillment.manager_id == margin_manager.id(), EInvalidMarginManager);
    margin_pool.update_state(clock);
    assert!(margin_manager.active_liquidation, ECannotLiquidate);
    margin_manager.active_liquidation = false;

    let margin_manager_id = margin_manager.id();
    let margin_pool_id = margin_pool.id();
    let repay_coin_amount = repay_coin.value();

    let total_fulfillment_amount = fulfillment.repay_amount + fulfillment.pool_reward_amount;
    let repay_percentage = math::div(repay_coin_amount, total_fulfillment_amount);
    assert!(repay_percentage <= constants::float_scaling(), ERepaymentExceedsTotal);
    let return_percentage = constants::float_scaling() - repay_percentage;

    let repay_is_base = margin_manager.has_base_debt();
    let repay_amount = math::mul(fulfillment.repay_amount, repay_percentage);
    let full_repayment = repay_percentage == constants::float_scaling();
    let mut default_amount = if (full_repayment) fulfillment.default_amount else 0;
    let mut pool_reward_amount = repay_coin_amount - repay_amount;

    let cancel_amount = pool_reward_amount.min(default_amount);
    pool_reward_amount = pool_reward_amount - cancel_amount;
    default_amount = default_amount - cancel_amount;

    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    if (repay_is_base) {
        margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares - repay_shares;
    } else {
        margin_manager.quote_borrowed_shares = margin_manager.quote_borrowed_shares - repay_shares;
    };

    let base_to_return = math::mul(fulfillment.base_exit_amount, return_percentage);
    let quote_to_return = math::mul(fulfillment.quote_exit_amount, return_percentage);

    if (base_to_return > 0) {
        assert!(return_base.value() >= base_to_return, EInvalidReturnAmount);
        let base_coin = return_base.split(base_to_return, ctx);
        margin_manager.liquidation_deposit_base(base_coin, ctx);
    };

    if (quote_to_return > 0) {
        assert!(return_quote.value() >= quote_to_return, EInvalidReturnAmount);
        let quote_coin = return_quote.split(quote_to_return, ctx);
        margin_manager.liquidation_deposit_quote(quote_coin, ctx);
    };

    let user_reward_usd = fulfillment.user_reward_usd;

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
    });

    let Fulfillment {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        user_reward_usd: _,
        default_amount: _,
        base_exit_amount: _,
        quote_exit_amount: _,
    } = fulfillment;

    (return_base, return_quote)
}

/// Repays the loan as the liquidator.
/// Returns the extra base and quote assets
public fun repay_liquidation_in_full<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    mut coin: Coin<RepayAsset>,
    fulfillment: Fulfillment<RepayAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<RepayAsset>) {
    assert!(fulfillment.manager_id == margin_manager.id(), EInvalidMarginManager);
    margin_pool.update_state(clock);
    assert!(margin_manager.active_liquidation, ECannotLiquidate);
    margin_manager.active_liquidation = false;

    let margin_manager_id = margin_manager.id();
    let margin_pool_id = margin_pool.id();
    let coin_amount = coin.value();
    let repay_amount = fulfillment.repay_amount;

    let total_fulfillment_amount = repay_amount + fulfillment.pool_reward_amount;
    assert!(coin_amount >= total_fulfillment_amount, ERepaymentNotEnough);

    let cancel_amount = fulfillment.pool_reward_amount.min(fulfillment.default_amount);
    let pool_reward_amount = fulfillment.pool_reward_amount - cancel_amount;
    let default_amount = fulfillment.default_amount - cancel_amount;

    let repay_is_base = margin_manager.has_base_debt();
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);

    if (repay_is_base) {
        margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares - repay_shares;
    } else {
        margin_manager.quote_borrowed_shares = margin_manager.quote_borrowed_shares - repay_shares;
    };

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

    event::emit(LiquidationEvent {
        margin_manager_id,
        margin_pool_id,
        liquidation_amount: repay_amount,
        pool_reward_amount,
        user_reward_usd,
        default_amount,
    });

    let Fulfillment {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        user_reward_usd: _,
        default_amount: _,
        base_exit_amount: _,
        quote_exit_amount: _,
    } = fulfillment;

    coin
}

/// Destroys the request to borrow or withdraw if risk ratio conditions are met.
/// This function is called after the borrow or withdraw request is created.
public fun prove_and_destroy_request<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    request: Request,
) {
    assert!(request.margin_manager_id == margin_manager.id(), EInvalidMarginManager);
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    margin_pool.update_state(clock);
    let manager_info = margin_manager.manager_info<BaseAsset, QuoteAsset, DebtAsset>(
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

/// Risk ratio = total asset in USD / (total debt and interest in USD)
/// Risk ratio above 2.0 allows for withdrawal from balance manager, borrowing, and trading
/// Risk ratio between 1.25 and 2.0 allows for borrowing and trading
/// Risk ratio between 1.1 and 1.25 allows for trading only
/// Risk ratio below 1.1 allows for liquidation
/// These numbers can be updated by the admin. 1.25 is the default borrow risk ratio, this is equivalent to 5x leverage.
public fun manager_info<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &MarginPool<DebtAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    pool_id: ID,
): ManagerInfo {
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    let (base_debt, quote_debt) = margin_manager.calculate_debts<BaseAsset, QuoteAsset, DebtAsset>(
        margin_pool,
    );

    let (base_asset, quote_asset) = margin_manager.calculate_assets<BaseAsset, QuoteAsset>(
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

public fun deepbook_pool<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): ID {
    margin_manager.deepbook_pool
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
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): &BalanceManager {
    &margin_manager.balance_manager
}

public(package) fun balance_manager_mut<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
): &mut BalanceManager {
    &mut margin_manager.balance_manager
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun balance_manager_trading_mut<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): &mut BalanceManager {
    assert!(margin_manager.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &mut margin_manager.balance_manager
}

public(package) fun base_borrowed_shares<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    margin_manager.base_borrowed_shares
}

public(package) fun quote_borrowed_shares<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    margin_manager.quote_borrowed_shares
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun trade_proof<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): TradeProof {
    margin_manager.balance_manager.generate_proof_as_trader(&margin_manager.trade_cap, ctx)
}

public(package) fun id<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): ID {
    object::id(margin_manager)
}

/// Returns (base_asset, quote_asset) for margin manager.
public(package) fun calculate_assets<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = margin_manager.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

/// General helper for debt calculation and asset totals.
/// Returns (base_debt, quote_debt)
public(package) fun calculate_debts<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
): (u64, u64) {
    let debt_is_base = margin_manager.has_base_debt();
    let debt_shares = if (debt_is_base) {
        margin_manager.base_borrowed_shares
    } else {
        margin_manager.quote_borrowed_shares
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
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    manager_info: &ManagerInfo,
    ctx: &mut TxContext,
): (Fulfillment<DebtAsset>, Coin<BaseAsset>, Coin<QuoteAsset>) {
    let in_default = manager_info.risk_ratio() < constants::float_scaling(); // false
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

    let base = margin_manager.liquidation_withdraw_base(
        base_exit_amount,
        ctx,
    );
    let quote = margin_manager.liquidation_withdraw_quote(
        quote_exit_amount,
        ctx,
    );

    // If manager is in default, we repay as much as possible
    let repay_amount = if (in_default) {
        default_amount_to_repay
    } else {
        manager_info.calculate_debt_repay_amount(
            margin_manager.has_base_debt(),
            usd_amount_to_repay,
        )
    }; // 750 USDT

    let manager_id = margin_manager.id();
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
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == margin_manager.owner, EInvalidMarginManagerOwner);
}

fun borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BorrowAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let manager_id = margin_manager.id();
    let coin = margin_pool.borrow(loan_amount, clock, ctx);

    margin_manager.deposit<BaseAsset, QuoteAsset, BorrowAsset>(coin, ctx);

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
fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_pool.update_state(clock);

    let repay_is_base = margin_manager.has_base_debt();
    let repay_amount = if (repay_amount.is_some()) {
        repay_amount.destroy_some()
    } else {
        if (repay_is_base) {
            margin_pool.to_borrow_amount(margin_manager.base_borrowed_shares)
        } else {
            margin_pool.to_borrow_amount(margin_manager.quote_borrowed_shares)
        }
    };
    let available_balance = margin_manager.balance_manager().balance<RepayAsset>();
    let repay_amount = repay_amount.min(available_balance);
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);

    if (repay_is_base) {
        margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares - repay_shares;
    } else {
        margin_manager.quote_borrowed_shares = margin_manager.quote_borrowed_shares - repay_shares;
    };

    let coin = margin_manager.repay_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repay_amount,
        ctx,
    );

    margin_pool.repay(
        coin,
        clock,
    );

    event::emit(LoanRepaidEvent {
        margin_manager_id: margin_manager.id(),
        margin_pool_id: margin_pool.id(),
        repay_amount,
    });

    repay_amount
}

/// Deposit base asset to margin manager during liquidation
fun liquidation_deposit_base<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<BaseAsset>,
    ctx: &TxContext,
) {
    margin_manager.liquidation_deposit<BaseAsset, QuoteAsset, BaseAsset>(
        coin,
        ctx,
    )
}

/// Deposit quote asset to margin manager during liquidation
fun liquidation_deposit_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<QuoteAsset>,
    ctx: &TxContext,
) {
    margin_manager.liquidation_deposit<BaseAsset, QuoteAsset, QuoteAsset>(
        coin,
        ctx,
    )
}

fun liquidation_deposit<BaseAsset, QuoteAsset, DepositAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &TxContext,
) {
    let balance_manager = &mut margin_manager.balance_manager;

    balance_manager.deposit_with_cap<DepositAsset>(
        &margin_manager.deposit_cap,
        coin,
        ctx,
    )
}

fun liquidation_withdraw_base<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<BaseAsset> {
    margin_manager.liquidation_withdraw<BaseAsset, QuoteAsset, BaseAsset>(
        withdraw_amount,
        ctx,
    )
}

fun liquidation_withdraw_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<QuoteAsset> {
    margin_manager.liquidation_withdraw<BaseAsset, QuoteAsset, QuoteAsset>(
        withdraw_amount,
        ctx,
    )
}

fun liquidation_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let balance_manager = &mut margin_manager.balance_manager;

    balance_manager.withdraw_with_cap<WithdrawAsset>(
        &margin_manager.withdraw_cap,
        withdraw_amount,
        ctx,
    )
}

/// Helper function for Step 2: Repay the user's loan
fun repay_user_loan<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<DebtAsset>,
    repay_coin: Coin<DebtAsset>,
    debt_is_base: bool,
    repay_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    clock: &Clock,
) {
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);

    if (debt_is_base) {
        margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares - repay_shares;
    } else {
        margin_manager.quote_borrowed_shares = margin_manager.quote_borrowed_shares - repay_shares;
    };

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
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
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
        margin_manager.liquidation_withdraw_base(base_to_exit, ctx),
        margin_manager.liquidation_withdraw_quote(quote_to_exit, ctx),
    )
}

/// This can only be called by the manager owner
fun repay_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    validate_owner(margin_manager, ctx);
    let balance_manager = &mut margin_manager.balance_manager;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        &margin_manager.withdraw_cap,
        withdraw_amount,
        ctx,
    );

    coin
}

/// Helper function to check if margin manager has debt in base asset
fun has_base_debt<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): bool {
    margin_manager.base_borrowed_shares > 0
}
