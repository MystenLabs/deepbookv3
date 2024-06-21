// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The `BalanceManager` is a shared object that holds all of the balances for different assets. Users must pass in
/// a `BalanceManager` to perform trades. The transaction sender is asserted to perform the necessary validation. Capabilities
/// are not used to avoid equivocation.
/// The owner can add traders to the account. Traders can perform the same action as an owner can except for deposits,
/// withdrawals, and addition / removals of traders.
module deepbook::balance_manager {
    // === Imports ===
    use sui::{
        bag::{Self, Bag},
        balance::{Self, Balance},
        coin::Coin,
        vec_set::{Self, VecSet},
    };

    // === Errors ===
    const EInvalidOwner: u64 = 0;
    const EInvalidTrader: u64 = 1;
    const EBalanceManagerBalanceTooLow: u64 = 3;
    const EMaxTraderReached: u64 = 4;
    const ETraderNotInList: u64 = 5;
    const ETraderAlreadyInList: u64 = 6;

    // === Constants ===
    const MAX_TRADERS: u64 = 1000;

    // === Structs ===
    /// A shared object that is passed into pools for placing orders.
    public struct BalanceManager has key {
        id: UID,
        owner: address,
        balances: Bag,
        authorized_traders: VecSet<address>,
    }

    /// Balance identifier.
    public struct BalanceKey<phantom T> has store, copy, drop {}

    // === Public-Mutative Functions ===
    public fun new(ctx: &mut TxContext): BalanceManager {
        BalanceManager {
            id: object::new(ctx),
            owner: ctx.sender(),
            balances: bag::new(ctx),
            authorized_traders: vec_set::empty(),
        }
    }

    #[allow(lint(share_owned))]
    public fun share(balance_manager: BalanceManager) {
        transfer::share_object(balance_manager);
    }

    /// Authorize a trader. Only the owner can authorize.
    public fun authorize_trader(
        balance_manager: &mut BalanceManager,
        authorize_address: address,
        ctx: &mut TxContext
    ) {
        balance_manager.validate_owner(ctx);
        assert!(balance_manager.authorized_traders.size() < MAX_TRADERS, EMaxTraderReached);
        assert!(!balance_manager.authorized_traders.contains(&authorize_address), ETraderAlreadyInList);
        balance_manager.authorized_traders.insert(authorize_address);
    }

    /// Remove an authorized_trader. Only the owner can remove.
    public fun remove_trader(balance_manager: &mut BalanceManager, trader_address: address, ctx: &TxContext) {
        balance_manager.validate_owner(ctx);
        assert!(balance_manager.authorized_traders.contains(&trader_address), ETraderNotInList);
        balance_manager.authorized_traders.remove(&trader_address);
    }

    /// Deposit funds to an balance_manager. Only owner can deposit.
    public fun deposit<T>(
        self: &mut BalanceManager,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        self.validate_owner(ctx);
        self.deposit_protected(coin.into_balance(), ctx);
    }

    /// Withdraw some balance of a single Coin from the balance_manager. Only owner can withdraw.
    public fun withdraw<T>(
        self: &mut BalanceManager,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        self.validate_owner(ctx);

        self.withdraw_protected(withdraw_amount, false, ctx).into_coin(ctx)
    }

    /// Withdraw entire balance of a single Coin from the balance_manager. Only owner can withdraw.
    public fun withdraw_all<T>(
        self: &mut BalanceManager,
        ctx: &mut TxContext,
    ): Coin<T> {
        self.validate_owner(ctx);

        self.withdraw_protected(0, true, ctx).into_coin(ctx)
    }

    // === Public-View Functions ===
    /// Returns the balance of a Coin in the balance_manager.
    public fun balance<T>(balance_manager: &BalanceManager): u64 {
        let key = BalanceKey<T> {};

        if (!balance_manager.balances.contains(key)) {
            0
        } else {
            let acc_balance: &Balance<T> = &balance_manager.balances[key];
            acc_balance.value()
        }
    }

    /// Returns the owner of the balance_manager.
    public fun owner(balance_manager: &BalanceManager): address {
        balance_manager.owner
    }

    /// Returns the owner of the balance_manager.
    public fun id(balance_manager: &BalanceManager): ID {
        balance_manager.id.to_inner()
    }

    // === Public-Package Functions ===
    /// Deposit funds to an balance_manager. Pool will call this to deposit funds.
    public(package) fun deposit_protected<T>(
        self: &mut BalanceManager,
        deposit_balance: Balance<T>,
        ctx: &TxContext,
    ) {
        self.validate_trader(ctx);

        let key = BalanceKey<T> {};
        if (self.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut self.balances[key];
            balance.join(deposit_balance);
        } else {
            self.balances.add(key, deposit_balance);
        }
    }

    /// Withdraw funds from the balance_manager. Pool will call this to withdraw funds.
    public(package) fun withdraw_protected<T>(
        self: &mut BalanceManager,
        withdraw_amount: u64,
        withdraw_all: bool,
        ctx: &TxContext,
    ): Balance<T> {
        self.validate_trader(ctx);

        let key = BalanceKey<T> {};
        let key_exists = self.balances.contains(key);
        if (withdraw_all) {
            if (key_exists) {
                self.balances.remove(key)
            } else {
                balance::zero()
            }
        } else {
            assert!(key_exists, EBalanceManagerBalanceTooLow);
            let acc_balance: &mut Balance<T> = &mut self.balances[key];
            let acc_value = acc_balance.value();
            assert!(acc_value >= withdraw_amount, EBalanceManagerBalanceTooLow);
            if (withdraw_amount == acc_value) {
                self.balances.remove(key)
            } else {
                acc_balance.split(withdraw_amount)
            }
        }
    }

    /// Deletes the balance_manager.
    /// This is used for deleting temporary balance_managers for direct swap with pool.
    public(package) fun delete(balance_manager: BalanceManager) {
        let BalanceManager {
            id,
            owner: _,
            balances,
            authorized_traders: _,
        } = balance_manager;

        id.delete();
        balances.destroy_empty();
    }

    /// Validate that the transaction sender is the owner.
    public(package) fun validate_owner(self: &BalanceManager, ctx: &TxContext) {
        assert!(ctx.sender() == self.owner(), EInvalidOwner);
    }

    /// Validate that the transaction sender is either the owner of a trader.
    public(package) fun validate_trader(self: &BalanceManager, ctx: &TxContext) {
        assert!(
            self.authorized_traders.contains(&ctx.sender()) ||
            ctx.sender() == self.owner(), EInvalidTrader
        );
    }
}
