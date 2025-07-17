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
        WithdrawCap
    },
    constants,
    math,
    pool::Pool
};
use margin_trading::{
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle::{calculate_usd_price, calculate_target_amount}
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::{Self, Coin}, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginPairNotAllowed: u64 = 1;
const EInvalidMarginManager: u64 = 4;
const EBorrowRiskRatioExceeded: u64 = 5;
const EWithdrawRiskRatioExceeded: u64 = 6;
const ECannotLiquidate: u64 = 8;
const EInvalidMarginManagerOwner: u64 = 9;

// === Constants ===
const WITHDRAW: u8 = 0;
const BORROW: u8 = 1;

// === Structs ===
/// A shared object that wraps a `BalanceManager` and provides the necessary capabilities to deposit, withdraw, and trade.
public struct MarginManager<phantom BaseAsset, phantom QuoteAsset> has key, store {
    id: UID,
    owner: address,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    trade_cap: TradeCap,
}

/// Event emitted when a new margin_manager is created.
public struct MarginManagerEvent has copy, drop {
    margin_manager_id: ID,
    balance_manager_id: ID,
    owner: address,
}

/// Event emitted when a new margin_manager is created.
public struct LiquidationEvent has copy, drop {
    margin_manager_id: ID,
    base_amount: u64,
    quote_amount: u64,
    liquidator: address,
}

/// Request_type: 0 for withdraw, 1 for borrow
public struct Request {
    margin_manager_id: ID,
    request_type: u8,
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(margin_registry: &MarginRegistry, ctx: &mut TxContext) {
    assert!(margin_registry.margin_pair_allowed<BaseAsset, QuoteAsset>(), EMarginPairNotAllowed);

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
        balance_manager,
        deposit_cap,
        withdraw_cap,
        trade_cap,
    };

    transfer::share_object(margin_manager)
}

/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == margin_manager.owner, EInvalidMarginManagerOwner);

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
    assert!(ctx.sender() == margin_manager.owner, EInvalidMarginManagerOwner);

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
    margin_pool: &mut MarginPool<BaseAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    margin_manager.borrow<BaseAsset, QuoteAsset, BaseAsset>(margin_pool, loan_amount, clock, ctx)
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    margin_manager.borrow<BaseAsset, QuoteAsset, QuoteAsset>(margin_pool, loan_amount, clock, ctx)
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

