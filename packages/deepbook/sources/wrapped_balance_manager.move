// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This is an example of how to wrap a BalanceManager with additional functionality.
/// The inner BalanceManager cannot be exposed as mutable to the outside world.
/// This is to ensure that the BalanceManager is always used in a safe way.
module deepbook::wrapped_balance_manager;
use deepbook::balance_manager::{Self, BalanceManager};
use deepbook::pool::Pool;
use std::type_name;
use sui::clock::Clock;
use sui::coin::Coin;
use token::deep::DEEP;

const EWithdrawalOverSponsoredDeep: u64 = 0;

public struct WrappedBalanceManager has key {
    id: UID,
    sponsored_deep: u64,
    balance_manager: BalanceManager,
}

public fun new(ctx: &mut TxContext): WrappedBalanceManager {
    let balance_manager = balance_manager::new(ctx);
    WrappedBalanceManager {
        id: object::new(ctx),
        sponsored_deep: 0,
        balance_manager,
    }
}

/// Deposit any coin
public fun deposit<T>(
    self: &mut WrappedBalanceManager,
    to_deposit: Coin<T>,
    ctx: &mut TxContext,
) {
    self.balance_manager.deposit(to_deposit, ctx);
}

/// Deposit sponsored DEEP
public fun deposit_sponsored_deep<DEEP>(
    self: &mut WrappedBalanceManager,
    to_deposit: Coin<DEEP>,
    ctx: &mut TxContext,
) {
    let quantity = to_deposit.value();
    self.sponsored_deep = self.sponsored_deep + quantity;
    self.deposit(to_deposit, ctx);
}

/// Withdraw any coin. If it's DEEP, ensure it's not over sponsored amount.
public fun withdraw<T>(
    self: &mut WrappedBalanceManager,
    withdraw_amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let type_name = type_name::get<T>();
    let deep_name = type_name::get<DEEP>();
    if (type_name == deep_name) {
        assert!(
            self.sponsored_deep >= withdraw_amount,
            EWithdrawalOverSponsoredDeep,
        );
        self.sponsored_deep = self.sponsored_deep - withdraw_amount;
    };

    self.balance_manager.withdraw(withdraw_amount, ctx)
}

/// Example of calling a pool function
public fun place_limit_order<BaseAsset, QuoteAsset>(
    self: &mut WrappedBalanceManager,
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
) {
    let trade_proof = self.balance_manager.generate_proof_as_owner(ctx);

    pool.place_limit_order(
        &mut self.balance_manager,
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
    );
}
