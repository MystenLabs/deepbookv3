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
use margin_trading::margin_registry::{Self, MarginRegistry};
use std::type_name;
use sui::{clock::Clock, coin::Coin, event};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;
const EMarginPairNotAllowed: u64 = 1;

// === Constants ===
// const MAX_TRADE_CAPS: u64 = 1000;

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

// === Public-Mutative Functions ===
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

// TODO: liquidate based on whether base or quote needs to be liquidated
public fun liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    // TODO: Cancel all open orders, collect settled balances, then liquidate?
    // TODO?: Call repay_same_assets first to ensure that the margin manager is in a state where it can liquidate.
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

// public fun repay_same_assets<BaseAsset, QuoteAsset>(
//     margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     abort 0x1
// }

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
/// The withdrawal is subject to the risk ratio limit, which will be checked before allowing the withdrawal.
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let balance_manager = &mut margin_manager.balance_manager;

    let coin = balance_manager.withdraw<WithdrawAsset>(
        withdraw_amount,
        ctx,
    );

    // TODO: Check risk ratio to determine if withdrawal is allowed

    coin
}

public fun claim_rebates<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &mut TxContext,
) {
    let balance_manager = &mut margin_manager.balance_manager;
    let trade_proof = balance_manager.generate_proof_as_trader(
        &margin_manager.trade_cap,
        ctx,
    );

    pool.claim_rebates(balance_manager, &trade_proof, ctx)
}

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

public(package) fun id<BaseAsset, QuoteAsset>(
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): ID {
    object::id(margin_manager)
}