/// Destroys the request to borrow or withdraw if risk ratio conditions are met.
/// This function is called after the borrow or withdraw request is created.
public fun risk_ratio_proof<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    request: Request,
) {
    assert!(request.margin_manager_id == margin_manager.id(), EInvalidMarginManager);

    let risk_ratio = risk_ratio<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        base_margin_pool,
        quote_margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    if (request.request_type == BORROW) {
        assert!(registry.can_borrow<BaseAsset, QuoteAsset>(risk_ratio), EBorrowRiskRatioExceeded);
    } else if (request.request_type == WITHDRAW) {
        assert!(
            registry.can_withdraw<BaseAsset, QuoteAsset>(risk_ratio),
            EWithdrawRiskRatioExceeded,
        );
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
public fun risk_ratio<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): u64 {
    let (base_debt, quote_debt) = margin_manager_debt<BaseAsset, QuoteAsset>(
        base_margin_pool,
        quote_margin_pool,
        margin_manager,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager_asset<BaseAsset, QuoteAsset>(
        pool,
        margin_manager,
    );

    let base_usd_debt = calculate_usd_price<BaseAsset>(
        registry,
        base_debt,
        clock,
        base_price_info_object,
    );
    let base_usd_asset = calculate_usd_price<BaseAsset>(
        registry,
        base_asset,
        clock,
        base_price_info_object,
    );
    let quote_usd_debt = calculate_usd_price<QuoteAsset>(
        registry,
        quote_debt,
        clock,
        quote_price_info_object,
    );
    let quote_usd_asset = calculate_usd_price<QuoteAsset>(
        registry,
        quote_asset,
        clock,
        quote_price_info_object,
    );
    let total_usd_debt = base_usd_debt + quote_usd_debt; // 6 decimals
    let total_usd_asset = base_usd_asset + quote_usd_asset; // 6 decimals

    if (total_usd_debt == 0 || total_usd_asset > 1000 * total_usd_debt) {
        1000 * constants::float_scaling() // 9 decimals, risk ratio above 1000 will be considered as 1000
    } else {
        math::div(total_usd_asset, total_usd_debt) // 9 decimals
    }
}

/// Liquidates a margin manager
public fun liquidate<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let (base_debt, quote_debt) = margin_manager_debt<BaseAsset, QuoteAsset>(
        base_margin_pool,
        quote_margin_pool,
        margin_manager,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager_asset<BaseAsset, QuoteAsset>(
        pool,
        margin_manager,
    );

    let base_usd_debt = calculate_usd_price<BaseAsset>(
        registry,
        base_debt,
        clock,
        base_price_info_object,
    );
    let base_usd_asset = calculate_usd_price<BaseAsset>(
        registry,
        base_asset,
        clock,
        base_price_info_object,
    );
    let quote_usd_debt = calculate_usd_price<QuoteAsset>(
        registry,
        quote_debt,
        clock,
        quote_price_info_object,
    );
    let quote_usd_asset = calculate_usd_price<QuoteAsset>(
        registry,
        quote_asset,
        clock,
        quote_price_info_object,
    );

    let total_usd_asset = base_usd_asset + quote_usd_asset; // 9 decimals
    let total_usd_debt = base_usd_debt + quote_usd_debt; // 9 decimals

    let risk_ratio = risk_ratio<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        base_margin_pool,
        quote_margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );

    assert!(registry.can_liquidate<BaseAsset, QuoteAsset>(risk_ratio), ECannotLiquidate);

    let target_ratio = registry.target_liquidation_risk_ratio<BaseAsset, QuoteAsset>();

    // Now we check whether we have base or quote loan that needs to be covered. Only one of them can be net negative.
    // TODO: some edge cases here during defaults?
    let net_debt_is_base = base_debt > base_asset; // If true, we have to swap quote to base
    let net_debt_is_quote = quote_debt > quote_asset; // If true, we have to swap base to quote

    // Amount in USD (9 decimals) to repay to bring risk_ratio to target_ratio
    // amount_to_liquidate = (target_ratio × debt_value - asset) / (target_ratio - 1)
    let mut usd_amount_to_repay = math::div(
        (math::mul(total_usd_debt, target_ratio) - total_usd_asset),
        (target_ratio - constants::float_scaling()),
    );

    // We increase the amount to account for the liquidation reward
    usd_amount_to_repay =
        math::mul(
            usd_amount_to_repay,
            constants::float_scaling() +
        registry.user_liquidation_reward<BaseAsset, QuoteAsset>() +
        registry.pool_liquidation_reward<BaseAsset, QuoteAsset>(),
        );

    let base_same_asset_repay = base_asset.min(base_debt);
    let quote_same_asset_repay = quote_asset.min(quote_debt);

    let base_usd_repay = calculate_usd_price<BaseAsset>(
        registry,
        base_same_asset_repay,
        clock,
        base_price_info_object,
    );
    let quote_usd_repay = calculate_usd_price<QuoteAsset>(
        registry,
        quote_same_asset_repay,
        clock,
        quote_price_info_object,
    );

    // Simply repaying the loan using same assets will be enough to cover the liquidation.
    let same_asset_usd_repay = base_usd_repay + quote_usd_repay;
    if (same_asset_usd_repay < usd_amount_to_repay) {
        let remaining_usd_repay = usd_amount_to_repay - same_asset_usd_repay;

        let quote_amount_liquidate = if (net_debt_is_base) {
            calculate_target_amount<QuoteAsset>(
                registry,
                remaining_usd_repay,
                clock,
                quote_price_info_object,
            )
        } else {
            0
        };
        let base_amount_liquidate = if (net_debt_is_quote) {
            calculate_target_amount<BaseAsset>(
                registry,
                remaining_usd_repay,
                clock,
                base_price_info_object,
            )
        } else {
            0
        };

        let trade_proof = margin_manager
            .balance_manager
            .generate_proof_as_trader(&margin_manager.trade_cap, ctx);

        let balance_manager = margin_manager.balance_manager_mut();
        pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);
        pool.withdraw_settled_amounts(balance_manager, &trade_proof);

        if (base_amount_liquidate > 0) {
            let client_order_id = 0;
            let is_bid = false;
            let pay_with_deep = false; // We have to use input token as fee during liquidation, in case there is not enough DEEP in the balance manager.

            let (_, lot_size, _) = pool.pool_book_params<BaseAsset, QuoteAsset>();

            // We can only swap the lesser of the amount to liquidate and the manager balance, if there's a default scenario.
            let base_balance = balance_manager.balance<BaseAsset>();
            let base_amount_swap = base_balance.min(
                base_amount_liquidate,
            );
            let base_quantity = base_amount_swap - base_amount_swap % lot_size;

            pool.place_market_order(
                balance_manager,
                &trade_proof,
                client_order_id,
                constants::self_matching_allowed(),
                base_quantity,
                is_bid,
                pay_with_deep,
                clock,
                ctx,
            );
        };

        if (quote_amount_liquidate > 0) {
            let client_order_id = 0;
            let is_bid = true;
            let pay_with_deep = false; // We have to use input token as fee during liquidation, in case there is not enough DEEP in the balance manager.

            let quote_amount_swap = (balance_manager.balance<QuoteAsset>()).min(
                quote_amount_liquidate,
            );

            let (base_out, _, _) = pool.get_base_quantity_out_input_fee(
                quote_amount_swap,
                clock,
            );

            pool.place_market_order(
                balance_manager,
                &trade_proof,
                client_order_id,
                constants::self_matching_allowed(),
                base_out,
                is_bid,
                pay_with_deep,
                clock,
                ctx,
            );
        };
    };

    // We repay the same loans using the same assets. The amount repaid is returned
    let (base_repaid, quote_repaid) = margin_manager.repay_all_liquidation(
        base_margin_pool,
        quote_margin_pool,
        registry,
        clock,
        ctx,
    );

    // Emit a liquidation event for the liquidator
    event::emit(LiquidationEvent {
        margin_manager_id: margin_manager.id(),
        base_amount: base_repaid,
        quote_amount: quote_repaid,
        liquidator: ctx.sender(),
    });

    // After repayment, the manager should be close to the target risk ratio.
    // We withdraw the liquidation reward for the pool.

    let pool_liquidation_reward = registry.pool_liquidation_reward<BaseAsset, QuoteAsset>();
    let pool_liquidation_reward_base = math::mul(pool_liquidation_reward, base_repaid);
    let pool_base_coin = margin_manager.liquidation_withdraw_base(
        pool_liquidation_reward_base,
        ctx,
    );
    let pool_liquidation_reward_quote = math::mul(pool_liquidation_reward, quote_repaid);
    let pool_quote_coin = margin_manager.liquidation_withdraw_quote(
        pool_liquidation_reward_quote,
        ctx,
    );

    base_margin_pool.add_liquidation_reward<BaseAsset>(pool_base_coin, clock);
    quote_margin_pool.add_liquidation_reward<QuoteAsset>(pool_quote_coin, clock);

    // We can withdraw the liquidation reward for the user.
    // Liquidation reward is a percentage of the amount repaid.
    let user_liquidation_reward = registry.user_liquidation_reward<BaseAsset, QuoteAsset>();
    let user_liquidation_reward_base = math::mul(user_liquidation_reward, base_repaid);
    let user_base_coin = margin_manager.liquidation_withdraw_base(
        user_liquidation_reward_base,
        ctx,
    );
    let user_liquidation_reward_quote = math::mul(user_liquidation_reward, quote_repaid);
    let user_quote_coin = margin_manager.liquidation_withdraw_quote(
        user_liquidation_reward_quote,
        ctx,
    );

    let in_default = risk_ratio < constants::float_scaling();
    if (in_default) {
        // If the manager is in default, we call the default endpoint
        base_margin_pool.default_loan(margin_manager.id(), clock);
        quote_margin_pool.default_loan(margin_manager.id(), clock);
    };

    (user_base_coin, user_quote_coin)
}

