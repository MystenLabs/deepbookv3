// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The BalanceManager is a shared object that holds all of the balances for different assets. A combination of `BalanceManager` and
/// `TradeProof` are passed into a pool to perform trades. A `TradeProof` can be generated in two ways: by the
/// owner directly, or by any `TradeCap` owner. The owner can generate a `TradeProof` without the risk of
/// equivocation. The `TradeCap` owner, due to it being an owned object, risks equivocation when generating
/// a `TradeProof`. Generally, a high frequency trading engine will trade as the default owner.
module deepbook::balance_manager {
    use sui::{
        bag::{Self, Bag},
        balance::{Self, Balance},
        coin::Coin,
        vec_set::{Self, VecSet},
    };

    const EInvalidOwner: u64 = 0;
    const EInvalidTrader: u64 = 1;
    const EInvalidProof: u64 = 2;
    const EBalanceManagerBalanceTooLow: u64 = 3;
    const EMaxTraderReached: u64 = 4;
    const ETraderNotInList: u64 = 5;

    const MAX_TRADERS: u64 = 1000;

    /// A shared object that is passed into pools for placing orders.
    public struct BalanceManager has key {
        id: UID,
        owner: address,
        balances: Bag,
        allow_list: VecSet<address>,
    }

    /// Balance identifier.
    public struct BalanceKey<phantom T> has store, copy, drop {}

    /// BalanceManager owner and `TradeCap` owners can generate a `TradeProof`.
    /// `TradeProof` is used to validate the balance_manager when trading on DeepBook.
    public struct TradeProof has drop {
        balance_manager_id: ID,
        trader: address,
    }

    public fun new(ctx: &mut TxContext): BalanceManager {
        BalanceManager {
            id: object::new(ctx),
            owner: ctx.sender(),
            balances: bag::new(ctx),
            allow_list: vec_set::empty(),
        }
    }

    #[allow(lint(share_owned))]
    public fun share(balance_manager: BalanceManager) {
        transfer::share_object(balance_manager);
    }

    /// Returns the balance of a Coin in an balance_manager.
    public fun balance<T>(balance_manager: &BalanceManager): u64 {
        let key = BalanceKey<T> {};
        if (!balance_manager.balances.contains(key)) {
            0
        } else {
            let acc_balance: &Balance<T> = &balance_manager.balances[key];
            acc_balance.value()
        }
    }

    /// Mint a `TradeCap`, only owner can mint a `TradeCap`.
    public fun authorize_trader(
        balance_manager: &mut BalanceManager,
        authorize_address: address,
        ctx: &mut TxContext
    ) {
        balance_manager.validate_owner(ctx);
        assert!(balance_manager.allow_list.size() < MAX_TRADERS, EMaxTraderReached);

        balance_manager.allow_list.insert(authorize_address);
    }

    /// Revoke a `TradeCap`. Only the owner can revoke a `TradeCap`.
    public fun remove_trader(balance_manager: &mut BalanceManager, trader_address: address, ctx: &TxContext) {
        balance_manager.validate_owner(ctx);

        assert!(balance_manager.allow_list.contains(&trader_address), ETraderNotInList);
        balance_manager.allow_list.remove(&trader_address);
    }

    /// Generate a `TradeProof` by the owner
    public fun generate_proof_as_owner(balance_manager: &mut BalanceManager, ctx: &TxContext): TradeProof {
        balance_manager.validate_owner(ctx);

        TradeProof {
            balance_manager_id: object::id(balance_manager),
            trader: ctx.sender(),
        }
    }

    /// Generate a `TradeProof` by the trader
    public fun generate_proof_as_trader(balance_manager: &mut BalanceManager, ctx: &TxContext): TradeProof {
        balance_manager.validate_trader(ctx);

        TradeProof {
            balance_manager_id: object::id(balance_manager),
            trader: ctx.sender(),
        }
    }

    /// Deposit funds to an balance_manager. Only owner can call this directly.
    public fun deposit<T>(
        balance_manager: &mut BalanceManager,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        let proof = generate_proof_as_owner(balance_manager, ctx);

        balance_manager.deposit_with_proof(&proof, coin.into_balance());
    }

    /// Withdraw funds from an balance_manager. Only owner can call this directly.
    /// If withdraw_all is true, amount is ignored and full balance withdrawn.
    /// If withdraw_all is false, withdraw_amount will be withdrawn.
    public fun withdraw<T>(
        balance_manager: &mut BalanceManager,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = generate_proof_as_owner(balance_manager, ctx);

        balance_manager.withdraw_with_proof(&proof, withdraw_amount, false).into_coin(ctx)
    }

    public fun withdraw_all<T>(
        balance_manager: &mut BalanceManager,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = generate_proof_as_owner(balance_manager, ctx);

        balance_manager.withdraw_with_proof(&proof, 0, true).into_coin(ctx)
    }

    public fun validate_proof(balance_manager: &BalanceManager, proof: &TradeProof) {
        assert!(object::id(balance_manager) == proof.balance_manager_id, EInvalidProof);
    }

    /// Returns the owner of the balance_manager.
    public fun owner(balance_manager: &BalanceManager): address {
        balance_manager.owner
    }

    /// Returns the owner of the balance_manager.
    public fun id(balance_manager: &BalanceManager): ID {
        balance_manager.id.to_inner()
    }

    /// Deposit funds to an balance_manager. Pool will call this to deposit funds.
    public(package) fun deposit_with_proof<T>(
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        to_deposit: Balance<T>,
    ) {
        balance_manager.validate_proof(proof);

        let key = BalanceKey<T> {};

        if (balance_manager.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut balance_manager.balances[key];
            balance.join(to_deposit);
        } else {
            balance_manager.balances.add(key, to_deposit);
        }
    }

    /// Withdraw funds from an balance_manager. Pool will call this to withdraw funds.
    public(package) fun withdraw_with_proof<T>(
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        withdraw_amount: u64,
        withdraw_all: bool,
    ): Balance<T> {
        balance_manager.validate_proof(proof);

        let key = BalanceKey<T> {};
        let key_exists = balance_manager.balances.contains(key);
        if (withdraw_all) {
            if (key_exists) {
                balance_manager.balances.remove(key)
            } else {
                balance::zero()
            }
        } else {
            assert!(key_exists, EBalanceManagerBalanceTooLow);
            let acc_balance: &mut Balance<T> = &mut balance_manager.balances[key];
            let acc_value = acc_balance.value();
            assert!(acc_value >= withdraw_amount, EBalanceManagerBalanceTooLow);
            if (withdraw_amount == acc_value) {
                balance_manager.balances.remove(key)
            } else {
                acc_balance.split(withdraw_amount)
            }
        }
    }

    /// Deletes an balance_manager.
    /// This is used for deleting temporary balance_managers for direct swap with pool.
    public(package) fun delete(balance_manager: BalanceManager) {
        let BalanceManager {
            id,
            owner: _,
            balances,
            allow_list: _,
        } = balance_manager;

        id.delete();
        balances.destroy_empty();
    }

    public(package) fun trader(trade_proof: &TradeProof): address {
        trade_proof.trader
    }

    fun validate_owner(balance_manager: &BalanceManager, ctx: &TxContext) {
        assert!(ctx.sender() == balance_manager.owner(), EInvalidOwner);
    }

    fun validate_trader(balance_manager: &BalanceManager, ctx: &TxContext) {
        assert!(balance_manager.allow_list.contains(&ctx.sender()), EInvalidTrader);
    }
}
