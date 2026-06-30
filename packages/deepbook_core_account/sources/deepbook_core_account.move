// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account-model wrapper around DeepBook core trading APIs. Each account gets one
/// stable embedded balance manager plus the caps needed to fund, trade, and sweep
/// through DeepBook without making the manager a long-lived user custody surface.
module deepbook_core_account::deepbook_core_account;

use account::{
    account::{Account, AccountWrapper, Auth},
    account_registry::{Self as account_registry, AccountRegistry}
};
use deepbook::{
    account::Account as CoreAccount,
    balance_manager::{Self, BalanceManager, DepositCap, TradeCap, WithdrawCap},
    order::Order,
    order_info::OrderInfo,
    pool::Pool,
    registry::Registry
};
use std::internal::permit;
use sui::{
    accumulator::AccumulatorRoot,
    clock::Clock,
    coin::{Self, Coin},
    vec_set::{Self as vec_set, VecSet}
};
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

/// Return whether this account already has a DeepBook core account slot.
public fun is_initialized(account: &Account): bool {
    account.has_data<DeepbookCoreAccountApp>()
}

/// Return this account's embedded balance-manager ID, if the slot exists.
public fun balance_manager_id(account: &Account): Option<ID> {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        option::none()
    } else {
        option::some(data(account).balance_manager.id())
    }
}

/// Return the free balance of `T` currently sitting in the embedded manager.
public fun balance_manager_balance<T>(account: &Account): u64 {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        0
    } else {
        data(account).balance_manager.balance<T>()
    }
}

/// Return whether this account's embedded balance manager has pool account data.
public fun account_exists<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): bool {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        false
    } else {
        pool.account_exists(&data(account).balance_manager)
    }
}

/// Return a copy of the DeepBook core account for this account's balance manager.
public fun account<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): Option<CoreAccount> {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        option::none()
    } else {
        let d = data(account);
        if (!pool.account_exists(&d.balance_manager)) {
            option::none()
        } else {
            option::some(pool.account(&d.balance_manager))
        }
    }
}

/// Return the open order IDs for this account's embedded balance manager.
public fun account_open_orders<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): VecSet<u128> {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        vec_set::empty()
    } else {
        pool.account_open_orders(&data(account).balance_manager)
    }
}

/// Return full order details for this account's embedded balance manager.
public fun get_account_order_details<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): vector<Order> {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        vector[]
    } else {
        pool.get_account_order_details(&data(account).balance_manager)
    }
}

/// Return locked base, quote, and DEEP balances for this account in the pool.
public fun locked_balance<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): (u64, u64, u64) {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
        (0, 0, 0)
    } else {
        pool.locked_balance(&data(account).balance_manager)
    }
}

/// Place a DeepBook limit order using account custody. The wrapper settles all
/// three touched coin types, temporarily funds the embedded manager, calls core,
/// then sweeps free balances back into the account.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    max_base_in: u64,
    max_quote_in: u64,
    max_deep_in: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    wrapper.settle<BaseAsset>(root, clock);
    wrapper.settle<QuoteAsset>(root, clock);
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let base_funding = withdraw_or_zero<BaseAsset>(account, max_base_in, ctx);
    let quote_funding = withdraw_or_zero<QuoteAsset>(account, max_quote_in, ctx);
    let deep_funding = withdraw_or_zero<DEEP>(account, max_deep_in, ctx);
    ensure_data(account, deepbook_registry, ctx);
    let d = data_mut(account);
    deposit_to_manager_if_nonzero<BaseAsset>(d, base_funding, ctx);
    deposit_to_manager_if_nonzero<QuoteAsset>(d, quote_funding, ctx);
    deposit_to_manager_if_nonzero<DEEP>(d, deep_funding, ctx);
    let proof = d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx);
    let info = pool.place_limit_order(
        &mut d.balance_manager,
        &proof,
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
    );
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
    info
}

/// Place a DeepBook market order using account custody.
public fun place_market_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    max_base_in: u64,
    max_quote_in: u64,
    max_deep_in: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    wrapper.settle<BaseAsset>(root, clock);
    wrapper.settle<QuoteAsset>(root, clock);
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let base_funding = withdraw_or_zero<BaseAsset>(account, max_base_in, ctx);
    let quote_funding = withdraw_or_zero<QuoteAsset>(account, max_quote_in, ctx);
    let deep_funding = withdraw_or_zero<DEEP>(account, max_deep_in, ctx);
    ensure_data(account, deepbook_registry, ctx);
    let d = data_mut(account);
    deposit_to_manager_if_nonzero<BaseAsset>(d, base_funding, ctx);
    deposit_to_manager_if_nonzero<QuoteAsset>(d, quote_funding, ctx);
    deposit_to_manager_if_nonzero<DEEP>(d, deep_funding, ctx);
    let proof = d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx);
    let info = pool.place_market_order(
        &mut d.balance_manager,
        &proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
    info
}

