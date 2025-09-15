// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_manager;

use deepbook::{
    balance_manager::{
        Self,
        BalanceManager,
        TradeCap,
        DepositCap,
        WithdrawCap,
        TradeProof,
        DeepBookReferral
    },
    constants,
    math,
    pool::Pool
};
use margin_trading::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle::calculate_target_currency
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
const EBorrowRiskRatioExceeded: u64 = 7;
const EWithdrawRiskRatioExceeded: u64 = 8;
const ECannotLiquidate: u64 = 9;
const EIncorrectMarginPool: u64 = 10;
const EInvalidManagerForSharing: u64 = 11;
const ENotReduceOnlyOrder: u64 = 12;

// === Structs ===
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
}

/// Hot potato to ensure manager is shared during creation
public struct ManagerInitializer {
    margin_manager_id: ID,
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
    total_borrow: u64,
    total_shares: u64,
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
    timestamp: u64,
}

// === Public Functions - Margin Manager ===
/// Creates a new margin manager and shares it.
public fun new<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let manager = new_margin_manager(pool, registry, clock, ctx);
    transfer::share_object(manager);
}

/// Creates a new margin manager and returns it along with an initializer.
/// The initializer is used to ensure the margin manager is shared after creation.
public fun new_with_initializer<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (MarginManager<BaseAsset, QuoteAsset>, ManagerInitializer) {
    let manager = new_margin_manager(pool, registry, clock, ctx);
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

/// Set the referral for the margin manager.
public fun set_referral<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    referral_cap: &DeepBookReferral,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    self.balance_manager.set_referral(referral_cap, &self.trade_cap);
}

/// Unset the referral for the margin manager.
public fun unset_referral<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
) {
    self.validate_owner(ctx);
    self.balance_manager.unset_referral(&self.trade_cap);
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

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit. This is restricted through the Request.
/// Request must be destroyed using prove_and_destroy_request
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

    let balance_manager = &mut self.balance_manager;
    let withdraw_cap = &self.withdraw_cap;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        withdraw_cap,
        withdraw_amount,
        ctx,
    );

    if (self.margin_pool_id.contains(&base_margin_pool.id())) {
        let risk_ratio = self.risk_ratio(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            base_margin_pool,
            clock,
        );
        assert!(registry.can_withdraw(pool.id(), risk_ratio), EWithdrawRiskRatioExceeded);
    } else if (self.margin_pool_id.contains(&quote_margin_pool.id())) {
        let risk_ratio = self.risk_ratio(
            registry,
            base_oracle,
            quote_oracle,
            pool,
            quote_margin_pool,
            clock,
        );
        assert!(registry.can_withdraw(pool.id(), risk_ratio), EWithdrawRiskRatioExceeded);
    };

    coin
}

/// Borrow the base asset using the margin manager.
/// Request must be destroyed using prove_and_destroy_request
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
    assert!(self.can_borrow(base_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        base_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    let (coin, total_borrow, total_shares) = base_margin_pool.borrow(loan_amount, clock, ctx);
    self.borrowed_base_shares = total_shares;
    self.margin_pool_id = option::some(base_margin_pool.id());
    self.deposit(registry, coin, ctx);
    let risk_ratio = self.risk_ratio(
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
        total_borrow,
        total_shares,
        timestamp: clock.timestamp_ms(),
    });
}

