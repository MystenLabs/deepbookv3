// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module manages pool volumes and fees as well as the individual user volume and orders.
/// Functions that mutate the state manager will refresh the Fees and Volumes to the current epoch.
/// Functions that mutate the invdividual user will refresh the user's data, calculating the
/// rebates and burns for the previous epoch.
/// It is guaranteed that the user's will not be refreshed before the state is refreshed.
module deepbook::state_manager {
    use sui::{
        table::{Self, Table},
        vec_set::{Self, VecSet},
    };

    const EUserNotFound: u64 = 1;
    
    /// Parameters that can be updated by governance.
    public struct TradeParams has store, copy, drop {
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    }

    /// Overall volumes for the current epoch. Used to calculate rebates and burns.
    public struct Volumes has store, copy, drop {
        total_maker_volume: u64,
        total_staked_maker_volume: u64,
        total_fees_collected: u64,
    }

    /// User data that is updated every epoch.
    public struct User has store, copy, drop {
        epoch: u64,
        open_orders: VecSet<u128>,
        maker_volume: u64,
        old_stake: u64,
        new_stake: u64,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
    }

    public struct StateManager has store {
        epoch: u64,
        fees: TradeParams,
        next_fees: TradeParams,
        volumes: Volumes,
        historic_volumes: Table<u64, Volumes>,
        users: Table<address, User>,
        balance_to_burn: u64,
    }

    public(package) fun new_trade_params(
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
    ): TradeParams {
        TradeParams {
            taker_fee,
            maker_fee,
            stake_required,
        }
    }

    public(package) fun new(
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ): StateManager {
        let fees = new_trade_params(taker_fee, maker_fee, stake_required);
        let next_fees = new_trade_params(taker_fee, maker_fee, stake_required);
        let volumes = Volumes {
            total_maker_volume: 0,
            total_staked_maker_volume: 0,
            total_fees_collected: 0,
        };
        StateManager {
            epoch: ctx.epoch(),
            fees,
            next_fees,
            volumes,
            historic_volumes: table::new(ctx),
            users: table::new(ctx),
            balance_to_burn: 0,
        }
    }

    /// Refresh the state manager to the current epoch.
    public(package) fun refresh(
        self: &mut StateManager,
        epoch: u64,
    ) {
        if (self.epoch == epoch) return;
        self.historic_volumes.add(self.epoch, self.volumes);
        self.fees = self.next_fees;
        self.epoch = epoch;
    }

    /// Set the fee parameters for the next epoch. Pushed by governance.
    public(package) fun set_next_fees(
        self: &mut StateManager,
        fees: Option<TradeParams>,
    ) {
        if (fees.is_some()) {
            self.next_fees = *fees.borrow();
        } else {
            self.next_fees = self.fees;
        }
    }
    
    /// Get the total maker volume for the current epoch.
    public(package) fun maker_fee(self: &StateManager, epoch: u64): u64 {
        if (self.epoch == epoch) {
            self.fees.maker_fee
        } else {
            self.next_fees.maker_fee
        }
    }

    /// Taker fee for a user. If the user has enough stake and has traded a certain amount of volume,
    /// the taker fee is halved.
    public(package) fun taker_fee_for_user(
        self: &mut StateManager,
        user: address,
    ): u64 {
        let user = update_user(self, user);
        // TODO: user has to trade a certain amount of volume first
        if (user.old_stake >= self.fees.stake_required) {
            self.fees.taker_fee / 2
        } else {
            self.fees.taker_fee
        }
    }

    /// Get the total maker volume for the current epoch.
    public(package) fun stake_required(self: &StateManager, epoch: u64): u64 {
        if (self.epoch == epoch) {
            self.fees.stake_required
        } else {
            self.next_fees.stake_required
        }
    }

    /// Reset the burn balance to 0, return the amount.
    public(package) fun reset_burn_balance(self: &mut StateManager): u64 {
        let amount = self.balance_to_burn;
        self.balance_to_burn = 0;

        amount
    }

    /// Get the users old_stake and new_stake, where old_stake is the amount staked before
    /// the current epoch and new_stake is the amount staked in the current epoch.
    public(package) fun user_stake(
        self: &StateManager,
        user: address,
        epoch: u64
    ): (u64, u64) {
        if (!self.users.contains(user)) return (0, 0);
        
        let user = self.users[user];
        if (user.epoch == epoch) {
            (user.old_stake, user.new_stake)
        } else {
            (user.old_stake + user.new_stake, 0)
        }
    }

