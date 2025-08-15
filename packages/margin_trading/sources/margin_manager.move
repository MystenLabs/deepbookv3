// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_manager;

use deepbook::{
    balance_manager::{
        Self,
        mint_deposit_cap,
        mint_trade_cap,
        mint_withdraw_cap,
        BalanceManager,
        TradeCap,
        DepositCap,
        WithdrawCap,
        TradeProof
    },
    constants,
    math,
    pool::Pool
};
use margin_trading::{
    margin_pool::{MarginPool, RepayReceipt},
    margin_registry::MarginRegistry,
    oracle::{calculate_usd_price, calculate_target_amount}
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::Coin, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginTradingNotAllowedInPool: u64 = 1;
const EInvalidMarginManagerOwner: u64 = 6;
const ECannotHaveLoanInBothMarginPools: u64 = 7;
const EIncorrectDeepBookPool: u64 = 8;
const EIncorrectRepayAmount: u64 = 9;

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
}

public struct Fulfillment {
    base_to_exit: u64,
    quote_to_exit: u64,
    return_amount: u64,
    pool_reward_amount: u64,
}

/// Request_type: 0 for withdraw, 1 for borrow
public struct Request {
    margin_manager_id: ID,
    request_type: u8,
}

public struct AssetInfo has copy, drop, store {
    asset: u64,
    debt: u64,
    usd_asset: u64,
    usd_debt: u64,
}

public struct ManagerInfo has copy, drop, store {
    base: AssetInfo,
    quote: AssetInfo,
    risk_ratio: u64, // 9 decimals
}

/// Event emitted when a new margin_manager is created.
public struct MarginManagerEvent has copy, drop {
    margin_manager_id: ID,
    balance_manager_id: ID,
    owner: address,
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(pool: &Pool<BaseAsset, QuoteAsset>, ctx: &mut TxContext) {
    assert!(pool.margin_trading_enabled(), EMarginTradingNotAllowedInPool);

    let id = object::new(ctx);

    let mut balance_manager = balance_manager::new_with_custom_owner(id.to_address(), ctx);
    let deposit_cap = mint_deposit_cap(&mut balance_manager, ctx);
    let withdraw_cap = mint_withdraw_cap(&mut balance_manager, ctx);
    let trade_cap = mint_trade_cap(&mut balance_manager, ctx);

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
    base_margin_pool.update_state(clock);
    let loan_shares = base_margin_pool.state().to_borrow_shares(loan_amount);
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
    quote_margin_pool.update_state(clock);
    let loan_shares = quote_margin_pool.state().to_borrow_shares(loan_amount);
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
    margin_manager.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        repay_amount,
        clock,
        ctx,
    )
}

/// Returns the risk ratio from the ManagerInfo
public fun risk_ratio(manager_info: &ManagerInfo): u64 {
    manager_info.risk_ratio
}

/// Returns the base and quote AssetInfo from the ManagerInfo
public fun asset_info(manager_info: &ManagerInfo): (AssetInfo, AssetInfo) {
    (manager_info.base, manager_info.quote)
}

/// Returns (asset, debt, usd_asset, usd_debt) given AssetInfo
public fun asset_debt_amount(asset_info: &AssetInfo): (u64, u64, u64, u64) {
    (asset_info.asset, asset_info.debt, asset_info.usd_asset, asset_info.usd_debt)
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
): (Fulfillment) {
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);
    margin_pool.update_state(clock);

    // cancel all orders. at this point, all available assets are in the balance manager.
    let trade_proof = margin_manager.trade_proof(ctx);
    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);

    produce_fulfillment<BaseAsset, QuoteAsset, DebtAsset>(
        margin_manager,
        margin_pool,
        registry,
        base_price_info_object,
        quote_price_info_object,
        pool.id(),
        clock,
    )
}

public fun validate_fulfillment<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    fulfillment: Fulfillment,
    repay_receipt: RepayReceipt,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    assert!(fulfillment.return_amount == repay_receipt.paid_amount(), EIncorrectRepayAmount);
    assert!(fulfillment.pool_reward_amount == repay_receipt.reward_amount(), EIncorrectRepayAmount);

    let base = margin_manager.liquidation_withdraw_base(
        fulfillment.base_to_exit,
        ctx,
    );
    let quote = margin_manager.liquidation_withdraw_quote(
        fulfillment.quote_to_exit,
        ctx,
    );

    let Fulfillment {
        base_to_exit: _,
        quote_to_exit: _,
        return_amount: _,
        pool_reward_amount: _,
    } = fulfillment;

    (base, quote)
}