/// Unwraps balance manager for trading in deepbook.
public fun balance_manager_trading_mut<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
): &mut BalanceManager {
    assert!(margin_manager.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &mut margin_manager.balance_manager
}

/// Unwraps TradeCap reference for trading in deepbook.
public fun trade_cap<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
): &TradeCap {
    assert!(margin_manager.owner == ctx.sender(), EInvalidMarginManagerOwner);

    &margin_manager.trade_cap
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

public(package) fun id<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): ID {
    object::id(margin_manager)
}

// === Private Functions ===
fun borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BorrowAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let manager_id = margin_manager.id();
    let coin = margin_pool.borrow(manager_id, loan_amount, clock, ctx);

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
    margin_pool.update_state(clock);
    let manager_id = margin_manager.id();

    margin_pool.update_user_loan(manager_id);
    let user_loan = margin_pool.user_loan(manager_id);

    let repay_amount = repay_amount.get_with_default(user_loan);
    let available_balance = margin_manager.balance_manager().balance<RepayAsset>();

    // if user tries to repay more than owed, just repay the loan amount
    let repayment = if (repay_amount >= user_loan) {
        user_loan
    } else {
        repay_amount
    };

    // if user tries to repay more than available balance, just repay the available balance
    let repayment = if (repayment >= available_balance) {
        available_balance
    } else {
        repayment
    };

    // Owner check is skipped if this is liquidation
    let coin = margin_manager.repay_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repayment,
        ctx,
    );

    let repay_amount = coin.value();

    margin_pool.repay(
        manager_id,
        coin,
        clock,
    );

    repay_amount
}