/// Borrow the quote asset using the margin manager.
/// Request must be destroyed using prove_and_destroy_request
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
    assert!(self.can_borrow(quote_margin_pool), ECannotHaveLoanInMoreThanOneMarginPool);
    assert!(
        quote_margin_pool.deepbook_pool_allowed(self.deepbook_pool),
        EDeepbookPoolNotAllowedForLoan,
    );
    let (coin, total_borrow, total_shares) = quote_margin_pool.borrow(loan_amount, clock, ctx);
    self.borrowed_quote_shares = total_shares;
    self.margin_pool_id = option::some(quote_margin_pool.id());
    self.deposit(registry, coin, ctx);
    let risk_ratio = self.risk_ratio(
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
        total_borrow,
        total_shares,
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

// === Public Functions - Liquidation - Receive Assets before liquidation ===
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
    let risk_ratio = self.risk_ratio(
        registry,
        base_oracle,
        quote_oracle,
        pool,
        margin_pool,
        clock,
    );
    assert!(registry.can_liquidate(pool.id(), risk_ratio), ECannotLiquidate);
    let trade_proof = self.trade_proof(ctx);
    pool.cancel_all_orders(&mut self.balance_manager, &trade_proof, clock, ctx);

    // 2. Calculate the maximum debt that can be repaid. The margin manager can be in three scenarios:
    // a) Assets <= Debt + user_reward: Full liquidation, repay as much debt as possible, lending pool may incur bad debt.
    // b) Debt + user_reward < Assets <= Debt + user_reward + pool_reward: There are enough assets to cover the debt, but pool may not get full rewards.
    // c) Debt + user_reward + pool_reward < Assets: There are enough assets to cover everything. We may not need to liquidate the full position.
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let debt = margin_pool.borrow_shares_to_amount(borrowed_shares, clock);
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    let debt_is_base =
        type_name::with_defining_ids<DebtAsset>() == type_name::with_defining_ids<BaseAsset>();
    let assets_per_debt = self.assets_per_debt(registry, pool, base_oracle, quote_oracle, clock);

    let liquidation_reward_with_user_pool =
        constants::float_scaling() + registry.user_liquidation_reward(pool.id()) + registry.pool_liquidation_reward(pool.id());

    let target_ratio = registry.target_liquidation_risk_ratio(pool.id());
    let numerator = math::mul(target_ratio, debt) - assets_per_debt;
    let denominator = target_ratio - liquidation_reward_with_user_pool;
    let debt_repay = math::div(numerator, denominator);
    // We have to pay the minimum between our current debt and the debt required to reach the target ratio.
    // In other words, if our assets are low, we pay off all debt (full liquidation)
    // if our assets are high, we pay off some of the debt (partial liquidation)
    let debt_repay = debt_repay.min(debt);
    let debt_with_reward = math::mul(debt_repay, liquidation_reward_with_user_pool);
    // max absolute debt amount that can be repaid
    let debt_can_repay = debt_with_reward.min(assets_per_debt);
    let liquidation_reward_with_user =
        constants::float_scaling() + registry.user_liquidation_reward(pool.id());
    let max_to_repay = math::div(debt_can_repay, liquidation_reward_with_user);

    let repay_amount = max_to_repay.min(repay_coin.value());
    let repay_ratio = math::div(repay_amount, max_to_repay);

    // Multiply total borrowed shares by two ratios: how much of the debt we are repaying,
    // and how much of that debt the Coin is covering.
    let repay_shares = math::mul(
        borrowed_shares,
        math::mul(math::div(debt_repay, debt), repay_ratio),
    );
    let (debt_repaid, pool_reward, pool_default) = margin_pool.repay_liquidation(
        repay_shares,
        repay_coin.split(repay_amount, ctx),
        clock,
    );
    if (debt_is_base) {
        self.borrowed_base_shares = self.borrowed_base_shares - repay_shares;
    } else {
        self.borrowed_quote_shares = self.borrowed_quote_shares - repay_shares;
    };

    // for every unit of coin provided, how many units of base + quote asset will be given back
    let asset_ratio_to_give = math::div(debt_with_reward, assets_per_debt);
    let base_out = self.liquidation_withdraw(
        math::mul(math::mul(base_asset, repay_ratio), asset_ratio_to_give),
        ctx,
    );
    let quote_out = self.liquidation_withdraw(
        math::mul(math::mul(quote_asset, repay_ratio), asset_ratio_to_give),
        ctx,
    );

    event::emit(LiquidationEvent {
        margin_manager_id: self.id(),
        margin_pool_id: margin_pool.id(),
        liquidation_amount: debt_repaid,
        pool_reward,
        pool_default,
        risk_ratio: math::div(math::mul(assets_per_debt, constants::float_scaling()), debt),
        timestamp: clock.timestamp_ms(),
    });

    (base_out, quote_out, repay_coin)
}

