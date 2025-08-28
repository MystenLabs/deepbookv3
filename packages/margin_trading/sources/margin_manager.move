// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_manager;

use deepbook::{
    balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap, TradeProof},
    pool::Pool
};
use margin_trading::{
    manager_info::{Self, ManagerInfo, Fulfillment},
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
const EDeepbookPoolNotAllowedForLoan: u64 = 6;
const EInvalidMarginManager: u64 = 7;
const EBorrowRiskRatioExceeded: u64 = 8;
const EWithdrawRiskRatioExceeded: u64 = 9;
const EInvalidDebtAsset: u64 = 10;
const ECannotLiquidate: u64 = 11;
const ERepaymentNotEnough: u64 = 12;
const EIncorrectMarginPool: u64 = 13;

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
    timestamp: u64,
}

/// Event emitted when loan is borrowed
public struct LoanBorrowedEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    loan_amount: u64,
    timestamp: u64,
}

/// Event emitted when loan is repaid
public struct LoanRepaidEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    repay_amount: u64,
    timestamp: u64,
}

/// Event emitted when margin manager is liquidated
public struct LiquidationEvent has copy, drop {
    margin_manager_id: ID,
    margin_pool_id: ID,
    liquidation_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    risk_ratio: u64,
    timestamp: u64,
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    registry.load_inner();
    assert!(registry.pool_enabled(pool), EMarginTradingNotAllowedInPool);

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
        timestamp: clock.timestamp_ms(),
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
): (Fulfillment, Coin<BaseAsset>, Coin<QuoteAsset>) {
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

    let fulfillment = manager_info.produce_fulfillment(self.id());

    let base = self.liquidation_withdraw_base(
        fulfillment.base_exit_amount(),
        ctx,
    );
    let quote = self.liquidation_withdraw_quote(
        fulfillment.quote_exit_amount(),
        ctx,
    );

    (fulfillment, base, quote)
}

/// Repays the loan as the liquidator.
/// Returns the extra coin not required for repayment.
public fun repay_liquidation_in_full<BaseAsset, QuoteAsset, RepayAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    margin_pool: &mut MarginPool<RepayAsset>,
    mut coin: Coin<RepayAsset>,
    fulfillment: Fulfillment,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RepayAsset> {
    registry.load_inner();
    margin_pool.update_state(clock);
    assert!(fulfillment.manager_id() == self.id(), EInvalidMarginManager);
    assert!(self.active_liquidation, ECannotLiquidate);
    self.active_liquidation = false;

    let margin_manager_id = self.id();
    let margin_pool_id = margin_pool.id();
    let repay_coin_amount = coin.value();
    let repay_amount = fulfillment.repay_amount();

    let total_fulfillment_amount = repay_amount + fulfillment.pool_reward_amount();
    assert!(repay_coin_amount >= total_fulfillment_amount, ERepaymentNotEnough);

    let repay_is_base = self.has_base_debt();
    let repay_shares = margin_pool.to_borrow_shares(repay_amount);
    self.decrease_borrowed_shares(repay_is_base, repay_shares);
    let default_shares = margin_pool.to_borrow_shares(fulfillment.default_amount());
    self.decrease_borrowed_shares(repay_is_base, default_shares);
    self.reset_margin_pool_id();

    let cancel_amount = fulfillment.pool_reward_amount().min(fulfillment.default_amount());
    let pool_reward_amount = fulfillment.pool_reward_amount() - cancel_amount;
    let default_amount = fulfillment.default_amount() - cancel_amount;

    let repay_coin = coin.split(total_fulfillment_amount, ctx);
    let timestamp = clock.timestamp_ms();

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
        timestamp,
    });

    let risk_ratio = fulfillment.fulfillment_risk_ratio();

    event::emit(LiquidationEvent {
        margin_manager_id,
        margin_pool_id,
        liquidation_amount: repay_amount,
        pool_reward_amount,
        default_amount,
        risk_ratio,
        timestamp,
    });

    fulfillment.drop();

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
        base_price_info_object,
        quote_price_info_object,
        margin_pool,
        pool,
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
        base_price_info_object,
        quote_price_info_object,
        margin_pool,
        pool,
        liquidation_coin,
        clock,
        ctx,
    );
    quote_coin.join(liquidation_coin);

    (base_coin, quote_coin)
}

public fun liquidate_loan<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    liquidation_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    let (fulfillment, base_coin, quote_coin) = self.liquidate<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        margin_pool,
        pool,
        clock,
        ctx,
    );

    let remainder_coin = self.repay_liquidation_in_full<BaseAsset, QuoteAsset, DebtAsset>(
        registry,
        margin_pool,
        liquidation_coin,
        fulfillment,
        clock,
        ctx,
    );

    (base_coin, quote_coin, remainder_coin)
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
    let timestamp = clock.timestamp_ms();

    self.deposit<BaseAsset, QuoteAsset, BorrowAsset>(registry, coin, ctx);

    event::emit(LoanBorrowedEvent {
        margin_manager_id: manager_id,
        margin_pool_id: margin_pool.id(),
        loan_amount,
        timestamp,
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
    let timestamp = clock.timestamp_ms();

    margin_pool.repay(
        coin,
        clock,
    );

    event::emit(LoanRepaidEvent {
        margin_manager_id: self.id(),
        margin_pool_id: margin_pool.id(),
        repay_amount,
        timestamp,
    });

    repay_amount
}

fun reset_margin_pool_id<BaseAsset, QuoteAsset>(self: &mut MarginManager<BaseAsset, QuoteAsset>) {
    if (self.base_borrowed_shares == 0 && self.quote_borrowed_shares == 0) {
        self.margin_pool_id = option::none();
    };
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
