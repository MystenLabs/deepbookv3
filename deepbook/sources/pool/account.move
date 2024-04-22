// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// TODO: I think it might make more sense to represent ownership by a "Capability",
// instead of by address. That allows for flexible access control (someone could wrap their AccountCap)
// and pass it to others.
// Is this intented to be a shared object or an owned object? Important: You cannot promote owned to shared!

/// The Account is a shared object and holds all of the balances for a user.
/// It is passed into Pools for placing orders. All Pools can desposit and withdraw from the account.
/// When performing security checks, we need to ensure owned objects such as a Capability are not used.
/// Owned objects cause wallets to be locked when trading at a high frequency.
module deepbook::account {
    use sui::{
        bag::{Self, Bag},
        balance::Balance,
        coin::Coin,
    };

    //// The account doesn't have enough funds to be withdrawn.
    const EAccountBalanceTooLow: u64 = 0;
    /// The account doesn't have the balance.
    const ENoBalance: u64 = 1;

    // TODO: use Bag instead of direct dynamic fields
    /// Owned by user, this is what's passed into pools
    public struct Account has key, store {
        id: UID,
        /// The owner of the account.
        owner: address,
        /// Stores the Coin Balances for this account.
        balances: Bag,
    }

    /// Identifier for balance
    public struct BalanceKey<phantom T> has store, copy, drop {}

    /// Create an individual account
    public fun new(ctx: &mut TxContext): Account {
        // validate that this user hasn't reached account limit
        Account {
            id: object::new(ctx),
            owner: ctx.sender(),
            balances: bag::new(ctx),
        }
    }

    /// Deposit funds to an account.
    /// TODO: security checks.
    /// TODO: Pool can deposit.
    public fun deposit<T>(
        account: &mut Account,
        coin: Coin<T>,
    ) {
        let key = BalanceKey<T> {};
        let to_deposit = coin.into_balance();

        if (account.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut account.balances[key];
            balance.join(to_deposit);
        } else {
            account.balances.add(key, to_deposit);
        }
    }

    /// Withdraw funds from an account.
    /// TODO: security checks.
    /// TODO: Pool can withdraw.
    public fun withdraw<T>(
        account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let key = BalanceKey<T> {};
        assert!(account.balances.contains(key), ENoBalance);
        let acc_balance: &mut Balance<T> = &mut account.balances[key];
        assert!(acc_balance.value() >= amount, EAccountBalanceTooLow);

        acc_balance.split(amount).into_coin(ctx)
    }

    /// Returns the owner of the account
    public fun owner(account: &Account): address {
        account.owner
    }
}
