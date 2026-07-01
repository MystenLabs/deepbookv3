// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account app-data for the DeepBook core wrapper. This module owns the embedded
/// balance manager slot and exposes only package-scoped helpers for the public
/// facade to fund, trade, and sweep through that manager.
module deepbook_core_account::account_data;

use account::{
    account::{Account, Auth},
    account_registry::{Self as account_registry, AccountRegistry}
};
use deepbook::{
    balance_manager::{Self, BalanceManager, DepositCap, TradeCap, TradeProof, WithdrawCap},
    registry::Registry
};
use std::internal::permit;
use sui::{coin::{Self, Coin}, event};
use token::deep::DEEP;

/// App witness that namespaces DeepBook core account data on an `Account`.
public struct DeepbookCoreAccountApp has drop {}

/// Per-account DeepBook core state. The embedded manager ID is stable across all
/// wrapped calls, so resting orders remain addressable by DeepBook core state.
public struct DeepbookCoreAccountData has store {
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    withdraw_cap: WithdrawCap,
    trade_cap: TradeCap,
}

/// Emitted once when a canonical account first gets DeepBook core account data.
public struct DeepbookCoreAccountInitialized has copy, drop {
    account_id: ID,
    account_owner: address,
    wrapper_id: ID,
    balance_manager_id: ID,
}

/// Return whether this account already has a DeepBook core account slot.
public fun is_initialized(account: &Account): bool {
    account.has_data<DeepbookCoreAccountApp>()
}

/// Return this account's embedded balance-manager ID, if the slot exists.
public fun balance_manager_id(account: &Account): Option<ID> {
    if (!is_initialized(account)) {
        option::none()
    } else {
        option::some(borrow(account).balance_manager.id())
    }
}

/// Return the free balance of `T` currently sitting in the embedded manager.
public fun balance_manager_balance<T>(account: &Account): u64 {
    if (!is_initialized(account)) {
        0
    } else {
        borrow(account).balance_manager.balance<T>()
    }
}

public(package) fun generate_auth_as_app(account_registry: &AccountRegistry): Auth {
    account_registry::generate_auth_as_app<DeepbookCoreAccountApp>(
        account_registry,
        permit<DeepbookCoreAccountApp>(),
    )
}

public(package) fun borrow(account: &Account): &DeepbookCoreAccountData {
    account.borrow_data<DeepbookCoreAccountApp, DeepbookCoreAccountData>()
}

public(package) fun ensure(
    account: &mut Account,
    deepbook_registry: &Registry,
    ctx: &mut TxContext,
) {
    if (!is_initialized(account)) {
        let (
            balance_manager,
            deposit_cap,
            withdraw_cap,
            trade_cap,
        ) = balance_manager::new_with_custom_owner_caps_v2<DeepbookCoreAccountApp>(
            DeepbookCoreAccountApp {},
            deepbook_registry,
            account.account_id().to_address(),
            ctx,
        );
        let account_id = account.account_id();
        let account_owner = account.owner();
        let wrapper_id = account.receive_address().to_id();
        let balance_manager_id = balance_manager.id();
        account.attach(
            permit<DeepbookCoreAccountApp>(),
            DeepbookCoreAccountData { balance_manager, deposit_cap, withdraw_cap, trade_cap },
        );
        event::emit(DeepbookCoreAccountInitialized {
            account_id,
            account_owner,
            wrapper_id,
            balance_manager_id,
        });
    };
}

public(package) fun borrow_mut(account: &mut Account): &mut DeepbookCoreAccountData {
    account.borrow_data_mut<DeepbookCoreAccountApp, DeepbookCoreAccountData>(
        permit<DeepbookCoreAccountApp>(),
    )
}

public(package) fun balance_manager(d: &DeepbookCoreAccountData): &BalanceManager {
    &d.balance_manager
}

public(package) fun balance_manager_mut(d: &mut DeepbookCoreAccountData): &mut BalanceManager {
    &mut d.balance_manager
}

public(package) fun generate_trader_proof(
    d: &mut DeepbookCoreAccountData,
    ctx: &TxContext,
): TradeProof {
    d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx)
}

public(package) fun sweep_all<BaseAsset, QuoteAsset>(
    d: &mut DeepbookCoreAccountData,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    (
        sweep_from_manager<BaseAsset>(d, ctx),
        sweep_from_manager<QuoteAsset>(d, ctx),
        sweep_from_manager<DEEP>(d, ctx),
    )
}

public(package) fun deposit_all<BaseAsset, QuoteAsset>(
    account: &mut Account,
    base: Coin<BaseAsset>,
    quote: Coin<QuoteAsset>,
    deep: Coin<DEEP>,
) {
    deposit_to_account_if_nonzero<BaseAsset>(account, base);
    deposit_to_account_if_nonzero<QuoteAsset>(account, quote);
    deposit_to_account_if_nonzero<DEEP>(account, deep);
}

public(package) fun withdraw_or_zero<T>(
    account: &mut Account,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    if (amount == 0) {
        coin::zero<T>(ctx)
    } else {
        account.withdraw<T>(amount, ctx)
    }
}

public(package) fun deposit_to_manager_if_nonzero<T>(
    d: &mut DeepbookCoreAccountData,
    coin: Coin<T>,
    ctx: &TxContext,
) {
    if (coin.value() == 0) {
        coin.destroy_zero();
    } else {
        d.balance_manager.deposit_with_cap<T>(&d.deposit_cap, coin, ctx);
    }
}

fun sweep_from_manager<T>(d: &mut DeepbookCoreAccountData, ctx: &mut TxContext): Coin<T> {
    let amount = d.balance_manager.balance<T>();
    if (amount == 0) {
        coin::zero<T>(ctx)
    } else {
        d.balance_manager.withdraw_with_cap<T>(&d.withdraw_cap, amount, ctx)
    }
}

fun deposit_to_account_if_nonzero<T>(account: &mut Account, coin: Coin<T>) {
    if (coin.value() == 0) {
        coin.destroy_zero();
    } else {
        account.deposit<T>(coin);
    }
}
