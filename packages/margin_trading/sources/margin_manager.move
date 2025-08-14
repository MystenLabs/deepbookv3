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
    margin_constants,
    margin_pool::{MarginPool, create_repayment_proof, RepaymentProof},
    margin_registry::MarginRegistry,
    oracle::{calculate_usd_price, calculate_target_amount, calculate_pair_usd_price}
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::{Self, Coin}, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginTradingNotAllowedInPool: u64 = 1;
const EInvalidMarginManager: u64 = 2;
const EBorrowRiskRatioExceeded: u64 = 3;
const EWithdrawRiskRatioExceeded: u64 = 4;
const ECannotLiquidate: u64 = 5;
const EInvalidMarginManagerOwner: u64 = 6;
const ECannotHaveLoanInBothMarginPools: u64 = 7;
const EIncorrectDeepBookPool: u64 = 8;

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

/// Event emitted when a new margin_manager is created.
public struct LiquidationEvent has copy, drop {
    margin_manager_id: ID,
    base_amount: u64,
    quote_amount: u64,
    liquidator: address,
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
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(
        quote_margin_pool.user_loan_amount(margin_manager.id(), clock) == 0,
        ECannotHaveLoanInBothMarginPools,
    );
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
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(
        base_margin_pool.user_loan_amount(margin_manager.id(), clock) == 0,
        ECannotHaveLoanInBothMarginPools,
    );
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

/// Destroys the request to borrow or withdraw if risk ratio conditions are met.
/// This function is called after the borrow or withdraw request is created.
public fun prove_and_destroy_request<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    request: Request,
) {
    assert!(request.margin_manager_id == margin_manager.id(), EInvalidMarginManager);
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    let risk_ratio = margin_manager
        .manager_info<BaseAsset, QuoteAsset>(
            registry,
            base_margin_pool,
            quote_margin_pool,
            pool,
            base_price_info_object,
            quote_price_info_object,
            clock,
        )
        .risk_ratio;
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
public fun manager_info<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): ManagerInfo {
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    let (base_debt, quote_debt) = margin_manager.total_debt<BaseAsset, QuoteAsset>(
        base_margin_pool,
        quote_margin_pool,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager.total_assets<BaseAsset, QuoteAsset>(
        pool,
    );

    let (base_usd_asset, base_usd_debt) = calculate_pair_usd_price<BaseAsset>(
        base_price_info_object,
        registry,
        base_asset,
        base_debt,
        clock,
    );
    let (quote_usd_asset, quote_usd_debt) = calculate_pair_usd_price<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_asset,
        quote_debt,
        clock,
    );

    let total_usd_debt = base_usd_debt + quote_usd_debt; // 6 decimals
    let total_usd_asset = base_usd_asset + quote_usd_asset; // 6 decimals
    let max_risk_ratio = margin_constants::max_risk_ratio(); // 9 decimals

    let risk_ratio = if (
        total_usd_debt == 0 || total_usd_asset > math::mul(total_usd_debt, max_risk_ratio)
    ) {
        max_risk_ratio
    } else {
        math::div(total_usd_asset, total_usd_debt) // 9 decimals
    };

    ManagerInfo {
        base: AssetInfo {
            asset: base_asset,
            debt: base_debt,
            usd_asset: base_usd_asset,
            usd_debt: base_usd_debt,
        },
        quote: AssetInfo {
            asset: quote_asset,
            debt: quote_debt,
            usd_asset: quote_usd_asset,
            usd_debt: quote_usd_debt,
        },
        risk_ratio,
    }
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
public fun liquidate_custom<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (
    Coin<BaseAsset>,
    Coin<QuoteAsset>,
    Option<RepaymentProof<BaseAsset>>,
    Option<RepaymentProof<QuoteAsset>>,
) {
    assert!(margin_manager.deepbook_pool == pool.id(), EIncorrectDeepBookPool);

    // Step 1: We retrieve the manager info and check if liquidation is possible.
    let manager_info = margin_manager.manager_info<BaseAsset, QuoteAsset>(
        registry,
        base_margin_pool,
        quote_margin_pool,
        pool,
        base_price_info_object,
        quote_price_info_object,
        clock,
    );
    let pool_id = pool.id();

    assert!(registry.can_liquidate(pool_id, manager_info.risk_ratio), ECannotLiquidate);

    // Step 2: We calculate how much needs to be sold (if any), and repaid.
    let margin_manager_id = margin_manager.id();
    let total_usd_debt = manager_info.base.usd_debt + manager_info.quote.usd_debt;
    let total_usd_asset = manager_info.base.usd_asset + manager_info.quote.usd_asset;
    let target_ratio = registry.target_liquidation_risk_ratio(pool_id);
    let user_liquidation_reward = registry.user_liquidation_reward(pool_id);
    let pool_liquidation_reward = registry.pool_liquidation_reward(pool_id);
    let total_liquidation_reward = user_liquidation_reward + pool_liquidation_reward;
    let liquidation_multiplier = constants::float_scaling() + total_liquidation_reward;
    let in_default = in_default(manager_info.risk_ratio);

    // Now we check whether we have base or quote loan that needs to be covered.
    // Scenario 1: debt is in base asset.
    // Scenario 2: debt is in quote asset.
    let debt_is_base = manager_info.base.debt > 0; // If true, we have to swap quote to base. Otherwise, we swap base to quote.

    // Amount in USD (9 decimals) to repay to bring risk_ratio to target_ratio
    // amount_to_repay = (target_ratio × debt_value - asset) / (target_ratio - (1 + total_liquidation_reward)))
    let usd_amount_to_repay = math::div(
        (math::mul(total_usd_debt, target_ratio) - total_usd_asset),
        (target_ratio - (constants::float_scaling() + total_liquidation_reward)),
    );

    // Step 3: We cancel all orders and withdraw settled amounts from the pool.
    let trade_proof = margin_manager.trade_proof(ctx);

    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);
    pool.withdraw_settled_amounts(balance_manager, &trade_proof);

    let mut max_base_repay = 0;
    let mut max_quote_repay = 0;

    // Step 4: We calculate how much we can already repay.
    // Just repaying using existing assets without swaps could help bring the risk ratio to the target.
    let (base_repaid, base_left_to_repay) = if (debt_is_base) {
        max_base_repay =
            math::mul(
                manager_info.base.debt,
                math::div(usd_amount_to_repay, total_usd_debt),
            );
        let base_asset = balance_manager.balance<BaseAsset>();
        let available_balance_for_repayment = math::div(
            base_asset,
            liquidation_multiplier,
        );
        if (max_base_repay >= available_balance_for_repayment) {
            (available_balance_for_repayment, true)
        } else {
            (max_base_repay, false)
        }
    } else {
        (0, false)
    };

    let (quote_repaid, quote_left_to_repay) = if (!debt_is_base) {
        max_quote_repay =
            math::mul(
                manager_info.quote.debt,
                math::div(usd_amount_to_repay, total_usd_debt),
            );
        let quote_asset = balance_manager.balance<QuoteAsset>();
        let available_balance_for_repayment = math::div(
            quote_asset,
            liquidation_multiplier,
        );
        if (max_quote_repay >= available_balance_for_repayment) {
            (available_balance_for_repayment, true)
        } else {
            (max_quote_repay, false)
        }
    } else {
        (0, false)
    };

    // Step 5: We calculate how much to give the liquidator to swap, and then repay.
    if (base_left_to_repay || quote_left_to_repay) {
        let liquidation_reward_multiplier = constants::float_scaling() + total_liquidation_reward;

        if (debt_is_base) {
            let base_repaid_usd = calculate_usd_price<BaseAsset>(
                base_price_info_object,
                registry,
                base_repaid,
                clock,
            );
            let remaining_usd_repay = usd_amount_to_repay - base_repaid_usd;

            let quote_equivalent = calculate_target_amount<QuoteAsset>(
                quote_price_info_object,
                registry,
                remaining_usd_repay,
                clock,
            );
            let quote_with_rewards = math::mul(quote_equivalent, liquidation_reward_multiplier);

            let quote_amount_returned = quote_with_rewards.min(balance_manager.balance<
                QuoteAsset,
            >());

            let base_loan_to_be_repaid = math::mul(
                max_base_repay - base_repaid,
                math::div(quote_amount_returned, quote_with_rewards),
            );
            let total_repayment = base_loan_to_be_repaid + base_repaid;

            let repayment_proof_base = option::some(
                create_repayment_proof<BaseAsset>(
                    margin_manager_id,
                    total_repayment,
                    math::mul(total_repayment, pool_liquidation_reward),
                    in_default,
                ),
            );
            let repayment_proof_quote = option::none<RepaymentProof<QuoteAsset>>();

            let base_withdrawn = math::mul(base_repaid, liquidation_multiplier);
            let base_returned = if (base_withdrawn > 0) {
                margin_manager.liquidation_withdraw_base(
                    base_withdrawn,
                    ctx,
                )
            } else {
                coin::zero<BaseAsset>(ctx)
            };
            let quote_returned = if (quote_amount_returned > 0) {
                margin_manager.liquidation_withdraw_quote(
                    quote_amount_returned,
                    ctx,
                )
            } else {
                coin::zero<QuoteAsset>(ctx)
            };

            // Emit a liquidation event for the liquidator
            event::emit(LiquidationEvent {
                margin_manager_id,
                base_amount: total_repayment,
                quote_amount: 0,
                liquidator: ctx.sender(),
            });

            (base_returned, quote_returned, repayment_proof_base, repayment_proof_quote)
        } else {
            let quote_repaid_usd = calculate_usd_price<QuoteAsset>(
                quote_price_info_object,
                registry,
                quote_repaid,
                clock,
            );
            let remaining_usd_repay = usd_amount_to_repay - quote_repaid_usd;

            let base_equivalent = calculate_target_amount<BaseAsset>(
                base_price_info_object,
                registry,
                remaining_usd_repay,
                clock,
            );
            let base_with_rewards = math::mul(base_equivalent, liquidation_reward_multiplier);

            let base_amount_returned = base_with_rewards.min(balance_manager.balance<BaseAsset>());

            let quote_loan_to_be_repaid = math::mul(
                max_quote_repay - quote_repaid,
                math::div(base_amount_returned, base_with_rewards),
            );

            let total_repayment = quote_loan_to_be_repaid + quote_repaid;
            let repayment_proof_base = option::none<RepaymentProof<BaseAsset>>();
            let repayment_proof_quote = option::some(
                create_repayment_proof<QuoteAsset>(
                    margin_manager_id,
                    total_repayment,
                    math::mul(total_repayment, pool_liquidation_reward),
                    in_default,
                ),
            );
            let base_returned = if (base_amount_returned > 0) {
                margin_manager.liquidation_withdraw_base(
                    base_amount_returned,
                    ctx,
                )
            } else {
                coin::zero<BaseAsset>(ctx)
            };
            let quote_withdrawn = math::mul(quote_repaid, liquidation_multiplier);
            let quote_returned = if (quote_withdrawn > 0) {
                margin_manager.liquidation_withdraw_quote(
                    quote_withdrawn,
                    ctx,
                )
            } else {
                coin::zero<QuoteAsset>(ctx)
            };

            // Emit a liquidation event for the liquidator
            event::emit(LiquidationEvent {
                margin_manager_id,
                base_amount: 0,
                quote_amount: total_repayment,
                liquidator: ctx.sender(),
            });

            (base_returned, quote_returned, repayment_proof_base, repayment_proof_quote)
        }
    } else {
        if (debt_is_base) {
            let repayment_proof_base = option::some(
                create_repayment_proof<BaseAsset>(
                    margin_manager_id,
                    base_repaid,
                    math::mul(base_repaid, pool_liquidation_reward),
                    in_default,
                ),
            );
            let repayment_proof_quote = option::none<RepaymentProof<QuoteAsset>>();

            let base_returned = margin_manager.liquidation_withdraw_base(
                math::mul(base_repaid, liquidation_multiplier),
                ctx,
            );
            let quote_returned = coin::zero<QuoteAsset>(ctx);

            // Emit a liquidation event for the liquidator
            event::emit(LiquidationEvent {
                margin_manager_id,
                base_amount: base_repaid,
                quote_amount: 0,
                liquidator: ctx.sender(),
            });

            (base_returned, quote_returned, repayment_proof_base, repayment_proof_quote)
        } else {
            let repayment_proof_base = option::none<RepaymentProof<BaseAsset>>();
            let repayment_proof_quote = option::some(
                create_repayment_proof<QuoteAsset>(
                    margin_manager_id,
                    quote_repaid,
                    math::mul(quote_repaid, pool_liquidation_reward),
                    in_default,
                ),
            );

            let base_returned = coin::zero<BaseAsset>(ctx);
            let quote_returned = margin_manager.liquidation_withdraw_quote(
                math::mul(quote_repaid, liquidation_multiplier),
                ctx,
            );

            // Emit a liquidation event for the liquidator
            event::emit(LiquidationEvent {
                margin_manager_id,
                base_amount: 0,
                quote_amount: quote_repaid,
                liquidator: ctx.sender(),
            });

            (base_returned, quote_returned, repayment_proof_base, repayment_proof_quote)
        }
    }
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

/// Returns the (base_debt, quote_debt) for the margin manager
public(package) fun total_debt<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    clock: &Clock,
): (u64, u64) {
    let base_debt = margin_manager.debt(base_margin_pool, clock);
    let quote_debt = margin_manager.debt(quote_margin_pool, clock);

    (base_debt, quote_debt)
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
    let user_loan_shares = margin_pool.user_loan_amount(manager_id, clock);
    let user_loan_amount = math::mul(user_loan_shares, margin_pool.state().borrow_index());

    let repay_amount = repay_amount.get_with_default(user_loan_amount);
    let available_balance = margin_manager.balance_manager().balance<RepayAsset>();
    let repay_amount = repay_amount.min(user_loan_amount).min(available_balance);

    // Owner check is skipped if this is liquidation
    let coin = margin_manager.repay_withdraw<BaseAsset, QuoteAsset, RepayAsset>(
        repay_amount,
        ctx,
    );

    margin_pool.repay(
        manager_id,
        coin,
        clock,
    );

    repay_amount
}

fun debt<BaseAsset, QuoteAsset, Asset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<Asset>,
    clock: &Clock,
): u64 {
    margin_pool.update_state(clock);
    let user_loan_shares = margin_pool.user_loan_amount(margin_manager.id(), clock);
    let user_loan_amount = math::mul(user_loan_shares, margin_pool.state().borrow_index());

    user_loan_amount
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