// Get the risk ratio of the margin manager.
public fun risk_ratio<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    pool: &Pool<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    clock: &Clock,
): u64 {
    let assets_per_debt = self.assets_per_debt(registry, pool, base_oracle, quote_oracle, clock);
    let borrowed_shares = self.borrowed_base_shares.max(self.borrowed_quote_shares);
    let debt = margin_pool.borrow_shares_to_amount(borrowed_shares, clock);
    let max_risk_ratio = margin_constants::max_risk_ratio();
    if (assets_per_debt > math::mul(debt, max_risk_ratio)) {
        max_risk_ratio
    } else {
        math::div(assets_per_debt, debt)
    }
}

// === Public Functions - Read Only ===
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

public fun deepbook_pool<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    self.deepbook_pool
}

public fun borrowed_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): (u64, u64) {
    (self.borrowed_base_shares, self.borrowed_quote_shares)
}

// === Public-Package Functions ===
public(package) fun assert_place_reduce_only<BaseAsset, QuoteAsset, DebtAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    _margin_pool: &MarginPool<DebtAsset>,
    is_bid: bool,
) {
    if (self.borrowed_base_shares == 0 && self.borrowed_quote_shares == 0) {
        return
    };

    if (type_name::with_defining_ids<DebtAsset>() == type_name::with_defining_ids<BaseAsset>()) {
        assert!(is_bid, ENotReduceOnlyOrder);
    } else {
        assert!(!is_bid, ENotReduceOnlyOrder);
    };
}

public(package) fun balance_manager<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): &BalanceManager {
    &self.balance_manager
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun balance_manager_trading_mut<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): &mut BalanceManager {
    assert!(self.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &mut self.balance_manager
}

/// Unwraps balance manager for trading in deepbook.
public(package) fun trade_proof<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
): TradeProof {
    self.balance_manager.generate_proof_as_trader(&self.trade_cap, ctx)
}

public(package) fun id<BaseAsset, QuoteAsset>(self: &MarginManager<BaseAsset, QuoteAsset>): ID {
    self.id.to_inner()
}

// === Private Functions ===
fun new_margin_manager<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): MarginManager<BaseAsset, QuoteAsset> {
    registry.load_inner();
    assert!(registry.pool_enabled(pool), EMarginTradingNotAllowedInPool);

    let id = object::new(ctx);
    let margin_manager_id = id.to_inner();

    let (
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
    ) = balance_manager::new_with_custom_owner_and_caps(id.to_address(), ctx);

    event::emit(MarginManagerEvent {
        margin_manager_id,
        balance_manager_id: object::id(&balance_manager),
        owner: ctx.sender(),
        timestamp: clock.timestamp_ms(),
    });

    MarginManager<BaseAsset, QuoteAsset> {
        id,
        owner: ctx.sender(),
        deepbook_pool: pool.id(),
        margin_pool_id: option::none(),
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
        borrowed_base_shares: 0,
        borrowed_quote_shares: 0,
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
/// TODO: Can the conversion here cause a rounding error?
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

fun assets_per_debt<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_oracle: &PriceInfoObject,
    quote_oracle: &PriceInfoObject,
    clock: &Clock,
): u64 {
    if (self.margin_pool_id.is_none()) {
        return 0
    };
    let (base_asset, quote_asset) = self.calculate_assets(pool);

    if (self.borrowed_base_shares > 0) {
        calculate_target_currency<QuoteAsset, BaseAsset>(registry, quote_oracle, base_oracle, quote_asset, clock) + base_asset
    } else {
        calculate_target_currency<BaseAsset, QuoteAsset>(registry, base_oracle, quote_oracle, base_asset, clock) + quote_asset
    }
}