/// Cancel a live order if it is still open for the embedded manager.
public fun cancel_live_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    order_id: u128,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account = wrapper.load_account_mut(auth);
    ensure_data(account, deepbook_registry, ctx);
    let d = data_mut(account);
    let proof = d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx);
    pool.cancel_live_order(&mut d.balance_manager, &proof, order_id, clock, ctx);
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
}

/// Cancel all listed live orders still open for the embedded manager.
public fun cancel_live_orders<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let account = wrapper.load_account_mut(auth);
    ensure_data(account, deepbook_registry, ctx);
    let d = data_mut(account);
    let proof = d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx);
    pool.cancel_live_orders(&mut d.balance_manager, &proof, order_ids, clock, ctx);
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
}

/// Withdraw any settled core amounts into the embedded manager and sweep them back
/// into the account.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    wrapper: &mut AccountWrapper,
    auth: Auth,
    ctx: &mut TxContext,
) {
    let account = wrapper.load_account_mut(auth);
    ensure_data(account, deepbook_registry, ctx);
    let d = data_mut(account);
    let proof = d.balance_manager.generate_proof_as_trader(&d.trade_cap, ctx);
    pool.withdraw_settled_amounts(&mut d.balance_manager, &proof);
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
}

/// Permissionlessly withdraw settled core amounts for an already-initialized
/// account, then sweep them into account custody.
public fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    ctx: &mut TxContext,
) {
    let auth = account_registry::generate_auth_as_app<DeepbookCoreAccountApp>(
        account_registry,
        permit<DeepbookCoreAccountApp>(),
    );
    let account = wrapper.load_account_mut(auth);
    if (!account.has_data<DeepbookCoreAccountApp>()) return;
    let d = data_mut(account);
    pool.withdraw_settled_amounts_permissionless(&mut d.balance_manager);
    let (base_swept, quote_swept, deep_swept) = sweep_all<BaseAsset, QuoteAsset>(d, ctx);
    deposit_all<BaseAsset, QuoteAsset>(account, base_swept, quote_swept, deep_swept);
}

fun data(account: &Account): &DeepbookCoreAccountData {
    account.borrow_data<DeepbookCoreAccountApp, DeepbookCoreAccountData>()
}

fun ensure_data(account: &mut Account, deepbook_registry: &Registry, ctx: &mut TxContext) {
    if (!account.has_data<DeepbookCoreAccountApp>()) {
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
        account.attach(
            permit<DeepbookCoreAccountApp>(),
            DeepbookCoreAccountData { balance_manager, deposit_cap, withdraw_cap, trade_cap },
        );
    };
}

fun data_mut(account: &mut Account): &mut DeepbookCoreAccountData {
    account.borrow_data_mut<DeepbookCoreAccountApp, DeepbookCoreAccountData>(
        permit<DeepbookCoreAccountApp>(),
    )
}

fun sweep_all<BaseAsset, QuoteAsset>(
    d: &mut DeepbookCoreAccountData,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    (
        sweep_from_manager<BaseAsset>(d, ctx),
        sweep_from_manager<QuoteAsset>(d, ctx),
        sweep_from_manager<DEEP>(d, ctx),
    )
}

fun deposit_all<BaseAsset, QuoteAsset>(
    account: &mut Account,
    base: Coin<BaseAsset>,
    quote: Coin<QuoteAsset>,
    deep: Coin<DEEP>,
) {
    deposit_to_account_if_nonzero<BaseAsset>(account, base);
    deposit_to_account_if_nonzero<QuoteAsset>(account, quote);
    deposit_to_account_if_nonzero<DEEP>(account, deep);
}

fun withdraw_or_zero<T>(account: &mut Account, amount: u64, ctx: &mut TxContext): Coin<T> {
    if (amount == 0) {
        coin::zero<T>(ctx)
    } else {
        account.withdraw<T>(amount, ctx)
    }
}

fun deposit_to_manager_if_nonzero<T>(
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
