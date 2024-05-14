// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Account is a shared object that holds all of the balances for a user. A combination of `Account` and
/// `TradeProof` are passed into a pool to perform trades. A `TradeProof` can be generated in two ways: by the
/// owner directly, or by any `TradeCap` owner. The owner can generate a `TradeProof` without the risk of
/// equivocation. The `TradeCap` owner, due to it being an owned object, risks equivocation when generating
/// a `TradeProof`. Generally, a high frequency trading engine will trade as the default owner.
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
    const ETradeCapNotInList: u64 = 6;

    const MAX_TRADE_CAPS: u64 = 1000;

    /// A shared object that is passed into pools for placing orders.
    public struct Account has key {
        id: UID,
        owner: address,
        balances: Bag,
        allow_listed: vector<ID>,
    }

    /// Balance identifier.
    public struct BalanceKey<phantom T> has store, copy, drop {}

    /// Owners of a `TradeCap` need to get a `TradeProof` to trade across pools in a single PTB (drops after).
    public struct TradeCap has key, store {
        id: UID,
        account_id: ID,
    }

    /// Account owner and `TradeCap` owners can generate a `TradeProof`.
    /// `TradeProof` is used to validate the account when trading on DeepBook.
    public struct TradeProof has drop {
        account_id: ID,
        trader: address,
    }

    public fun new(ctx: &mut TxContext): Account {
        Account {
            id: object::new(ctx),
            owner: ctx.sender(),
            balances: bag::new(ctx),
            allow_listed: vector[],
        }
    }

    #[allow(lint(share_owned))]
    public fun share(account: Account) {
        transfer::share_object(account);
    }

    /// Returns the balance of a Coin in an account.
    public fun balance<T>(account: &Account): u64 {
        let key = BalanceKey<T> {};
        if (!account.balances.contains(key)) {
            0
        } else {
            let acc_balance: &Balance<T> = &account.balances[key];
            acc_balance.value()
        }
    }

    /// Mint a `TradeCap`, only owner can mint a `TradeCap`.
    public fun mint_trade_cap(account: &mut Account, ctx: &mut TxContext): TradeCap {
        account.validate_owner(ctx);
        assert!(account.allow_listed.length() < MAX_TRADE_CAPS, EMaxTradeCapsReached);

        let id = object::new(ctx);
        account.allow_listed.push_back(id.to_inner());

        TradeCap {
            id,
            account_id: object::id(account),
        }
    }

    /// Revoke a `TradeCap`. Only the owner can revoke a `TradeCap`.
    public fun revoke_trade_cap(account: &mut Account, trade_cap_id: &ID, ctx: &TxContext) {
        account.validate_owner(ctx);

        let (exists, idx) = account.allow_listed.index_of(trade_cap_id);
        assert!(exists, ETradeCapNotInList);
        account.allow_listed.swap_remove(idx);
    }

    /// Generate a `TradeProof` by the owner. The owner does not require a capability
    /// and can generate TradeProofs without the risk of equivocation.
    public fun generate_proof_as_owner(account: &mut Account, ctx: &TxContext): TradeProof {
        account.validate_owner(ctx);

        TradeProof {
            account_id: object::id(account),
            trader: ctx.sender(),
        }
    }

    /// Generate a `TradeProof` with a `TradeCap`.
    /// Risk of equivocation since `TradeCap` is an owned object.
    public fun generate_proof_as_trader(account: &mut Account, trade_cap: &TradeCap, ctx: &TxContext): TradeProof {
        account.validate_trader(trade_cap);

        TradeProof {
            account_id: object::id(account),
            trader: ctx.sender(),
        }
    }

    /// Deposit funds to an account. Only owner can call this directly.
    public fun deposit<T>(
        account: &mut Account,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        let proof = generate_proof_as_owner(account, ctx);

        account.deposit_with_proof(&proof, coin.into_balance());
    }

    /// Withdraw funds from an account. Only owner can call this directly.
    public fun withdraw<T>(
        account: &mut Account,
        amount: u64,
        withdraw_all: bool,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = generate_proof_as_owner(account, ctx);

        account.withdraw_with_proof(&proof, amount, withdraw_all).into_coin(ctx)
    }

    public fun validate_proof(account: &Account, proof: &TradeProof) {
        assert!(object::id(account) == proof.account_id, EInvalidProof);
    }

    /// Returns the owner of the account.
    public fun owner(account: &Account): address {
        account.owner
    }

    /// Returns the owner of the account.
    public fun id(account: &Account): ID {
        account.id.to_inner()
    }

    /// Deposit funds to an account. Pool will call this to deposit funds.
    public(package) fun deposit_with_proof<T>(
        account: &mut Account,
        proof: &TradeProof,
        to_deposit: Balance<T>,
    ) {
        account.validate_proof(proof);

        let key = BalanceKey<T> {};

        if (account.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut account.balances[key];
            balance.join(to_deposit);
        } else {
            account.balances.add(key, to_deposit);
        }
    }

    /// Withdraw funds from an account. Pool will call this to withdraw funds.
    public(package) fun withdraw_with_proof<T>(
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        withdraw_all: bool,
    ): Balance<T> {
        account.validate_proof(proof);

        let key = BalanceKey<T> {};
        assert!(account.balances.contains(key), ENoBalance);
        let acc_balance: &mut Balance<T> = &mut account.balances[key];
        let value = acc_balance.value();

        if (!withdraw_all) {
            assert!(value >= amount, EAccountBalanceTooLow);
            acc_balance.split(amount)
        } else {
            acc_balance.split(value)
        }
    }

    public(package) fun delete(account: Account) {
        let Account {
            id,
            owner: _,
            balances,
            allow_listed: _,
        } = account;

        id.delete();
        balances.destroy_empty();
    }

    public(package) fun trader(trade_proof: &TradeProof): address {
        trade_proof.trader
    }

    fun validate_owner(account: &Account, ctx: &TxContext) {
        assert!(ctx.sender() == account.owner(), EInvalidOwner);
    }

    fun validate_trader(account: &Account, trade_cap: &TradeCap) {
        assert!(account.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidTrader);
    }
}
