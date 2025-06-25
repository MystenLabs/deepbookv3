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
    order_info::OrderInfo,
    pool::Pool
};
use margin_trading::{
    lending_pool::{LendingPool, new_loan},
    margin_math,
    margin_registry::{Self, MarginRegistry},
    oracle::calculate_usd_price
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
const ELiquidationCheckBeforeRequest: u64 = 8;
const ECannotLiquidate: u64 = 9;

// === Constants ===
const WITHDRAW: u8 = 0;
const BORROW: u8 = 1;
const LIQUIDATE: u8 = 2;

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

/// Request_type: 0 for withdraw, 1 for borrow, 2 for liquidate
public struct Request {
    margin_manager_id: ID,
    request_type: u8,
}

public struct LiquidationProof {
    margin_manager_id: ID,
    amount: u64,
}

// === Public Functions - Margin Manager ===
public fun new<BaseAsset, QuoteAsset>(margin_registry: &MarginRegistry, ctx: &mut TxContext) {
    assert!(
        margin_registry::is_margin_pair_allowed<BaseAsset, QuoteAsset>(margin_registry),
        EMarginPairNotAllowed,
    );

    let id = object::new(ctx);

    let mut balance_manager = balance_manager::new(ctx);
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

/// TODO: this is a WIP
/// amount_to_liquidate = (asset_value - target_ratio × debt_value) / (target_ratio - 1)
public fun liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    margin_manager.cancel_all_orders(pool, clock, ctx);
    margin_manager.withdraw_settled_amounts(pool, ctx);
    // TODO: Check the risk ratio to determine if liquidation is allowed

    let balance_manager = &mut margin_manager.balance_manager;
    let trade_proof = balance_manager.generate_proof_as_trader(
        &margin_manager.trade_cap,
        ctx,
    );

    let quote_amount_to_liquidate = 100_000_000; // 100 USDC, TODO: replace with actual logic
    let client_order_id = 0; // TODO: Should this be customizable?
    let is_bid = true; // TODO: Should this be customizable?
    let pay_with_deep = false; // TODO: Should this be customizable?
    // We have to use input token as fee during, in case there is not enough DEEP in the balance manager.
    // Alternatively, we can utilize DEEP flash loan.
    let (base_out, _, _) = pool.get_base_quantity_out_input_fee(
        quote_amount_to_liquidate,
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
}

/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &mut TxContext,
) {
    let deposit_asset_type = type_name::get<DepositAsset>();
    let base_asset_type = type_name::get<BaseAsset>();
    let quote_asset_type = type_name::get<QuoteAsset>();
    let deep_asset_type = type_name::get<DEEP>();
    assert!(
        deposit_asset_type == base_asset_type || deposit_asset_type == quote_asset_type || deposit_asset_type == deep_asset_type,
        EInvalidDeposit,
    );

    let balance_manager = &mut margin_manager.balance_manager;

    balance_manager.deposit<DepositAsset>(coin, ctx);
}

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit. This is restricted through the WithdrawalRequest.
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): (Coin<WithdrawAsset>, Request) {
    let balance_manager = &mut margin_manager.balance_manager;

    let coin = balance_manager.withdraw<WithdrawAsset>(
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
    lending_pool: &mut LendingPool<BaseAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    lending_pool.update_indices<BaseAsset>(clock);

    margin_manager.borrow<BaseAsset, QuoteAsset, BaseAsset>(lending_pool, loan_amount, ctx)
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    lending_pool: &mut LendingPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    lending_pool.update_indices<QuoteAsset>(clock);

    margin_manager.borrow<BaseAsset, QuoteAsset, QuoteAsset>(lending_pool, loan_amount, ctx)
}

/// Repay the base asset loan using the margin manager.
public fun repay_base<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<BaseAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
) {
    lending_pool.update_indices<BaseAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, BaseAsset>(lending_pool, repay_amount, ctx);
}

/// Repay the quote asset loan using the margin manager.
public fun repay_quote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    lending_pool: &mut LendingPool<QuoteAsset>,
    repay_amount: Option<u64>, // if None, repay all
    clock: &Clock,
    ctx: &mut TxContext,
) {
    lending_pool.update_indices<QuoteAsset>(clock);
    margin_manager.repay<BaseAsset, QuoteAsset, QuoteAsset>(lending_pool, repay_amount, ctx);
}