/// Repays the loan using the margin manager.
/// Returns the total amount repaid
/// This is used for liquidation, where the repay amount is not specified.
fun repay_liquidation<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    registry: &MarginRegistry,
    repay_amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_pool.update_state(clock);
    let manager_id = margin_manager.id();

    margin_pool.update_user_loan(manager_id);
    let user_loan = margin_pool.user_loan(manager_id);

    let repay_amount = repay_amount.get_with_default(user_loan);
    let manager_asset = margin_manager.balance_manager().balance<RepayAsset>();
    let liquidation_multiplier =
        constants::float_scaling() + registry.user_liquidation_reward<BaseAsset, QuoteAsset>() + registry.pool_liquidation_reward<BaseAsset, QuoteAsset>();
    let available_balance_for_repayment = math::div(
        manager_asset,
        liquidation_multiplier,
    );

    // if user tries to repay more than owed, just repay the loan amount
    let repayment = if (repay_amount >= user_loan) {
        user_loan
    } else {
        repay_amount
    };

    // if user tries to repay more than available balance, just repay the available balance
    let repayment = if (repayment >= available_balance_for_repayment) {
        available_balance_for_repayment
    } else {
        repayment
    };

    // Owner check is skipped if this is liquidation
    let coin = margin_manager.liquidation_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repayment,
        ctx,
    );

    let repay_amount = coin.value();

    margin_pool.repay(
        manager_id,
        coin,
        clock,
    );

    repay_amount
}

/// Returns the (base_debt, quote_debt) for the margin manager
fun margin_manager_debt<BaseAsset, QuoteAsset>(
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    clock: &Clock,
): (u64, u64) {
    let base_debt = margin_manager.manager_debt(base_margin_pool, clock);
    let quote_debt = margin_manager.manager_debt(quote_margin_pool, clock);

    (base_debt, quote_debt)
}

fun manager_debt<BaseAsset, QuoteAsset, Asset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<Asset>,
    clock: &Clock,
): u64 {
    margin_pool.update_state(clock);
    margin_pool.update_user_loan(margin_manager.id());

    margin_pool.user_loan(margin_manager.id())
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
    let balance_manager = &mut margin_manager.balance_manager;

    let coin = balance_manager.withdraw<WithdrawAsset>(
        withdraw_amount,
        ctx,
    );

    coin
}

/// Returns (base_asset, quote_asset) for margin manager.
fun margin_manager_asset<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = margin_manager.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

/// Repay all for the balance manager.
/// Returns (base_repaid, quote_repaid)
fun repay_all_liquidation<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    margin_registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    let base_repaid = repay_base_liquidate(
        margin_manager,
        base_margin_pool,
        margin_registry,
        clock,
        ctx,
    );
    let quote_repaid = repay_quote_liquidate(
        margin_manager,
        quote_margin_pool,
        margin_registry,
        clock,
        ctx,
    );

    (base_repaid, quote_repaid)
}

/// Repay the base asset loan using the margin manager.
/// Returns the total amount repaid
fun repay_base_liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BaseAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.repay_liquidation<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        registry,
        option::none(),
        clock,
        ctx,
    )
}

/// Repay the quote asset loan using the margin manager.
/// Returns the total amount repaid
fun repay_quote_liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    registry: &MarginRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.repay_liquidation<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        registry,
        option::none(),
        clock,
        ctx,
    )
}
