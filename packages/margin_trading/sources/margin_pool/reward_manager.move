// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Reward manager is responsible for managing the rewards per total shares.
module margin_trading::reward_manager;

use deepbook::math;
use margin_trading::margin_constants;
use std::type_name::TypeName;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

const EMaxRewardTypesExceeded: u64 = 0;

public struct RewardManager has store {
    reward_pools: VecMap<TypeName, RewardPool>,
    last_update_shares: u64,
    last_update_time: u64,
}

public struct RewardPool has store {
    cumulative_reward_per_share: u64, // cumulative rewards per share (no scaling)
    emission: Emission,
}

public struct Emission has store {
    end_time: u64,
    rewards_per_second: u64,
}

public(package) fun create_reward_manager(clock: &Clock): RewardManager {
    RewardManager {
        reward_pools: vec_map::empty(),
        last_update_time: clock.timestamp_ms(),
    }
}

/// Given the current total outstanding shares and time elapsed, calculate how much
/// of each reward token has accumulated. Add this amount to the cumulative reward per share.
public(package) fun update(self: &mut RewardManager, shares: u64, clock: &Clock) {
    let keys = self.reward_pools.keys();
    let last_update_time = self.last_update_time;
    let size = keys.length();
    let mut i = 0;
    while (i < size) {
        let key = keys[i];
        let reward_pool = &mut self.reward_pools[&key];
        let elapsed_time_seconds = elapsed_distribution_time_seconds(
            last_update_time,
            reward_pool.emission.end_time,
            clock,
        );
        let rewards_to_distribute = math::mul(
            reward_pool.emission.rewards_per_second,
            elapsed_time_seconds,
        );
        if (self.last_update_shares > 0) {
            let reward_per_share = math::div(rewards_to_distribute, self.last_update_shares);
            reward_pool.cumulative_reward_per_share =
                reward_pool.cumulative_reward_per_share + reward_per_share;
        };

        i = i + 1;
    };

    self.last_update_time = clock.timestamp_ms();
    self.last_update_shares = shares;
}

/// Add a reward pool entry for a given reward token type.
public(package) fun add_reward_pool_entry(self: &mut RewardManager, reward_token_type: TypeName) {
    if (self.reward_pools.contains(&reward_token_type)) {
        return
    };

    assert!(
        self.reward_pools.size() < margin_constants::max_reward_types(),
        EMaxRewardTypesExceeded,
    );
    let reward_pool = RewardPool {
        cumulative_reward_per_share: 0,
        emission: Emission {
            end_time: 0,
            rewards_per_second: 0,
        },
    };
    self.reward_pools.insert(reward_token_type, reward_pool);
}

/// Increase the emission of a given reward token type.
public(package) fun increase_emission(
    self: &mut RewardManager,
    reward_token_type: TypeName,
    end_time: u64,
    rewards_per_second: u64,
) {
    let reward_pool = &mut self.reward_pools[&reward_token_type];
    reward_pool.emission.end_time = end_time;
    reward_pool.emission.rewards_per_second = rewards_per_second;
}

/// Get the remaining emission for a given reward token type.
public(package) fun remaining_emission_for_type(
    self: &RewardManager,
    reward_token_type: TypeName,
    clock: &Clock,
): u64 {
    if (!self.reward_pools.contains(&reward_token_type)) {
        return 0
    };

    let reward_pool = &self.reward_pools[&reward_token_type];

    reward_pool.remaining_emission(clock)
}

public(package) fun reward_pools(self: &RewardManager): &VecMap<TypeName, RewardPool> {
    &self.reward_pools
}

public(package) fun cumulative_reward_per_share(self: &RewardPool): u64 {
    self.cumulative_reward_per_share
}

fun remaining_emission(self: &RewardPool, clock: &Clock): u64 {
    if (self.emission.end_time <= clock.timestamp_ms()) {
        return 0
    };

    let remaining_time_seconds = (self.emission.end_time - clock.timestamp_ms()) / 1000;
    math::mul(self.emission.rewards_per_second, remaining_time_seconds)
}

fun elapsed_distribution_time_seconds(last_update_time: u64, end_time: u64, clock: &Clock): u64 {
    if (end_time <= clock.timestamp_ms()) {
        return 0
    };

    (clock.timestamp_ms() - last_update_time) / 1000
}
