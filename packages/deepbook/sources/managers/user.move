module deepbook::v3user_manager {
    use sui::{
        table::{Self, Table},
        vec_set::{Self, VecSet},
    };

    /// User data that is updated every epoch.
    public struct User has store, copy, drop {
        epoch: u64,
        open_orders: VecSet<u128>,
        maker_volume: u64,
        old_stake: u64,
        new_stake: u64,
        voted_proposal: Option<address>,
        unclaimed_rebates: u64,
        settled_base_amount: u64,
        settled_quote_amount: u64,
        settled_deep_amount: u64,
    }

    public struct UserManager has store {
        users: Table<address, User>,
    }


    fun update_user(
        self: &mut StateManager,
        user: address,
    ): &mut User {
        let epoch = self.epoch;
        add_new_user(self, user, epoch);
        self.decrement_users_with_rebates(user, epoch);

        let user = &mut self.users[user];
        if (user.epoch == epoch) return user;
        let (rebates, burns) = calculate_rebate_and_burn_amounts(user);
        user.epoch = epoch;
        user.maker_volume = 0;
        user.old_stake = user.old_stake + user.new_stake;
        user.new_stake = 0;
        user.unclaimed_rebates = user.unclaimed_rebates + rebates;
        self.balance_to_burn = self.balance_to_burn + burns;
        user.voted_proposal = option::none();

        user
    }
    
    fun add_new_user(
        self: &mut UserManager,
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
                voted_proposal: option::none(),
                unclaimed_rebates: 0,
                settled_base_amount: 0,
                settled_quote_amount: 0,
                settled_deep_amount: 0,
            });
        };
    }
}