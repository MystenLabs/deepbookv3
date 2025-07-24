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
    margin_constants,
    margin_pool::{user_loan, MarginPool, create_repayment_proof, RepaymentProof},
    margin_registry::MarginRegistry,
    oracle::{calculate_usd_price, calculate_target_amount, calculate_pair_usd_price}
};
use pyth::price_info::PriceInfoObject;
use std::type_name;
use sui::{clock::Clock, coin::{Self, Coin}, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginPairNotAllowed: u64 = 1;
const EInvalidMarginManager: u64 = 2;
const EBorrowRiskRatioExceeded: u64 = 3;
const EWithdrawRiskRatioExceeded: u64 = 4;
const ECannotLiquidate: u64 = 5;
const EInvalidMarginManagerOwner: u64 = 6;
const ECannotHaveLoanInBothMarginPools: u64 = 7;
const ELiquidationSlippageExceeded: u64 = 8;

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
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(
        user_loan(quote_margin_pool, margin_manager.id(), clock) == 0,
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
        user_loan(base_margin_pool, margin_manager.id(), clock) == 0,
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

    assert!(
        registry.can_liquidate<BaseAsset, QuoteAsset>(manager_info.risk_ratio),
        ECannotLiquidate,
    );

    // Step 2: We calculate how much needs to be sold (if any), and repaid.
    let margin_manager_id = margin_manager.id();
    let total_usd_debt = manager_info.base.usd_debt + manager_info.quote.usd_debt;
    let total_usd_asset = manager_info.base.usd_asset + manager_info.quote.usd_asset;
    let target_ratio = registry.target_liquidation_risk_ratio<BaseAsset, QuoteAsset>();
    let user_liquidation_reward = registry.user_liquidation_reward<BaseAsset, QuoteAsset>();
    let pool_liquidation_reward = registry.pool_liquidation_reward<BaseAsset, QuoteAsset>();
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
    // TODO: update this to use the new function in main
    let trade_proof = margin_manager
        .balance_manager
        .generate_proof_as_trader(&margin_manager.trade_cap, ctx);

    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);
    pool.withdraw_settled_amounts(balance_manager, &trade_proof);

    let mut max_base_repay = 0;
    let mut max_quote_repay = 0;

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

/// Liquidates a margin manager
public fun liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
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

    assert!(
        registry.can_liquidate<BaseAsset, QuoteAsset>(manager_info.risk_ratio),
        ECannotLiquidate,
    );

    // Step 2: We calculate how much needs to be sold (if any), and repaid.
    let total_usd_debt = manager_info.base.usd_debt + manager_info.quote.usd_debt;
    let total_usd_asset = manager_info.base.usd_asset + manager_info.quote.usd_asset;
    let target_ratio = registry.target_liquidation_risk_ratio<BaseAsset, QuoteAsset>();
    let total_liquidation_reward =
        registry.user_liquidation_reward<BaseAsset, QuoteAsset>() +
        registry.pool_liquidation_reward<BaseAsset, QuoteAsset>();

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

    let base_same_asset_repay = manager_info.base.asset.min(manager_info.base.debt);
    let quote_same_asset_repay = manager_info.quote.asset.min(manager_info.quote.debt);

    let base_usd_repay = if (base_same_asset_repay > 0) {
        calculate_usd_price<BaseAsset>(
            base_price_info_object,
            registry,
            base_same_asset_repay,
            clock,
        )
    } else {
        0
    };
    let quote_usd_repay = if (quote_same_asset_repay > 0) {
        calculate_usd_price<QuoteAsset>(
            quote_price_info_object,
            registry,
            quote_same_asset_repay,
            clock,
        )
    } else {
        0
    };

    // Simply repaying the loan using same assets will be enough to cover the liquidation.
    let same_asset_usd_repay = base_usd_repay + quote_usd_repay;

    // Step 3: Trade execution and repayment
    // TODO: update this to use the new function in main
    let trade_proof = margin_manager
        .balance_manager
        .generate_proof_as_trader(&margin_manager.trade_cap, ctx);

    let balance_manager = margin_manager.balance_manager_mut();
    pool.cancel_all_orders(balance_manager, &trade_proof, clock, ctx);
    pool.withdraw_settled_amounts(balance_manager, &trade_proof);
    let (_, lot_size, min_size) = pool.pool_book_params<BaseAsset, QuoteAsset>();
    let (taker_fee, _, _) = pool.pool_trade_params();
    // Assume taker fee is 1%. We apply the 1.25 multiplier to make it 1.25%, since we're paying in input token.
    let penalty_taker_fee = math::mul(
        constants::fee_penalty_multiplier(),
        taker_fee,
    );
    let penalty_taker_fee_multiplier = constants::float_scaling() + penalty_taker_fee;

    let (base_repaid, quote_repaid) = if (same_asset_usd_repay < usd_amount_to_repay) {
        let max_slippage = registry.max_slippage<BaseAsset, QuoteAsset>();
        let liquidation_reward_multiplier = constants::float_scaling() + total_liquidation_reward;

        // After repayment of the same assets, these will be the debt and asset remaining
        let new_total_usd_debt = total_usd_debt - same_asset_usd_repay;
        let new_total_usd_asset =
            total_usd_asset - math::mul(same_asset_usd_repay, liquidation_reward_multiplier);

        // Equation to calculate the amount to swap, accounting for taker fees and liquidation rewards.
        let usd_amount_to_swap = math::div(
            (math::mul(new_total_usd_debt, target_ratio) - new_total_usd_asset),
            (
                math::div(math::mul(target_ratio,constants::float_scaling() - penalty_taker_fee), liquidation_reward_multiplier) - constants::float_scaling(),
            ),
        );

        // Calculate the amount to swap from quote to base
        if (debt_is_base) {
            // This becomes 1.1 * target_amount
            let quote_amount_liquidate = calculate_target_amount<QuoteAsset>(
                quote_price_info_object,
                registry,
                usd_amount_to_swap,
                clock,
            );

            let client_order_id = 0;
            let is_bid = true;
            let pay_with_deep = false; // We have to use input token as fee during liquidation, in case there is not enough DEEP in the balance manager.

            let quote_balance = balance_manager.balance<QuoteAsset>();
            let quote_amount_swap = quote_balance.min(
                quote_amount_liquidate,
            );

            let (base_out, _, _) = pool.get_base_quantity_out_input_fee(
                quote_amount_swap,
                clock,
            );

            let order_info = pool.place_market_order(
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

            // We check the usd value of the base quantity received, vs the quote quantity used
            // The base received in USD should be at least the quote used in USD, minus slippage
            let base_quantity_received = order_info.executed_quantity();
            let quote_quantity_used = order_info.cumulative_quote_quantity();

            let base_usd_received = calculate_usd_price<BaseAsset>(
                base_price_info_object,
                registry,
                base_quantity_received,
                clock,
            );
            let quote_usd_used = calculate_usd_price<QuoteAsset>(
                quote_price_info_object,
                registry,
                quote_quantity_used,
                clock,
            );

            assert!(
                base_usd_received >= math::mul(quote_usd_used, constants::float_scaling() - max_slippage),
                ELiquidationSlippageExceeded,
            );
        };

        // Calculate the amount to swap from base to quote.
        if (!debt_is_base) {
            let base_amount_liquidate = calculate_target_amount<BaseAsset>(
                base_price_info_object,
                registry,
                usd_amount_to_swap,
                clock,
            );

            let client_order_id = 0;
            let is_bid = false;
            let pay_with_deep = false; // We have to use input token as fee during liquidation, in case there is not enough DEEP in the balance manager.

            // We can only swap the lesser of the amount to liquidate and the manager balance, if there's a default scenario.
            let base_balance = balance_manager.balance<BaseAsset>();
            let mut base_amount_swap = base_balance.min(
                base_amount_liquidate,
            );
            // Since our amount to swap includes fees, we have to adjust the base_quantity down, or order will fail.
            base_amount_swap = math::div(base_amount_swap, penalty_taker_fee_multiplier);
            let base_quantity = base_amount_swap - base_amount_swap % lot_size;

            let order_info = pool.place_market_order(
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

            // We check the usd value of the quote quantity received, vs the base quantity used
            // The quote received in USD should be at least the base used in USD, minus slippage
            let base_quantity_used = order_info.executed_quantity();
            let quote_quantity_received = order_info.cumulative_quote_quantity();

            let base_usd_used = calculate_usd_price<BaseAsset>(
                base_price_info_object,
                registry,
                base_quantity_used,
                clock,
            );
            let quote_usd_received = calculate_usd_price<QuoteAsset>(
                quote_price_info_object,
                registry,
                quote_quantity_received,
                clock,
            );

            assert!(
                quote_usd_received >= math::mul(base_usd_used, constants::float_scaling() - max_slippage),
                ELiquidationSlippageExceeded,
            );
        };

        // We repay the same loans using the same assets. The amount repaid is returned
        margin_manager.repay_all_liquidation(
            base_margin_pool,
            quote_margin_pool,
            registry,
            option::none(),
            option::none(),
            clock,
            ctx,
        )
    } else {
        // Just repaying using existing assets without swaps is enough to bring the risk ratio to target.
        let max_base_repay = math::mul(
            manager_info.base.debt,
            math::div(usd_amount_to_repay, total_usd_debt),
        );
        let max_quote_repay = math::mul(
            manager_info.quote.debt,
            math::div(usd_amount_to_repay, total_usd_debt),
        );

        margin_manager.repay_all_liquidation(
            base_margin_pool,
            quote_margin_pool,
            registry,
            option::some(max_base_repay),
            option::some(max_quote_repay),
            clock,
            ctx,
        )
    };

    // Emit a liquidation event for the liquidator
    event::emit(LiquidationEvent {
        margin_manager_id: margin_manager.id(),
        base_amount: base_repaid,
        quote_amount: quote_repaid,
        liquidator: ctx.sender(),
    });

    // Step 4: Liquidation rewards based on amount repaid.
    // After repayment, the manager should be close to the target risk ratio (some slippage, but should be close).
    // We withdraw the liquidation reward for the pool.
    let pool_liquidation_reward = registry.pool_liquidation_reward<BaseAsset, QuoteAsset>(); // 2%
    let pool_liquidation_reward_base = math::mul(pool_liquidation_reward, base_repaid);
    let pool_liquidation_reward_quote = math::mul(pool_liquidation_reward, quote_repaid);

    if (pool_liquidation_reward_base > 0) {
        let pool_base_coin = margin_manager.liquidation_withdraw_base(
            pool_liquidation_reward_base,
            ctx,
        );
        base_margin_pool.add_liquidation_reward<BaseAsset>(
            pool_base_coin,
            margin_manager.id(),
            clock,
        );
    };

    if (pool_liquidation_reward_quote > 0) {
        let pool_quote_coin = margin_manager.liquidation_withdraw_quote(
            pool_liquidation_reward_quote,
            ctx,
        );
        quote_margin_pool.add_liquidation_reward<QuoteAsset>(
            pool_quote_coin,
            margin_manager.id(),
            clock,
        );
    };

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

    if (in_default(manager_info.risk_ratio)) {
        // Based on the pool min_size, we calculate the minimum USD order size including fees.
        let min_usd_order = math::mul(
            penalty_taker_fee_multiplier,
            calculate_usd_price<BaseAsset>(
                base_price_info_object,
                registry,
                min_size,
                clock,
            ),
        );

        // Either user defaulted on a base debt, or a quote debt. Cannot be both.
        if (debt_is_base) {
            // If user defaulted on a base debt, we have to make sure the quote to base swap is complete.
            // We check to see no more quote assets can be swapped to base.
            let quote_asset_remain = margin_manager.balance_manager.balance<QuoteAsset>();
            let quote_asset_remain_usd = calculate_usd_price<QuoteAsset>(
                quote_price_info_object,
                registry,
                quote_asset_remain,
                clock,
            );

            // No more quote asset can be swapped to base, so we default on the base loan
            if (quote_asset_remain_usd < min_usd_order) {
                base_margin_pool.default_loan(margin_manager.id(), clock);
            };
        } else {
            // If user defaulted on a quote debt, we have to make sure the base to quote swap is complete.
            // We check to see no more base assets can be swapped to quote.
            let base_asset_remain = margin_manager.balance_manager.balance<BaseAsset>();
            let base_asset_remain_usd = calculate_usd_price<BaseAsset>(
                base_price_info_object,
                registry,
                base_asset_remain,
                clock,
            );

            // No more base asset can be swapped to quote, so we default on the quote loan
            if (base_asset_remain_usd < min_usd_order) {
                quote_margin_pool.default_loan(margin_manager.id(), clock);
            };
        };
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
    let manager_id = margin_manager.id();
    let user_loan = margin_pool.user_loan(manager_id, clock);

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

/// Returns the (base_debt, quote_debt) for the margin manager
fun total_debt<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    clock: &Clock,
): (u64, u64) {
    let base_debt = margin_manager.debt(base_margin_pool, clock);
    let quote_debt = margin_manager.debt(quote_margin_pool, clock);

    (base_debt, quote_debt)
}

fun debt<BaseAsset, QuoteAsset, Asset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    margin_pool: &mut MarginPool<Asset>,
    clock: &Clock,
): u64 {
    margin_pool.user_loan(margin_manager.id(), clock)
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

/// Returns (base_asset, quote_asset) for margin manager.
fun total_assets<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
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
    max_base_repay: Option<u64>, // if None, repay max
    max_quote_repay: Option<u64>, // if None, repay max
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    let base_repaid = margin_manager.repay_base_liquidate(
        base_margin_pool,
        margin_registry,
        max_base_repay,
        clock,
        ctx,
    );
    let quote_repaid = margin_manager.repay_quote_liquidate(
        quote_margin_pool,
        margin_registry,
        max_quote_repay,
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
    repay_amount: Option<u64>, // if None, repay max
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.repay_liquidation<BaseAsset, QuoteAsset, BaseAsset>(
        margin_pool,
        registry,
        repay_amount,
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
    repay_amount: Option<u64>, // if None, repay max
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    margin_manager.repay_liquidation<BaseAsset, QuoteAsset, QuoteAsset>(
        margin_pool,
        registry,
        repay_amount,
        clock,
        ctx,
    )
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
    let manager_id = margin_manager.id();
    let user_loan = margin_pool.user_loan(manager_id, clock);

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

    if (repayment == 0) {
        return 0 // Nothing to repay
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

fun in_default(risk_ratio: u64): bool {
    risk_ratio < constants::float_scaling() // Risk ratio < 1.0 means the manager is in default.
}
