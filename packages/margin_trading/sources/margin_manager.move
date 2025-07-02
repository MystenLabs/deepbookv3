// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// TODO: update comments
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
    pool::Pool
};
use margin_trading::{
    margin_math,
    margin_pool::{MarginPool, new_loan},
    margin_registry::{Self, MarginRegistry},
    oracle::{calculate_usd_price, calculate_target_amount}
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::Coin, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginPairNotAllowed: u64 = 1;
const EMaxPoolBorrowPercentageExceeded: u64 = 2;
const EInvalidLoanQuantity: u64 = 3;
const EInvalidMarginManager: u64 = 4;
const EBorrowRiskRatioExceeded: u64 = 5;
const EWithdrawRiskRatioExceeded: u64 = 6;
const ENotEnoughAssetInPool: u64 = 7;
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
    assert!(
        margin_registry::margin_pair_allowed<BaseAsset, QuoteAsset>(margin_registry),
        EMarginPairNotAllowed,
    );

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
    margin_pool.update_indices<BaseAsset>(clock);

    margin_manager.borrow<BaseAsset, QuoteAsset, BaseAsset>(margin_pool, loan_amount, ctx)
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    margin_pool.update_indices<QuoteAsset>(clock);

    margin_manager.borrow<BaseAsset, QuoteAsset, QuoteAsset>(margin_pool, loan_amount, ctx)
}

/// Repay the base asset loan using the margin manager.
public fun repay_base<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BaseAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
) {
    margin_pool.update_indices<BaseAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, BaseAsset>(margin_pool, repay_amount, false, ctx);
}