/// Destroys the request to borrow or withdraw if risk ratio conditions are met.
/// This function is called after the borrow or withdraw request is created.
/// TODO: liquidation check to be added for target risk_ratio
public fun risk_ratio_proof<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    request: Request,
) {
    assert!(request.margin_manager_id == margin_manager.id(), EInvalidMarginManager);
    assert!(request.request_type != LIQUIDATE, ELiquidationCheckBeforeRequest);

    let risk_ratio = risk_ratio<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        base_lending_pool,
        quote_lending_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    if (request.request_type == BORROW) {
        assert!(registry.can_borrow(risk_ratio), EBorrowRiskRatioExceeded);
    } else if (request.request_type == WITHDRAW) {
        assert!(registry.can_withdraw(risk_ratio), EWithdrawRiskRatioExceeded);
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
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): u64 {
    let (base_debt, quote_debt) = margin_manager_debt<BaseAsset, QuoteAsset>(
        base_lending_pool,
        quote_lending_pool,
        margin_manager,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager_asset<BaseAsset, QuoteAsset>(
        pool,
        margin_manager,
    );

    let (base_usd_debt, base_usd_asset) = calculate_usd_price<BaseAsset>(
        registry,
        base_debt,
        base_asset,
        clock,
        base_price_info_object,
    );
    let (quote_usd_debt, quote_usd_asset) = calculate_usd_price<QuoteAsset>(
        registry,
        quote_debt,
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

/// Returns LiquidationProof for the margin manager?
/// TODO: This is a WIP
public fun liquidation_prep<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): (LiquidationProof, u64, u64) {
    let (base_debt, quote_debt) = margin_manager_debt<BaseAsset, QuoteAsset>(
        base_lending_pool,
        quote_lending_pool,
        margin_manager,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager_asset<BaseAsset, QuoteAsset>(
        pool,
        margin_manager,
    );

    let (base_usd_debt, base_usd_asset) = calculate_usd_price<BaseAsset>(
        registry,
        base_debt,
        base_asset,
        clock,
        base_price_info_object,
    );
    let (quote_usd_debt, quote_usd_asset) = calculate_usd_price<QuoteAsset>(
        registry,
        quote_debt,
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

    assert!(registry.can_liquidate(risk_ratio), ECannotLiquidate);
    // let target_ratio = registry.target_liquidation_risk_ratio();

    // Amount in USD (9 decimals) to liquidate to bring risk_ratio to target_ratio
    // let amount_to_liquidate = margin_math::div(
    //     (total_usd_asset - margin_math::mul(total_usd_debt, target_ratio)),
    //     (target_ratio - constants::float_scaling()),
    // );

    let proof = LiquidationProof {
        margin_manager_id: margin_manager.id(),
        amount: 0,
    };

    // amount_to_liquidate = (asset_value - target_ratio × debt_value) / (target_ratio - 1)

    (proof, total_usd_asset, total_usd_debt)
}

// === Public Proxy Functions - Trading ===
/// Places a limit order in the pool.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
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
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

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
public fun place_market_order<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

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

/// Modifies an order
public fun modify_order<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
    new_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.modify_order(
        balance_manager,
        &trade_proof,
        order_id,
        new_quantity,
        clock,
        ctx,
    )
}

/// Cancels an order
public fun cancel_order<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
    clock: &Clock,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.cancel_order(
        balance_manager,
        &trade_proof,
        order_id,
        clock,
        ctx,
    );
}

/// Cancel multiple orders within a vector.
public fun cancel_orders<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.cancel_orders(
        balance_manager,
        &trade_proof,
        order_ids,
        clock,
        ctx,
    );
}

/// Cancels all orders for the given account.
public fun cancel_all_orders<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.cancel_all_orders(
        balance_manager,
        &trade_proof,
        clock,
        ctx,
    );
}

/// Withdraw settled amounts to balance_manager.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.withdraw_settled_amounts(
        balance_manager,
        &trade_proof,
    );
}

/// Stake DEEP tokens to the pool.
public fun stake<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    amount: u64,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.stake(
        balance_manager,
        &trade_proof,
        amount,
        ctx,
    );
}

/// Unstake DEEP tokens from the pool.
public fun unstake<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.unstake(
        balance_manager,
        &trade_proof,
        ctx,
    );
}

/// Submit proposal using the margin manager.
public fun submit_proposal<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.submit_proposal(
        balance_manager,
        &trade_proof,
        taker_fee,
        maker_fee,
        stake_required,
        ctx,
    );
}

/// Vote on a proposal using the margin manager.
public fun vote<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    proposal_id: ID,
    ctx: &TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.vote(
        balance_manager,
        &trade_proof,
        proposal_id,
        ctx,
    );
}

public fun claim_rebates<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
) {
    let balance_manager = margin_manager.balance_manager_mut();
    let trade_proof = balance_manager.generate_proof_as_owner(ctx);

    pool.claim_rebates(balance_manager, &trade_proof, ctx)
}

// === Public-Package Functions ===
public(package) fun liquidation_deposit<BaseAsset, QuoteAsset, DepositAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    coin: Coin<DepositAsset>,
    ctx: &TxContext,
) {
    let balance_manager = &mut margin_manager.balance_manager;

    balance_manager.deposit_with_cap<DepositAsset>(&margin_manager.deposit_cap, coin, ctx);
}