    /// Increase user stake. Return old and new stake.
    public(package) fun increase_user_stake(
        self: &mut StateManager,
        user: address,
        amount: u64,
    ): (u64, u64) {
        let user = update_user(self, user);
        user.new_stake = user.new_stake + amount;

        (user.old_stake, user.new_stake)
    }

    /// Remove user stake. Return old and new stake.
    public(package) fun remove_user_stake(
        self: &mut StateManager,
        user: address,
    ): (u64, u64) {
        let user = update_user(self, user);
        let (old_stake, new_stake) = (user.old_stake, user.new_stake);
        user.old_stake = 0;
        user.new_stake = 0;

        (old_stake, new_stake)
    }

    /// Set rebates for user to 0. Return the new unclaimed rebates.
    public(package) fun reset_user_rebates(
        self: &mut StateManager,
        user: address,
    ): u64 {
        let user = update_user(self, user);
        let rebates = user.unclaimed_rebates;
        user.unclaimed_rebates = 0;

        rebates
    }

    /// All of the user's open orders.
    public(package) fun user_open_orders(
        self: &StateManager,
        user: address,
    ): VecSet<u128> {
        if (!self.users.contains(user)) return vec_set::empty();

        self.users[user].open_orders
    }

    /// Add an open order to the user.
    public(package) fun add_user_open_order(
        self: &mut StateManager,
        user: address,
        order_id: u128,
    ) {
        let user = update_user(self, user);
        user.open_orders.insert(order_id);
    }

    /// Remove an open order from the user.
    public(package) fun remove_user_open_order(
        self: &mut StateManager,
        user: address,
        order_id: u128,
    ) {
        assert!(self.users.contains(user), EUserNotFound);

        let user = update_user(self, user);
        user.open_orders.remove(&order_id);
    }

    /// Increase the user's settled amount. Happens when a maker order is filled.
    public(package) fun add_user_settled_amount(
        self: &mut StateManager,
        user: address,
        amount: u64,
        base: bool,
    ) {
        let user = update_user(self, user);
        if (base) {
            user.settled_base_amount = user.settled_base_amount + amount;
        } else {
            user.settled_quote_amount = user.settled_quote_amount + amount;
        }
    }

    public(package) fun reset_user_settled_amounts(
        self: &mut StateManager,
        user: address,
    ): (u64, u64) {
        let user = update_user(self, user);
        let (base_amount, quote_amount) = (user.settled_base_amount, user.settled_quote_amount);
        user.settled_base_amount = 0;
        user.settled_quote_amount = 0;

        (base_amount, quote_amount)
    }

    /// Increase maker volume for the user.
    /// Increase the total maker volume.
    /// If the user has enough stake, increase the total staked maker volume.
    public(package) fun increase_maker_volume(
        self: &mut StateManager,
        user: address,
        volume: u64,
    ) {
        let user = update_user(self, user);
        user.maker_volume = user.maker_volume + volume;
        
        if (user.old_stake >= self.fees.stake_required) {
            self.volumes.total_staked_maker_volume = self.volumes.total_staked_maker_volume + volume;
        };
        self.volumes.total_maker_volume = self.volumes.total_maker_volume + volume;
    }

    /// Add new user or refresh an existing user.
    public(package) fun update_user(
        self: &mut StateManager,
        user: address,
    ): &mut User {
        let epoch = self.epoch;
        add_new_user_if_not_exist(self, user, epoch);

        let user = &mut self.users[user];
        if (user.epoch == epoch) return user;
        
        let (rebates, burns) = calculate_rebate_and_burn_amounts(user);
        user.epoch = epoch;
        user.maker_volume = 0;
        user.old_stake = user.old_stake + user.new_stake;
        user.new_stake = 0;
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        self.balance_to_burn = self.balance_to_burn + burns;

        user
    }

    fun add_new_user_if_not_exist(
        self: &mut StateManager,
        user: address,
        epoch: u64,
    ) {
        if (!self.users.contains(user)) {
            self.users.add(user, User {
                epoch,
                open_orders: vec_set::empty(),
                maker_volume: 0,
                old_stake: 0,
                new_stake: 0,
                unclaimed_rebates: 0,
                settled_base_amount: 0,
                settled_quote_amount: 0,
            });
        };
    }

    /// Given the epoch's volume data and the user's volume data,
    /// calculate the rebate and burn amounts.
    fun calculate_rebate_and_burn_amounts(_user: &User): (u64, u64) {
        // calculate rebates from the current User data
        (0, 0)
    }
}
