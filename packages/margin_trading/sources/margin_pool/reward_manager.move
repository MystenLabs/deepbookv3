// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::reward_manager;

use deepbook::math;
use margin_trading::margin_constants;
use std::type_name::TypeName;
use sui::{clock::Clock, table::{Self, Table}};

const EMaxRewardTypesExceeded: u64 = 0;
const ERewardPoolNotFound: u64 = 1;

public struct RewardManager has store {
    reward_pools: vector<RewardPool>,
    user_rewards: Table<address, UserRewards>,
    last_update_time: u64,
}

public struct RewardPool has store {
    reward_token_type: TypeName, // type of the reward token
    cumulative_reward_per_share: u64, // cumulative rewards per share (no scaling)
    emission: Emission,
}

public struct Emission has store {
    end_time: u64,
    rewards_per_second: u64,
}

public struct UserRewards has store {
    positive: vector<u64>,
    negative: vector<u64>,
}

public(package) fun create_reward_manager(clock: &Clock, ctx: &mut TxContext): RewardManager {
    RewardManager {
        reward_pools: vector::empty(),
        user_rewards: table::new(ctx),
        last_update_time: clock.timestamp_ms(),
    }
}

public(package) fun update(self: &mut RewardManager, shares: u64, clock: &Clock) {
    let size = self.reward_pools.length();
    let mut i = 0;
    while (i < size) {
        let reward_pool = &mut self.reward_pools[i];
        let elapsed_time_seconds = elapsed_distribution_time_seconds(reward_pool, clock);
        let rewards_to_distribute = math::mul(
            reward_pool.emission.rewards_per_second,
            elapsed_time_seconds,
        );
        let reward_per_share = math::div(rewards_to_distribute, shares);
        reward_pool.cumulative_reward_per_share =
            reward_pool.cumulative_reward_per_share + reward_per_share;

        i = i + 1;
    };

    self.last_update_time = clock.timestamp_ms();
}

public(package) fun add_reward_pool_entry(self: &mut RewardManager, reward_token_type: TypeName) {
    let existing_pool_index = self.reward_pools.find_index!(|pool| {
        pool.reward_token_type == reward_token_type
    });

    if (existing_pool_index.is_none()) {
        assert!(
            self.reward_pools.length() < margin_constants::max_reward_types(),
            EMaxRewardTypesExceeded,
        );
        let reward_pool = RewardPool {
            reward_token_type,
            cumulative_reward_per_share: 0,
            emission: Emission {
                end_time: 0,
                rewards_per_second: 0,
            },
        };

        self.reward_pools.push_back(reward_pool);
    };
}

public(package) fun increase_emission(
    self: &mut RewardManager,
    reward_token_type: TypeName,
    end_time: u64,
    rewards_per_second: u64,
) {
    let idx = self.type_index(reward_token_type);
    self.reward_pools[idx].emission.end_time = end_time;
    self.reward_pools[idx].emission.rewards_per_second = rewards_per_second;
}

public(package) fun remaining_emission_for_type(
    self: &RewardManager,
    reward_token_type: TypeName,
    clock: &Clock,
): u64 {
    let idx = self.type_index(reward_token_type);

    self.reward_pools[idx].remaining_emission(clock)
}

public(package) fun update_user_shares(
    self: &mut RewardManager,
    user: address,
    shares_before: u64,
    shares_after: u64,
) {
    let user_rewards = self.user_rewards.borrow_mut(user);
    let mut i = 0;
    let size = self.reward_pools.length();
    while (i < size) {
        user_rewards.user_reward_index_entry(i);
        let cumulative_reward_per_share = self.reward_pools[i].cumulative_reward_per_share;

        if (shares_after > shares_before) {
            let positive_reward = &mut user_rewards.positive[i];
            *positive_reward =
                *positive_reward + math::mul(cumulative_reward_per_share, shares_after - shares_before);
        } else {
            let negative_reward = &mut user_rewards.negative[i];
            *negative_reward =
                *negative_reward + math::mul(cumulative_reward_per_share, shares_before - shares_after);
        };
        i = i + 1;
    }
}

public(package) fun reset_user_shares_for_type(
    self: &mut RewardManager,
    user: address,
    reward_token_type: TypeName,
    shares: u64,
): u64 {
    let idx = self.type_index(reward_token_type);
    let user_rewards = self.user_rewards.borrow_mut(user);
    let reward = math::mul(self.reward_pools[idx].cumulative_reward_per_share, shares);
    let returned_reward = reward + user_rewards.negative[idx] - user_rewards.positive[idx];
    insert_swap_remove(&mut user_rewards.positive, idx, reward);
    insert_swap_remove(&mut user_rewards.negative, idx, 0);

    returned_reward
}

public(package) fun index_snapshot(self: &RewardManager): vector<u64> {
    let size = self.reward_pools.length();
    let mut i = 0;
    let mut indices = vector::empty();
    while (i < size) {
        let reward_pool = &self.reward_pools[i];
        let index = reward_pool.cumulative_reward_per_share;
        indices.push_back(index);
        i = i + 1;
    };

    indices
}

fun type_index(self: &RewardManager, reward_token_type: TypeName): u64 {
    let idx = self.reward_pools.find_index!(|pool| {
        pool.reward_token_type == reward_token_type
    });
    assert!(idx.is_some(), ERewardPoolNotFound);

    idx.destroy_some()
}

fun remaining_emission(self: &RewardPool, clock: &Clock): u64 {
    let elapsed_time_seconds = elapsed_distribution_time_seconds(self, clock);
    math::mul(self.emission.rewards_per_second, elapsed_time_seconds)
}

fun elapsed_distribution_time_seconds(reward_pool: &RewardPool, clock: &Clock): u64 {
    if (reward_pool.emission.end_time <= clock.timestamp_ms()) {
        return 0
    };

    (clock.timestamp_ms() - reward_pool.emission.end_time) / 1000
}

fun user_reward_index_entry(user_rewards: &mut UserRewards, reward_index: u64) {
    if (reward_index >= user_rewards.positive.length()) {
        user_rewards.positive.push_back(0);
        user_rewards.negative.push_back(0);
    };
}

fun insert_swap_remove(self: &mut vector<u64>, index: u64, value: u64) {
    self.push_back(value);
    self.swap_remove(index);
}
