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
    governance::TradeParamsUpdateEvent,
    math,
    pool::Pool,
    registry
};
use margin_trading::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle::calculate_target_amount
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::{Self, Coin}, event};
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
const EInvalidManagerForSharing: u64 = 14;

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
    borrowed_shares: u64,
    active_liquidation: bool, // without this, the margin manager can be liquidated multiple times within the same tx
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
    pool_reward_amount: u64,
    default_amount: u64,
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
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
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

    let (base_per_dollar, quote_per_dollar) = assets_per_dollar<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    let (base_asset, quote_asset) = self.calculate_assets(pool);

    if (self.borrowed_shares > 0) {
        let risk_ratio = if (self.margin_pool_id.contains(&base_margin_pool.id())) {
            let base_debt = base_margin_pool.borrow_shares_to_amount(self.borrowed_shares, clock);
            let assets_per_base =
                math::div(math::mul(quote_asset, quote_per_dollar), base_per_dollar) + base_asset;
            let max_risk_ratio = margin_constants::max_risk_ratio();
            let risk_ratio = if (assets_per_base > math::mul(base_debt, max_risk_ratio)) {
                max_risk_ratio
            } else {
                math::div(assets_per_base, base_debt)
            };

            risk_ratio
        } else {
            let quote_debt = quote_margin_pool.borrow_shares_to_amount(self.borrowed_shares, clock);
            let assets_per_quote =
                math::div(math::mul(base_asset, base_per_dollar), quote_per_dollar) + quote_asset;
            let max_risk_ratio = margin_constants::max_risk_ratio();
            let risk_ratio = if (assets_per_quote > math::mul(quote_debt, max_risk_ratio)) {
                max_risk_ratio
            } else {
                math::div(assets_per_quote, quote_debt)
            };

            risk_ratio
        };
        assert!(registry.can_borrow(pool.id(), risk_ratio), EBorrowRiskRatioExceeded);
    };

    coin
}

/// Borrow the base asset using the margin manager.
/// Request must be destroyed using prove_and_destroy_request
public fun borrow_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
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
    self.borrowed_shares = total_shares;
    self.margin_pool_id = option::some(base_margin_pool.id());
    self.deposit(registry, coin, ctx);

    let (base_per_dollar, quote_per_dollar) = assets_per_dollar<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    let assets_per_base =
        math::div(math::mul(quote_asset, quote_per_dollar), base_per_dollar) + base_asset;
    let max_risk_ratio = margin_constants::max_risk_ratio();
    let risk_ratio = if (assets_per_base > math::mul(total_borrow, max_risk_ratio)) {
        max_risk_ratio
    } else {
        math::div(assets_per_base, total_borrow)
    };
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
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
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
    self.borrowed_shares = total_shares;
    self.margin_pool_id = option::some(quote_margin_pool.id());
    self.deposit(registry, coin, ctx);

    let (base_per_dollar, quote_per_dollar) = assets_per_dollar<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    let assets_per_quote =
        math::div(math::mul(base_asset, base_per_dollar), quote_per_dollar) + quote_asset;
    let max_risk_ratio = margin_constants::max_risk_ratio();
    let risk_ratio = if (assets_per_quote > math::mul(total_borrow, max_risk_ratio)) {
        max_risk_ratio
    } else {
        math::div(assets_per_quote, total_borrow)
    };
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
    percentage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        percentage,
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
    percentage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    self.validate_owner(ctx);
    assert!(self.margin_pool_id.contains(&margin_pool.id()), EIncorrectMarginPool);

    self.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        percentage,
        clock,
        ctx,
    )
}

