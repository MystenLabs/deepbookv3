// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// TODO: I think it might make more sense to represent ownership by a "Capability",
// instead of by address. That allows for flexible access control (someone could wrap their AccountCap)
// and pass it to others.
// Is this intented to be a shared object or an owned object? Important: You cannot promote owned to shared!

/// The Account is a shared object and holds all of the balances for a user.
/// It is passed into Pools for placing orders.



module deepbook::account {
    use sui::{
        bag::{Self, Bag},
        balance::Balance,
        coin::Coin,
    };

    const EInvalidOwner: u64 = 0;
    const EInvalidTrader: u64 = 1;
    const EInvalidProof: u64 = 2;
    const EAccountBalanceTooLow: u64 = 3;
    const ENoBalance: u64 = 4;
    const EMaxTradeCapsReached: u64 = 5;
    const EUserNotAllowListed: u64 = 6;

    const MAX_TRADE_CAPS: u64 = 10;

    /// A shared object that's passed into Pools for placing orders.
    public struct Account has key {
        id: UID,
        /// The owner of the account.
        owner: address,
        /// Stores the Coin Balances for this account.
        balances: Bag,
        trade_cap_count: u64,
        allow_listed: vector<ID>,
    }

    /// Identifier for balance
    public struct BalanceKey<phantom T> has store, copy, drop {}

    /// Owners of a TradeCap can mint TradeProofs.
    public struct TradeCap has key, store {
        id: UID,
        account_id: ID,
    }

    /// Owner and TradeCap owners can generate a TradeProof.
    /// TradeProof is used to validate the account when trading on DeepBook.
    public struct TradeProof has drop {
        account_id: ID,
    }

    public fun new(ctx: &mut TxContext): Account {
        Account {
            id: object::new(ctx),
            owner: ctx.sender(),
            balances: bag::new(ctx),
            trade_cap_count: 0,
            allow_listed: vector[],
        }
    }

    public fun share(account: Account) {
        transfer::share_object(account);
    }

    /// Mint a TradeCap. Any owner of a TradeCap can mint a TradeProof, 
    /// which is used to validate the account when trading on DeepBook.
    public fun mint_trade_cap(account: &mut Account, ctx: &mut TxContext): TradeCap {
        account.validate_owner(ctx);
        assert!(account.trade_cap_count < MAX_TRADE_CAPS, EMaxTradeCapsReached);

        let id = object::new(ctx);
        account.allow_listed.push_back(id.to_inner());
        account.trade_cap_count = account.trade_cap_count + 1;

        TradeCap {
            id,
            account_id: object::id(account),
        }
    }

    /// Revoke a TradeCap. Only the owner can revoke a TradeCap.
    public fun revoke_trade_cap(account: &mut Account, trade_cap_id: &ID, ctx: &TxContext) {
        account.validate_owner(ctx);
        let mut i = 0;
        let len = account.allow_listed.length();
        while (i < len) {
            if (&account.allow_listed[i] == trade_cap_id) {
                account.allow_listed.swap_remove(i);
                break;
            };
            i = i + 1;
        };

        assert!(i < len, EUserNotAllowListed);

        account.trade_cap_count = account.trade_cap_count - 1;
    }

    /// Generate a TradeProof by the owner. The owner does not pass a capability,
    /// and can generate TradeProofs without the risk of equivocation.
    public fun generate_proof_as_owner(account: &mut Account, ctx: &TxContext): TradeProof {
        account.validate_owner(ctx);

        TradeProof {
            account_id: object::id(account),
        }
    }

    /// Generate a TradeProof with a TradeCap.
    /// Risk of equivocation since TradeCap is an owned object.
    public fun generate_proof_as_trader(account: &mut Account, trade_cap: &TradeCap): TradeProof {
        account.validate_trader(trade_cap);

        TradeProof {
            account_id: object::id(account),
        }
    }

    /// Deposit funds to an account. Only owner can call this directly.
    public fun deposit<T>(
        account: &mut Account,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        let proof = generate_proof_as_owner(account, ctx);

        account.deposit_with_proof(&proof, coin);
    }

    /// Deposit funds to an account. Pool will call this to deposit funds.
    public(package) fun deposit_with_proof<T>(
        account: &mut Account,
        proof: &TradeProof,
        coin: Coin<T>,
    ) {
        proof.validate_proof(account);

        let key = BalanceKey<T> {};
        let to_deposit = coin.into_balance();

        if (account.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut account.balances[key];
            balance.join(to_deposit);
        } else {
            account.balances.add(key, to_deposit);
        }
    }

    /// Withdraw funds from an account. Only owner can call this directly.
    public fun withdraw<T>(
        account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = generate_proof_as_owner(account, ctx);

        account.withdraw_with_proof(&proof, amount, ctx)
    }

    /// Withdraw funds from an account. Pool will call this to withdraw funds.
    public(package) fun withdraw_with_proof<T>(
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        proof.validate_proof(account);

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

    fun validate_owner(account: &Account, ctx: &TxContext) {
        assert!(ctx.sender() == account.owner(), EInvalidOwner);
    }

    fun validate_trader(account: &Account, trade_cap: &TradeCap) {
        assert!(account.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidTrader);
    }

    fun validate_proof(proof: &TradeProof, account: &Account) {
        assert!(object::id(account) == proof.account_id, EInvalidProof);
    }
}