/// Repay the quote asset loan using the margin manager.
public fun repay_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
) {
    margin_pool.update_indices<QuoteAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, QuoteAsset>(margin_pool, repay_amount, false, ctx);
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
        margin_math::div(total_usd_asset, total_usd_debt) // 9 decimals
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
) {
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

    let risk_ratio = if (total_usd_debt == 0 || total_usd_asset > 1000 * total_usd_debt) {
        1000 * constants::float_scaling() // 9 decimals, risk ratio above 1000 will be considered as 1000
    } else {
        margin_math::div(total_usd_asset, total_usd_debt) // 9 decimals
    };

    assert!(registry.can_liquidate<BaseAsset, QuoteAsset>(risk_ratio), ECannotLiquidate);

    let target_ratio = registry.target_liquidation_risk_ratio<BaseAsset, QuoteAsset>();

    // Now we check whether we have base or quote loan that needs to be covered. Only one of them can be net negative.
    // TODO: some edge cases here?
    let net_debt_is_base = base_debt > base_asset; // If true, we have to swap quote to base
    let net_debt_is_quote = quote_debt > quote_asset; // If true, we have to swap base to quote

    // Amount in USD (9 decimals) to repay to bring risk_ratio to target_ratio
    // amount_to_liquidate = (target_ratio × debt_value - asset) / (target_ratio - 1)
    let usd_amount_to_repay = margin_math::div(
        (margin_math::mul(total_usd_debt, target_ratio) - total_usd_asset),
        (target_ratio - constants::float_scaling()),
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
            let pay_with_deep = false; // TODO: Should this be customizable? No guarantee to be DEEP in manager however
            // We have to use input token as fee during, in case there is not enough DEEP in the balance manager.
            // Alternatively, we can utilize DEEP flash loan.

            let (_, lot_size, _) = pool.pool_book_params<BaseAsset, QuoteAsset>();
            let base_quantity = base_amount_liquidate - base_amount_liquidate % lot_size;

            pool.place_market_order(
                margin_manager.balance_manager_mut(),
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
            let pay_with_deep = false; // TODO: Should this be customizable? No guarantee to be DEEP in manager however
            // We have to use input token as fee during, in case there is not enough DEEP in the balance manager.
            // Alternatively, we can utilize DEEP flash loan.
            let (base_out, _, _) = pool.get_base_quantity_out_input_fee(
                quote_amount_liquidate,
                clock,
            );

            pool.place_market_order(
                margin_manager.balance_manager_mut(),
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

        event::emit(LiquidationEvent {
            margin_manager_id: margin_manager.id(),
            base_amount: base_amount_liquidate,
            quote_amount: quote_amount_liquidate,
            liquidator: ctx.sender(),
        });
    } else {
        event::emit(LiquidationEvent {
            margin_manager_id: margin_manager.id(),
            base_amount: 0,
            quote_amount: 0,
            liquidator: ctx.sender(),
        });
    };

    // We repay the same loans using the same assets.
    margin_manager.repay_all_liquidation(base_margin_pool, quote_margin_pool, clock, ctx);
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
fun manager_debt<BaseAsset, QuoteAsset, Asset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<Asset>,
    clock: &Clock,
): u64 {
    margin_pool.update_indices<Asset>(clock);
    if (margin_pool.loans().contains(margin_manager.id())) {
        margin_manager.update_loan_interest<BaseAsset, QuoteAsset, Asset>(margin_pool);

        margin_pool.loans().borrow(margin_manager.id()).loan_amount()
    } else {
        0 // no loan found for this margin manager
    }
}

/// Updates the loan interest for the margin manager if it has an active loan in the margin pool.
fun update_loan_interest<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
) {
    let manager_id = margin_manager.id();
    let margin_pool_total_loan = margin_pool.total_loan();
    let mut loan = margin_pool.loans().remove(manager_id);
    let interest_multiplier = margin_math::div(
        margin_pool.borrow_index(),
        loan.last_borrow_index(),
    );
    let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
    let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
    loan.set_loan_amount(new_loan_amount);
    loan.set_last_borrow_index(margin_pool.borrow_index());

    margin_pool.set_total_loan(margin_pool_total_loan + interest);
    margin_pool.loans().add(manager_id, loan);
}

fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<RepayAsset>,
    repay_amount: Option<u64>,
    is_liquidation: bool,
    ctx: &mut TxContext,
) {
    let manager_id = margin_manager.id();
    if (margin_pool.loans().contains(manager_id)) {
        let mut loan = margin_pool.loans().remove(manager_id);
        let margin_pool_total_loan = margin_pool.total_loan();
        let interest_multiplier = margin_math::div(
            margin_pool.borrow_index(),
            loan.last_borrow_index(),
        );
        let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
        let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
        loan.set_loan_amount(new_loan_amount);
        loan.set_last_borrow_index(margin_pool.borrow_index());

        let repay_amount = repay_amount.get_with_default(loan.loan_amount());
        let available_balance = margin_manager.balance_manager().balance<RepayAsset>();

        // if user tries to repay more than owed, just repay the loan amount
        let repayment = if (repay_amount >= loan.loan_amount()) {
            loan.loan_amount()
        } else {
            repay_amount
        };

        // if user tries to repay more than available balance, just repay the available balance
        let repayment = if (repayment > available_balance) {
            available_balance
        } else {
            repayment
        };

        margin_pool.set_total_loan(margin_pool_total_loan + interest - repayment);

        // Owner check is skipped if this is liquidation
        let coin = if (is_liquidation) {
            margin_manager.liquidation_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
                repayment,
                ctx,
            )
        } else {
            margin_manager.repay_withdrawal<BaseAsset, QuoteAsset, RepayAsset>(
                repayment,
                ctx,
            )
        };

        let balance = coin.into_balance();
        margin_pool.vault().join(balance);
        let loan_amount = loan.loan_amount();

        loan.set_loan_amount(loan_amount - repayment);
        if (loan.loan_amount() > 0) {
            margin_pool.loans().add(manager_id, loan);
        };
    }
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
fun repay_withdrawal<BaseAsset, QuoteAsset, WithdrawAsset>(
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

fun borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BorrowAsset>,
    loan_amount: u64,
    ctx: &mut TxContext,
): Request {
    assert!(loan_amount > 0, EInvalidLoanQuantity);
    assert!(margin_pool.vault().value() >= loan_amount, ENotEnoughAssetInPool);
    let manager_id = margin_manager.id();
    let margin_pool_total_loan = margin_pool.total_loan();
    if (margin_pool.loans().contains(manager_id)) {
        let mut loan = margin_pool.loans().remove(manager_id);
        let interest_multiplier = margin_math::div(
            margin_pool.borrow_index(),
            loan.last_borrow_index(),
        );
        let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
        let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
        loan.set_loan_amount(new_loan_amount + loan_amount); // previous loan with interest and new loan
        loan.set_last_borrow_index(margin_pool.borrow_index());

        margin_pool.set_total_loan(margin_pool_total_loan + interest + loan_amount);
        margin_pool.loans().add(manager_id, loan);
    } else {
        let loan = new_loan(loan_amount, margin_pool.borrow_index());
        margin_pool.loans().add(manager_id, loan);
        margin_pool.set_total_loan(margin_pool_total_loan + loan_amount);
    };

    let borrow_percentage = margin_math::div(
        margin_pool.total_loan(),
        margin_pool.total_supply(),
    );
    assert!(
        borrow_percentage <= margin_pool.max_borrow_percentage(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let deposit = margin_pool.vault().split(loan_amount).into_coin(ctx);
    margin_manager.deposit<BaseAsset, QuoteAsset, BorrowAsset>(deposit, ctx);

    Request {
        margin_manager_id: manager_id,
        request_type: BORROW,
    }
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

// Returns the (base_debt, quote_debt) for the margin manager
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

fun repay_all_liquidation<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    repay_base_liquidate(margin_manager, base_margin_pool, clock, ctx);
    repay_quote_liquidate(margin_manager, quote_margin_pool, clock, ctx);
}

fun repay_base_liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<BaseAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    margin_pool.update_indices<BaseAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, BaseAsset>(margin_pool, option::none(), true, ctx);
}

/// Repay the quote asset loan using the margin manager.
fun repay_quote_liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<QuoteAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    margin_pool.update_indices<QuoteAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        option::none(),
        true,
        ctx,
    );
}
