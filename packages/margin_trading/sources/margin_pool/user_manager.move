module margin_trading::user_manager;

use deepbook::math;
use margin_trading::reward_manager::RewardPool;
use std::type_name::TypeName;
use sui::{table::{Self, Table}, vec_map::{Self, VecMap}};

public struct UserManager has store {
    users: Table<address, User>,
}

public struct User has store {
    loan_shares: u64,
    supply_shares: u64,
    rewards: VecMap<TypeName, RewardTracker>,
}

public struct RewardTracker has store {
    positive: u64,
    negative: u64,
}

public(package) fun create_user_manager(ctx: &mut TxContext): UserManager {
    UserManager {
        users: table::new(ctx),
    }
}

public(package) fun increase_user_supply_shares(
    self: &mut UserManager,
    user: address,
    supply_shares: u64,
    reward_pools: &VecMap<TypeName, RewardPool>,
) {
    self.add_user_entry(user);
    let user = self.users.borrow_mut(user);
    let supply_shares_before = user.supply_shares;
    user.supply_shares = user.supply_shares + supply_shares;
    user.update_user_reward_shares(reward_pools, supply_shares_before, supply_shares);
}

public(package) fun decrease_user_supply_shares(
    self: &mut UserManager,
    user: address,
    supply_shares: u64,
    reward_pools: &VecMap<TypeName, RewardPool>,
) {
    self.add_user_entry(user);
    let user = self.users.borrow_mut(user);
    let supply_shares_before = user.supply_shares;
    user.supply_shares = user.supply_shares - supply_shares;
    user.update_user_reward_shares(reward_pools, supply_shares_before, supply_shares);
}

public(package) fun increase_user_loan_shares(
    self: &mut UserManager,
    user: address,
    loan_shares: u64,
) {
    self.add_user_entry(user);
    let user = self.users.borrow_mut(user);
    user.loan_shares = user.loan_shares + loan_shares;
}

public(package) fun decrease_user_loan_shares(
    self: &mut UserManager,
    user: address,
    loan_shares: u64,
) {
    let user = self.users.borrow_mut(user);
    user.loan_shares = user.loan_shares - loan_shares;
}

public(package) fun user_supply_shares(self: &UserManager, user: address): u64 {
    self.users.borrow(user).supply_shares
}

public(package) fun user_loan_shares(self: &UserManager, user: address): u64 {
    self.users.borrow(user).loan_shares
}

public(package) fun reset_user_rewards_for_type(
    self: &mut UserManager,
    user: address,
    reward_token_type: TypeName,
    reward_pools: &VecMap<TypeName, RewardPool>,
    shares: u64,
): u64 {
    self.add_user_entry(user);
    let user = self.users.borrow_mut(user);
    let reward_index = reward_pools[&reward_token_type].cumulative_reward_per_share();
    user.user_reward_entry(shares, reward_index, reward_token_type);

    let reward = math::mul(reward_index, shares);
    let returned_reward =
        reward + user.rewards[&reward_token_type].negative - user.rewards[&reward_token_type].positive;
    user.rewards[&reward_token_type].positive = reward;
    user.rewards[&reward_token_type].negative = 0;

    returned_reward
}

fun user_reward_entry(
    self: &mut User,
    current_shares: u64,
    current_index: u64,
    reward_token_type: TypeName,
) {
    if (!self.rewards.contains(&reward_token_type)) {
        self
            .rewards
            .insert(
                reward_token_type,
                RewardTracker {
                    positive: math::mul(current_index, current_shares),
                    negative: 0,
                },
            );
    }
}

fun update_user_reward_shares(
    user: &mut User,
    reward_pools: &VecMap<TypeName, RewardPool>,
    shares_before: u64,
    shares_after: u64,
) {
    let keys = reward_pools.keys();
    let size = keys.length();
    let mut i = 0;
    while (i < size) {
        let key = keys[i];
        let reward_pool = &reward_pools[&key];
        let cumulative_reward_per_share = reward_pool.cumulative_reward_per_share();
        let reward_tracker = &mut user.rewards[&key];
        let reward_addition = &mut reward_tracker.positive;
        let reward_subtraction = &mut reward_tracker.negative;
        if (shares_after > shares_before) {
            *reward_addition =
                *reward_addition + math::mul(cumulative_reward_per_share, shares_after - shares_before);
        } else {
            *reward_subtraction =
                *reward_subtraction + math::mul(cumulative_reward_per_share, shares_before - shares_after);
        };
        i = i + 1;
    }
}

fun add_user_entry(self: &mut UserManager, user: address) {
    if (!self.users.contains(user)) {
        self
            .users
            .add(
                user,
                User {
                    loan_shares: 0,
                    supply_shares: 0,
                    rewards: vec_map::empty(),
                },
            );
    }
}
