// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// TODO: I think it might make more sense to represent ownership by a "Capability",
// instead of by address. That allows for flexible access control (someone could wrap their AccountCap)
// and pass it to others.
// Is this intented to be a shared object or an owned object? Important: You cannot promote owned to shared!

module deepbook::account {
    use sui::{
        coin::Coin,
        balance::{Balance},
        dynamic_field as df,
    };

    //// The account doesn't have enough funds to be withdrawn
    const EAccountBalanceTooLow: u64 = 0;

    /// Owned by user, this is what's passed into pools
    public struct Account has key, store {
        id: UID,
        owner: address,
        // coin_balances will be represented in dynamic fields
    }

    /// Identifier for balance
    public struct BalanceKey<phantom T> has store, copy, drop {}

    /// Create an individual account
    public fun new(ctx: &mut TxContext): Account {
        // validate that this user hasn't reached account limit
        Account {
            id: object::new(ctx),
            owner: ctx.sender(),
        }
    }

    /// Deposit funds to an account
    public fun deposit<T>(
        account: &mut Account,
        coin: Coin<T>,
    ) {
        let balance_key = BalanceKey<T> {};
        let balance = coin.into_balance();
        // Check if a balance for this coin type already exists.
        if (df::exists_with_type<BalanceKey<T>, Balance<T>>(&account.id, balance_key)) {
            // If it exists, borrow the existing balance mutably.
            let existing_balance: &mut Balance<T> = df::borrow_mut(&mut account.id, balance_key);
            existing_balance.join(balance);
        } else {
            // If the balance does not exist, add a new dynamic field with the balance.
            df::add(&mut account.id, balance_key, balance);
        }
    }

    /// Withdraw funds from an account
    public fun withdraw<T>(
        account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let balance_key = BalanceKey<T> {};
        // Check if the account has a balance for this coin type
        assert!(df::exists_with_type<BalanceKey<T>, Balance<T>>(&account.id, balance_key), EAccountBalanceTooLow);
        // Borrow the existing balance mutably to split it
        let existing_balance: &mut Balance<T> = df::borrow_mut(&mut account.id, balance_key);
        // Ensure the account has enough of the coin type to withdraw the desired amount
        assert!(existing_balance.value() >= amount, EAccountBalanceTooLow);
        
        existing_balance.split(amount).into_coin(ctx)
    }

    /// Returns the owner of the account
    public fun owner(account: &Account): address {
        account.owner
    }
}
