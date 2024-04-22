// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::user {
    use sui::vec_set::{Self, VecSet};

    const EInvalidResetAddress: u64 = 1;

    public struct User has store {
        user: address,
        last_refresh_epoch: u64,
        open_orders: VecSet<u128>,
        maker_volume: u64,
        stake_amount: u64,
        next_stake_amount: u64,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
    }

    public(package) fun new_user(user: address): User {
        User {
            user,
            last_refresh_epoch: 0,
            open_orders: vec_set::empty(),
            maker_volume: 0,
            stake_amount: 0,
            next_stake_amount: 0,
            unclaimed_rebates: 0,
            settled_base_amount: 0,
            settled_quote_amount: 0,
        }
    }

    /// Get user's current and next stake amounts
    public(package) fun stake(user: &User): (u64, u64) {
        (user.stake_amount, user.next_stake_amount)
    }

    /// Refresh user and return burn amount accumulated (if any)
    public(package) fun refresh(user: &mut User, ctx: &TxContext): u64 {
        let current_epoch = ctx.epoch();
        if (user.last_refresh_epoch == current_epoch) return 0;

        let (rebates, burn) = calculate_rebates_and_burn(user);
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        user.last_refresh_epoch = current_epoch;
        user.maker_volume = 0;
        user.stake_amount = user.next_stake_amount;
        user.next_stake_amount = 0;

        burn
    }

    /// Increase user stake and return the new stake amount
    public(package) fun increase_stake(user: &mut User, amount: u64): u64 {
        user.next_stake_amount = user.next_stake_amount + amount;

        user.stake_amount + user.next_stake_amount
    }

    // Remove user stake
    public(package) fun remove_stake(user: &mut User): (u64, u64) {
        let old_stake = user.stake_amount;
        let new_stake = user.next_stake_amount;
        user.stake_amount = 0;
        user.next_stake_amount = 0;

        (old_stake, new_stake)
    }

    /// Return user unclaimed rebates and reset to 0
    public(package) fun reset_rebates(user: &mut User): u64 {
        let rebates = user.unclaimed_rebates;
        user.unclaimed_rebates = 0;

        rebates
    }

    /// Get settled amounts for the user
    public(package) fun settle_amounts(user: &User): (u64, u64) {
        (user.settled_base_amount, user.settled_quote_amount)
    }

    /// Set settled amounts for the user
    public(package) fun set_settle_amounts(
        user: &mut User,
        settled_base_amount: u64,
        settled_quote_amount: u64,
        ctx: &TxContext,
    ) {
        assert!(user.user == ctx.sender(), EInvalidResetAddress);
        user.settled_base_amount = settled_base_amount;
        user.settled_quote_amount = settled_quote_amount;
    }

    // TODO: Function name is not very descriptive, "burn" part is not clear
    /// Returns (rebates, burn) for the user
    fun calculate_rebates_and_burn(_user: &User): (u64, u64) {
        // calculate rebates from the current User data
        (0, 0)
    }

    /// Get user's open orders.
    public(package) fun open_orders(self: &User): VecSet<u128> {
        self.open_orders
    }

    public(package) fun add_open_order(
        self: &mut User,
        order_id: u128,
    ) {
        self.open_orders.insert(order_id);
    }

    public(package) fun remove_open_order(
        self: &mut User,
        order_id: u128,
    ): u128 {
        self.open_orders.remove(&order_id);
        order_id
    }
}
