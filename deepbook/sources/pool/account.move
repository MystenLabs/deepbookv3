module deepbook::account {
    use sui::dynamic_field as df;
    use sui::coin::{Self, Coin};
    use sui::balance::{Balance};
    use std::type_name::{Self};
    use std::ascii::{String};

    /// The account doesn't have enough funds to be withdrawn
    const EAccountBalanceTooLow: u64 = 0;

    // Owned by user, this is what's passed into pools
    public struct Account has key, store {
        id: UID,
        owner: address,
        // coin_balances will be represented in dynamic fields
    }
        
    // Identifier for balance
    public struct BalanceKey<phantom T> has store, copy, drop {
        coin_type: String,
    }

    // Create an individual account
    public fun new(ctx: &mut TxContext): Account {
        // validate that this user hasn't reached account limit
        Account {
            id: object::new(ctx),
            owner: ctx.sender(),
        }
    }

    // Deposit funds to an account
    public fun deposit<T>(
        account: &mut Account, 
        coin: Coin<T>,
    ) {
        let coin_type_name = type_name::get<T>().into_string();
        let balance_key = BalanceKey<T> { coin_type: coin_type_name };

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

    // Withdraw funds from an account
    public fun withdraw<T>(
        account: &mut Account, 
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let coin_type_name = type_name::get<T>().into_string();

        let balance_key = BalanceKey<T> { coin_type: coin_type_name };
        // Check if the account has a balance for this coin type
        assert!(df::exists_with_type<BalanceKey<T>, Balance<T>>(&account.id, balance_key), EAccountBalanceTooLow);
        // Borrow the existing balance mutably to split it
        let existing_balance: &mut Balance<T> = df::borrow_mut(&mut account.id, balance_key);
        // Ensure the account has enough of the coin type to withdraw the desired amount
        assert!(existing_balance.value() >= amount, EAccountBalanceTooLow);
        let withdrawn_balance = existing_balance.split(amount);
        // Take a transferable `Coin` from a `Balance`
        coin::from_balance(withdrawn_balance, ctx)
    }

    public fun get_owner(account: &Account): address {
        account.owner   
    }
}