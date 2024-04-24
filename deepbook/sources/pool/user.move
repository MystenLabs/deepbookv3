// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The user module manages user data and operations for the current epoch.
/// This includes the user's open orders, maker volume, stake amount, and unclaimed rebates.
/// When the epoch changes, the first user action triggers the necessary calculation for that user
/// for the previous epoch.
module deepbook::user {
    use sui::vec_set::{Self, VecSet};

    public struct User has store {
        user: address,
        last_refresh_epoch: u64,
        open_orders: VecSet<u128>,
        maker_volume: u64,
        stake_amount: u64,
        new_stake_amount: u64,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
    }

    public(package) fun new(user: address): User {
        User {
            user,
            last_refresh_epoch: 0,
            open_orders: vec_set::empty(),
            maker_volume: 0,
            stake_amount: 0,
            new_stake_amount: 0,
            unclaimed_rebates: 0,
            settled_base_amount: 0,
            settled_quote_amount: 0,
        }
    }

    /// Get user's current and next stake amounts.
    public(package) fun stake(user: &User): (u64, u64) {
        (user.stake_amount, user.new_stake_amount)
    }

    /// Refresh user and return burn amount accumulated, if any.
    public(package) fun refresh(user: &mut User, ctx: &TxContext): u64 {
        let current_epoch = ctx.epoch();
        if (user.last_refresh_epoch == current_epoch) return 0;

        let (rebates, burn) = calculate_rebate_and_burn_amounts(user);
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        user.last_refresh_epoch = current_epoch;
        user.maker_volume = 0;
        user.stake_amount = user.new_stake_amount;
        user.new_stake_amount = 0;

        burn
    }

    /// Increase user stake and return the total stake amount.
    /// Validation of amount is done before calling this function.
    public(package) fun increase_stake(user: &mut User, amount: u64): u64 {
        user.new_stake_amount = user.new_stake_amount + amount;

        user.stake_amount + user.new_stake_amount
    }

    // Remove the old and new user stake and return the amounts.
    public(package) fun remove_stake(user: &mut User): (u64, u64) {
        let old_stake = user.stake_amount;
        let new_stake = user.new_stake_amount;
        user.stake_amount = 0;
        user.new_stake_amount = 0;

        (old_stake, new_stake)
    }

    /// Reset unclaimed rebates to 0 and return the amount.
    public(package) fun reset_rebates(user: &mut User): u64 {
        let rebates = user.unclaimed_rebates;
        user.unclaimed_rebates = 0;

        rebates
    }

    /// Given the epoch's volume data and the user's volume data,
    /// calculate the rebate and burn amounts.
    fun calculate_rebate_and_burn_amounts(_user: &User): (u64, u64) {
        // calculate rebates from the current User data
        (0, 0)
    }

    /// Get the user's open orders.
    public(package) fun open_orders(self: &User): VecSet<u128> {
        self.open_orders
    }

    /// Add an open order to User.
    /// Validation of the order is done before calling this function.
    public(package) fun add_open_order(
        self: &mut User,
        order_id: u128,
    ) {
        self.open_orders.insert(order_id);
    }

    /// Remove an open order from User.
    /// Validation of the order is done before calling this function.
    public(package) fun remove_open_order(
        self: &mut User,
        order_id: u128,
    ): u128 {
        self.open_orders.remove(&order_id);

        order_id
    }

    /// Add to the user's settled base amount.
    public(package) fun add_settled_base_amount(
        self: &mut User,
        amount: u64,
    ) {
        self.settled_base_amount = self.settled_base_amount + amount;
    }

    /// Add to the user's settled quote amount.
    public(package) fun add_settled_quote_amount(
        self: &mut User,
        amount: u64,
    ) {
        self.settled_quote_amount = self.settled_quote_amount + amount;
    }
}