// === Public Functions - Liquidation - Receive Assets before liquidation ===
public fun liquidate_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    margin_pool: &mut MarginPool<BaseAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    mut repay_coin: Coin<BaseAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let debt = margin_pool.borrow_shares_to_amount(self.borrowed_shares, clock);
    let (base_per_dollar, quote_per_dollar) = assets_per_dollar<BaseAsset, QuoteAsset>(
        registry,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    let (base_asset, quote_asset) = self.calculate_assets(pool);
    let assets_per_base =
        math::div(math::mul(quote_asset, quote_per_dollar), base_per_dollar) + base_asset;
    let liquidation_with_user =
        constants::float_scaling() + registry.user_liquidation_reward(pool.id());
    let debt_with_reward = math::mul(debt, liquidation_with_user);

    if (assets_per_base <= debt_with_reward) {
        let max_to_repay = math::div(assets_per_base, liquidation_with_user);
        let repay_amount = max_to_repay.min(repay_coin.value());
        let repay_ratio = math::div(repay_amount, max_to_repay);
        margin_pool.repay_coin(repay_coin.split(repay_amount, ctx));
        let mut base_out = self.liquidation_withdraw_base(
            math::mul(base_asset, repay_ratio),
            ctx,
        );
        base_out.join(repay_coin);
        let quote_out = self.liquidation_withdraw_quote(
            math::mul(quote_asset, repay_ratio),
            ctx,
        );
        let repay_shares = math::mul(self.borrowed_shares, repay_ratio);
        margin_pool.repay_shares(repay_shares, clock);
        margin_pool.decrease_supply_absolute(math::mul(debt - repay_amount, repay_ratio));
        self.borrowed_shares = self.borrowed_shares - repay_shares;

        return (base_out, quote_out)
    };

    let liquidation_reward =
        registry.user_liquidation_reward(pool.id()) + registry.pool_liquidation_reward(pool.id());
    let debt_with_reward = math::mul(debt, liquidation_reward);
    if (assets_per_base <= debt_with_reward) {
        let max_to_repay = math::div(assets_per_base, liquidation_with_user);
        let repay_amount = max_to_repay.min(repay_coin.value());
        let repay_ratio = math::div(repay_amount, max_to_repay);
        margin_pool.repay_coin(repay_coin.split(repay_amount, ctx));
        let mut base_out = self.liquidation_withdraw_base(
            math::mul(base_asset, repay_ratio),
            ctx,
        );
        base_out.join(repay_coin);
        let quote_out = self.liquidation_withdraw_quote(
            math::mul(quote_asset, repay_ratio),
            ctx,
        );
        let repay_shares = math::mul(self.borrowed_shares, repay_ratio);
        margin_pool.repay_shares(repay_shares, clock);
        margin_pool.increase_supply_absolute(math::mul(max_to_repay - debt, repay_ratio));
        self.borrowed_shares = self.borrowed_shares - repay_shares;

        return (base_out, quote_out)
    };

    let target_ratio = registry.target_liquidation_risk_ratio(pool.id());
    let numerator = math::mul(target_ratio, assets_per_base) - debt;
    let denominator = target_ratio - (constants::float_scaling() + liquidation_reward);
    let debt_with_reward = math::div(numerator, denominator);
    let asset_ratio_to_give = math::div(debt_with_reward, assets_per_base);
    let max_to_repay = math::div(debt_with_reward, liquidation_with_user);
    let debt_repay = math::div(debt_with_reward, liquidation_reward);

    let repay_amount = max_to_repay.min(repay_coin.value());
    let repay_ratio = math::div(repay_amount, max_to_repay);
    margin_pool.repay_coin(repay_coin.split(repay_amount, ctx));
    let mut base_out = self.liquidation_withdraw_base(
        math::mul(math::mul(base_asset, repay_ratio), asset_ratio_to_give),
        ctx,
    );
    base_out.join(repay_coin);
    let quote_out = self.liquidation_withdraw_quote(
        math::mul(math::mul(quote_asset, repay_ratio), asset_ratio_to_give),
        ctx,
    );
    let repay_shares = math::mul(
        self.borrowed_shares,
        math::mul(math::div(debt_repay, debt), repay_ratio),
    );
    margin_pool.repay_shares(repay_shares, clock);
    margin_pool.increase_supply_absolute(math::mul(max_to_repay - debt_repay, repay_ratio));
    self.borrowed_shares = self.borrowed_shares - repay_shares;

    (base_out, quote_out)
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

public(package) fun borrowed_shares<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
): u64 {
    self.borrowed_shares
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
        borrowed_shares: 0,
        active_liquidation: false,
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
    percentage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let percentage = percentage.min(constants::float_scaling());
    let repay_shares = math::mul(percentage, self.borrowed_shares);
    let repay_amount = margin_pool.repay_shares(repay_shares, clock);
    let available_balance = self.balance_manager().balance<RepayAsset>();
    assert!(available_balance >= repay_amount, ERepaymentNotEnough);

    let coin: Coin<RepayAsset> = self.repay_withdraw(repay_amount, ctx);
    margin_pool.repay_coin(coin);

    self.borrowed_shares = self.borrowed_shares - repay_shares;
    if (self.borrowed_shares == 0) {
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

/// Helper function to determine if margin manager can borrow from a margin pool
fun can_borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<BorrowAsset>,
): bool {
    let no_current_loan = self.margin_pool_id.is_none();

    self.margin_pool_id.contains(&margin_pool.id()) || no_current_loan
}

fun assets_per_dollar<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): (u64, u64) {
    let base_per_dollar = calculate_target_amount<BaseAsset>(
        base_price_info_object,
        registry,
        constants::float_scaling(),
        clock,
    );

    let quote_per_dollar = calculate_target_amount<QuoteAsset>(
        quote_price_info_object,
        registry,
        constants::float_scaling(),
        clock,
    );

    (base_per_dollar, quote_per_dollar)
}