public(package) fun liquidation_withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
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
    lending_pool: &mut LendingPool<Asset>,
    clock: &Clock,
): u64 {
    lending_pool.update_indices<Asset>(clock);
    if (lending_pool.loans().contains(margin_manager.id())) {
        margin_manager.update_loan_interest<BaseAsset, QuoteAsset, Asset>(lending_pool);

        lending_pool.loans().borrow(margin_manager.id()).loan_amount()
    } else {
        0 // no loan found for this margin manager
    }
}

/// Updates the loan interest for the margin manager if it has an active loan in the lending pool.
fun update_loan_interest<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    lending_pool: &mut LendingPool<RepayAsset>,
) {
    let manager_id = margin_manager.id();
    let lending_pool_total_loan = lending_pool.total_loan();
    let mut loan = lending_pool.loans().remove(manager_id);
    let interest_multiplier = margin_math::div(
        lending_pool.borrow_index(),
        loan.last_borrow_index(),
    );
    let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
    let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
    loan.set_loan_amount(new_loan_amount);
    loan.set_last_borrow_index(lending_pool.borrow_index());

    lending_pool.set_total_loan(lending_pool_total_loan + interest);
    lending_pool.loans().add(manager_id, loan);
}

fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    lending_pool: &mut LendingPool<RepayAsset>,
    repay_amount: Option<u64>,
    ctx: &mut TxContext,
) {
    let manager_id = margin_manager.id();
    if (lending_pool.loans().contains(manager_id)) {
        let mut loan = lending_pool.loans().remove(manager_id);
        let lending_pool_total_loan = lending_pool.total_loan();
        let interest_multiplier = margin_math::div(
            lending_pool.borrow_index(),
            loan.last_borrow_index(),
        );
        let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
        let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
        loan.set_loan_amount(new_loan_amount);
        loan.set_last_borrow_index(lending_pool.borrow_index());

        let repay_amount = repay_amount.get_with_default(loan.loan_amount());

        // if user tries to repay more than owed, just repay the full amount
        let repayment = if (repay_amount >= loan.loan_amount()) {
            loan.loan_amount()
        } else {
            repay_amount
        };
        lending_pool.set_total_loan(lending_pool_total_loan + interest - repayment);

        let coin = margin_manager.repay_withdrawal<BaseAsset, QuoteAsset, RepayAsset>(
            repayment,
            ctx,
        );
        let balance = coin.into_balance();
        lending_pool.vault().join(balance);
        let loan_amount = loan.loan_amount();

        loan.set_loan_amount(loan_amount - repayment);
        if (loan.loan_amount() > 0) {
            lending_pool.loans().add(manager_id, loan);
        };
    }
}

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
    lending_pool: &mut LendingPool<BorrowAsset>,
    loan_amount: u64,
    ctx: &mut TxContext,
): Request {
    assert!(loan_amount > 0, EInvalidLoanQuantity);
    assert!(lending_pool.vault().value() >= loan_amount, ENotEnoughAssetInPool);
    let manager_id = margin_manager.id();
    let lending_pool_total_loan = lending_pool.total_loan();
    if (lending_pool.loans().contains(manager_id)) {
        let mut loan = lending_pool.loans().remove(manager_id);
        let interest_multiplier = margin_math::div(
            lending_pool.borrow_index(),
            loan.last_borrow_index(),
        );
        let new_loan_amount = margin_math::mul(loan.loan_amount(), interest_multiplier); // previous loan with interest
        let interest = new_loan_amount - loan.loan_amount(); // TODO: event for interest accured?
        loan.set_loan_amount(new_loan_amount + loan_amount); // previous loan with interest and new loan
        loan.set_last_borrow_index(lending_pool.borrow_index());

        lending_pool.set_total_loan(lending_pool_total_loan + interest + loan_amount);
        lending_pool.loans().add(manager_id, loan);
    } else {
        let loan = new_loan(loan_amount, lending_pool.borrow_index());
        lending_pool.loans().add(manager_id, loan);
        lending_pool.set_total_loan(lending_pool_total_loan + loan_amount);
    };

    let borrow_percentage = margin_math::div(
        lending_pool.total_loan(),
        lending_pool.total_supply(),
    );
    assert!(
        borrow_percentage <= lending_pool.max_borrow_percentage(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let deposit = lending_pool.vault().split(loan_amount).into_coin(ctx);
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
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    clock: &Clock,
): (u64, u64) {
    let base_debt = margin_manager.manager_debt(base_lending_pool, clock);
    let quote_debt = margin_manager.manager_debt(quote_lending_pool, clock);

    (base_debt, quote_debt)
}