public fun deepbook_pool<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): ID {
    margin_manager.deepbook_pool
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
public(package) fun total_assets<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = margin_manager.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

// === Private Functions ===
// calculate quantity of debt that must be removed to reach target risk ratio.
// D = debt, A = assets, T = target risk ratio, R = liquidation reward
// amount_to_exit = (DT + TA - D) / (T + TR - 1)
fun produce_fulfillment<BaseAsset, QuoteAsset, DebtAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &MarginPool<DebtAsset>,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    pool_id: ID,
    clock: &Clock,
): Fulfillment {
    let borrowed_shares = margin_manager
        .base_borrowed_shares
        .max(margin_manager.quote_borrowed_shares);
    let debt_amount = margin_pool.state().to_borrow_amount(borrowed_shares);
    let base_in_manager = margin_manager.balance_manager().balance<BaseAsset>();
    let quote_in_manager = margin_manager.balance_manager().balance<QuoteAsset>();

    let debt = calculate_usd_price<DebtAsset>(
        base_price_info_object,
        registry,
        debt_amount,
        clock,
    );
    let base_in_usd = calculate_usd_price<BaseAsset>(
        base_price_info_object,
        registry,
        base_in_manager,
        clock,
    );
    let quote_in_usd = calculate_usd_price<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_in_manager,
        clock,
    );

    let target_ratio = registry.target_liquidation_risk_ratio(pool_id);
    let user_liquidation_reward = registry.user_liquidation_reward(pool_id);
    let pool_liquidation_reward = registry.pool_liquidation_reward(pool_id);
    let liquidation_reward = user_liquidation_reward + pool_liquidation_reward;

    let assets = base_in_usd + quote_in_usd;
    let numerator = math::mul(debt, target_ratio) + math::mul(assets, target_ratio) - debt;
    let denominator =
        target_ratio + math::mul(target_ratio, liquidation_reward) - constants::float_scaling();

    // this is the amount that needs to exit the balance manager to reach the target risk ratio.
    // it may be greater than the total assets in the balance manager.
    let mut amount_to_exit_usd = math::div(numerator, denominator);
    let (base_to_exit_usd, quote_to_exit_usd) = if (base_in_usd > quote_in_usd) {
        let base_usd = amount_to_exit_usd.min(base_in_usd);
        amount_to_exit_usd = amount_to_exit_usd - base_usd;
        let quote_usd = amount_to_exit_usd.min(quote_in_usd);
        (base_usd, quote_usd)
    } else {
        let quote_usd = amount_to_exit_usd.min(quote_in_usd);
        amount_to_exit_usd = amount_to_exit_usd - quote_usd;
        let base_usd = amount_to_exit_usd.min(base_in_usd);
        (base_usd, quote_usd)
    };

    // the amount that will leave the margin manager.
    let total_to_give_up = base_to_exit_usd + quote_to_exit_usd;
    // amount that will go to the margin pool.
    let total_to_give_up = total_to_give_up - math::mul(total_to_give_up, user_liquidation_reward);

    let return_price_info_object = if (base_in_usd > quote_in_usd) {
        base_price_info_object
    } else {
        quote_price_info_object
    };

    let quantity_to_return = calculate_target_amount<DebtAsset>(
        return_price_info_object,
        registry,
        total_to_give_up,
        clock,
    );

    let base_to_exit = calculate_target_amount<BaseAsset>(
        base_price_info_object,
        registry,
        base_to_exit_usd,
        clock,
    );

    let quote_to_exit = calculate_target_amount<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_to_exit_usd,
        clock,
    );

    Fulfillment {
        base_to_exit,
        quote_to_exit,
        return_amount: quantity_to_return,
        pool_reward_amount: debt_amount.max(quantity_to_return) - quantity_to_return,
    }
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
    margin_manager.validate_owner(ctx);
    margin_pool.update_state(clock);
    let repay_amount = if (repay_amount.is_some()) {
        repay_amount.destroy_some()
    } else {
        margin_pool.state().to_borrow_amount(margin_manager.base_borrowed_shares)
    };
    let available_balance = margin_manager.balance_manager().balance<RepayAsset>();
    let repay_amount = repay_amount.min(available_balance);
    let repay_shares = margin_pool.state().to_borrow_shares(repay_amount);
    margin_manager.base_borrowed_shares = margin_manager.base_borrowed_shares - repay_shares;

    let coin = margin_manager.repay_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repay_amount,
        ctx,
    );

    margin_pool.repay(
        coin,
        clock,
    );

    repay_amount
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

/// This can only be called by the manager owner
fun repay_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    assert!(ctx.sender() == margin_manager.owner, EInvalidMarginManagerOwner);

    let balance_manager = &mut margin_manager.balance_manager;
    let withdraw_cap = &margin_manager.withdraw_cap;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        withdraw_cap,
        withdraw_amount,
        ctx,
    );

    coin
}

fun in_default(risk_ratio: u64): bool {
    risk_ratio < constants::float_scaling() // Risk ratio < 1.0 means the manager is in default.
}
