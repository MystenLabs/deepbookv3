// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account-model wrapper around DeepBook core trading APIs. Each account gets one
/// stable embedded balance manager plus the caps needed to fund, trade, and sweep
/// through DeepBook without making the manager a long-lived user custody surface.
module deepbook_core_account::deepbook_core_account;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook::{
    account::Account as CoreAccount,
    order::Order,
    order_info::OrderInfo,
    pool::Pool,
    registry::Registry
};
use deepbook_core_account::account_data;
use sui::{accumulator::AccumulatorRoot, clock::Clock, vec_set::{Self as vec_set, VecSet}};
use token::deep::DEEP;

/// Return whether this account's embedded balance manager has pool account data.
public fun account_exists<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): bool {
    if (!account_data::is_initialized(account)) {
        false
    } else {
        let d = account_data::borrow(account);
        pool.account_exists(account_data::balance_manager(d))
    }
}

/// Return a copy of the DeepBook core account for this account's balance manager.
public fun account<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): Option<CoreAccount> {
    if (!account_data::is_initialized(account)) {
        option::none()
    } else {
        let d = account_data::borrow(account);
        let balance_manager = account_data::balance_manager(d);
        if (!pool.account_exists(balance_manager)) {
            option::none()
        } else {
            option::some(pool.account(balance_manager))
        }
    }
}

/// Return the open order IDs for this account's embedded balance manager.
public fun account_open_orders<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): VecSet<u128> {
    if (!account_data::is_initialized(account)) {
        vec_set::empty()
    } else {
        let d = account_data::borrow(account);
        pool.account_open_orders(account_data::balance_manager(d))
    }
}

/// Return full order details for this account's embedded balance manager.
public fun get_account_order_details<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): vector<Order> {
    if (!account_data::is_initialized(account)) {
        vector[]
    } else {
        let d = account_data::borrow(account);
        pool.get_account_order_details(account_data::balance_manager(d))
    }
}

/// Return locked base, quote, and DEEP balances for this account in the pool.
public fun locked_balance<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    account: &Account,
): (u64, u64, u64) {
    if (!account_data::is_initialized(account)) {
        (0, 0, 0)
    } else {
        let d = account_data::borrow(account);
        pool.locked_balance(account_data::balance_manager(d))
    }
}

/// Place a DeepBook limit order using account custody. The wrapper settles and
/// temporarily funds the embedded manager with all account balances for the
/// three touched coin types, calls core, then sweeps free balances back.
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
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    wrapper.settle<BaseAsset>(root, clock);
    wrapper.settle<QuoteAsset>(root, clock);
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let (base_funding, quote_funding, deep_funding) = account_data::withdraw_all<
        BaseAsset,
        QuoteAsset,
    >(account, root, clock, ctx);
    account_data::ensure(account, deepbook_registry, ctx);
    let d = account_data::borrow_mut(account);
    account_data::deposit_to_manager_if_nonzero<BaseAsset>(d, base_funding, ctx);
    account_data::deposit_to_manager_if_nonzero<QuoteAsset>(d, quote_funding, ctx);
    account_data::deposit_to_manager_if_nonzero<DEEP>(d, deep_funding, ctx);
    let proof = account_data::generate_trader_proof(d, ctx);
    let info = pool.place_limit_order(
        account_data::balance_manager_mut(d),
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
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
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
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    wrapper.settle<BaseAsset>(root, clock);
    wrapper.settle<QuoteAsset>(root, clock);
    wrapper.settle<DEEP>(root, clock);
    let account = wrapper.load_account_mut(auth);
    let (base_funding, quote_funding, deep_funding) = account_data::withdraw_all<
        BaseAsset,
        QuoteAsset,
    >(account, root, clock, ctx);
    account_data::ensure(account, deepbook_registry, ctx);
    let d = account_data::borrow_mut(account);
    account_data::deposit_to_manager_if_nonzero<BaseAsset>(d, base_funding, ctx);
    account_data::deposit_to_manager_if_nonzero<QuoteAsset>(d, quote_funding, ctx);
    account_data::deposit_to_manager_if_nonzero<DEEP>(d, deep_funding, ctx);
    let proof = account_data::generate_trader_proof(d, ctx);
    let info = pool.place_market_order(
        account_data::balance_manager_mut(d),
        &proof,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
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
    account_data::ensure(account, deepbook_registry, ctx);
    let d = account_data::borrow_mut(account);
    let proof = account_data::generate_trader_proof(d, ctx);
    pool.cancel_live_order(account_data::balance_manager_mut(d), &proof, order_id, clock, ctx);
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
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
    account_data::ensure(account, deepbook_registry, ctx);
    let d = account_data::borrow_mut(account);
    let proof = account_data::generate_trader_proof(d, ctx);
    pool.cancel_live_orders(account_data::balance_manager_mut(d), &proof, order_ids, clock, ctx);
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
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
    account_data::ensure(account, deepbook_registry, ctx);
    let d = account_data::borrow_mut(account);
    let proof = account_data::generate_trader_proof(d, ctx);
    pool.withdraw_settled_amounts(account_data::balance_manager_mut(d), &proof);
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
}

/// Permissionlessly withdraw settled core amounts for an already-initialized
/// account, then sweep them into account custody.
public fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    ctx: &mut TxContext,
) {
    let auth = account_data::generate_auth_as_app(account_registry);
    let account = wrapper.load_account_mut(auth);
    if (!account_data::is_initialized(account)) return;
    let d = account_data::borrow_mut(account);
    pool.withdraw_settled_amounts_permissionless(account_data::balance_manager_mut(d));
    let (base_swept, quote_swept, deep_swept) = account_data::sweep_all<BaseAsset, QuoteAsset>(
        d,
        ctx,
    );
    account_data::deposit_all<BaseAsset, QuoteAsset>(
        account,
        base_swept,
        quote_swept,
        deep_swept,
    );
}
