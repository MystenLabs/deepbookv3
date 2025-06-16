// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The MarginManager is a shared object that holds all of the balances for different assets. A combination of `BalanceManager` and
/// `TradeProof` are passed into a pool to perform trades. A `TradeProof` can be generated in two ways: by the
/// owner directly, or by any `TradeCap` owner. The owner can generate a `TradeProof` without the risk of
/// equivocation. The `TradeCap` owner, due to it being an owned object, risks equivocation when generating
/// a `TradeProof`. Generally, a high frequency trading engine will trade as the default owner.
///
/// TODO: update comments
module margin_trading::margin_manager;

use deepbook::balance_manager::{
    Self,
    BalanceManager,
    BalanceKey,
    TradeCap,
    TradeProof,
    DepositCap,
    WithdrawCap
};
use deepbook::constants;
use deepbook::pool::{Self, Pool};
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::coin::Coin;
use sui::event;
use sui::vec_set::{Self, VecSet};
use token::deep::DEEP;

// === Errors ===
const EInvalidDeposit: u64 = 0;

// === Constants ===
// const MAX_TRADE_CAPS: u64 = 1000;

public struct MARGIN_MANAGER has drop {}

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
public fun new<BaseAsset, QuoteAsset>(ctx: &mut TxContext) {
    // TODO: add in logic to ensure only certain pairs of margin managers can be created. This can be a shared object

    let id = object::new(ctx);

    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager::mint_deposit_cap(&mut balance_manager, ctx);
    let withdraw_cap = balance_manager::mint_withdraw_cap(&mut balance_manager, ctx);
    let trade_cap = balance_manager::mint_trade_cap(&mut balance_manager, ctx);

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

    transfer::public_share_object(margin_manager)
}

public fun liquidate<BaseAsset, QuoteAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    ctx: &TxContext,
) {
    let balance_manager = &mut margin_manager.balance_manager;
    let trade_proof = balance_manager.generate_proof_as_trader(
        &margin_manager.trade_cap,
        ctx,
    );

    let quote_amount_to_liquidate = 100_000_000; // 100 USDC, TODO: replace with actual logic
    let price_to_liquidate = 1_000_000; // 1 USDC, TODO: replace with actual logic
    let client_order_id = 0; // TODO: Should this be customizable?

    // pool.place_market_order(
    //     balance_manager,
    //     &trade_proof,
    //     client_order_id,
    //     constants::self_matching_allowed(),

    // );
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

    balance_manager.deposit_with_cap<DepositAsset>(&margin_manager.deposit_cap, coin, ctx);
}

public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let withdraw_asset_type = type_name::get<WithdrawAsset>();
    let base_asset_type = type_name::get<BaseAsset>();
    let quote_asset_type = type_name::get<QuoteAsset>();
    let deep_asset_type = type_name::get<DEEP>();
    assert!(
        withdraw_asset_type == base_asset_type || withdraw_asset_type == quote_asset_type || withdraw_asset_type == deep_asset_type,
        EInvalidDeposit,
    );

    let balance_manager = &mut margin_manager.balance_manager;

    let coin = balance_manager.withdraw_with_cap<WithdrawAsset>(
        &margin_manager.withdraw_cap,
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
