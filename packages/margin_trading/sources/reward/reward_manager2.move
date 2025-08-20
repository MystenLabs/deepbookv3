module margin_trading::reward_manager2;

use deepbook::margin_constants;
use deepbook::math;
use std::type_name::TypeName;
use sui::clock::Clock;
use sui::vec_map::{Self, VecMap};

const EMaxRewardTypesExceeded: u64 = 0;
const ERewardPoolAlreadyExists: u64 = 1;

public struct RewardManager2 has store {
    reward_pools: VecMap<TypeName, RewardPool>,
    last_update_time: u64,
    last_shares: u64,
}

public struct RewardPool has store {
    cumulative_reward_per_share: u64,
    emission: Emission,
}

public struct Emission has store {
    end_time: u64,
    rewards_per_second: u64,
}

public(package) fun default(clock: &Clock): RewardManager2 {
    RewardManager2 {
        reward_pools: vec_map::empty(),
        last_update_time: clock.timestamp_ms(),
        last_shares: 0,
    }
}

/// Given the current total outstanding shares and time elapsed, calculate how much
/// of each reward token has accumulated. Add this amount to the cumulative reward per share.
public(package) fun update(self: &mut RewardManager2, clock: &Clock) {
    let keys = self.reward_pools.keys();
    let last_update_time = self.last_update_time;
    let last_shares = self.last_shares;
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
        reward_pool.update_index(last_shares, elapsed_time_seconds);

        i = i + 1;
    };

    self.last_update_time = clock.timestamp_ms();
}

public(package) fun set_current_shares(self: &mut RewardManager2, shares: u64) {
    self.last_shares = shares;
}

public(package) fun add_reward_pool_entry(
    self: &mut RewardManager2,
    reward_token_type: TypeName,
) {
    assert!(
        self.reward_pools.size() < margin_constants::max_reward_types(),
        EMaxRewardTypesExceeded,
    );
    assert!(!self.reward_pools.contains(&reward_token_type), ERewardPoolAlreadyExists);

    let reward_pool = RewardPool {
        cumulative_reward_per_share: 0,
        emission: Emission {
            end_time: 0,
            rewards_per_second: 0,
        },
    };
    self.reward_pools.insert(reward_token_type, reward_pool);
}

public(package) fun increase_emission(
    self: &mut RewardManager2,
    reward_token_type: TypeName,
    end_time: u64,
    rewards_per_second: u64,
) {
    let reward_pool = &mut self.reward_pools[&reward_token_type];
    reward_pool.emission.end_time = end_time;
    reward_pool.emission.rewards_per_second = rewards_per_second;
}

fun update_index(self: &mut RewardPool, shares: u64, time_elapsed_seconds: u64) {
    let rewards_to_distribute = math::mul(self.emission.rewards_per_second, time_elapsed_seconds);
    if (shares > 0) {
        let reward_per_share = math::div(rewards_to_distribute, shares);
        self.cumulative_reward_per_share = self.cumulative_reward_per_share + reward_per_share;
    };
}

fun elapsed_distribution_time_seconds(last_update_time: u64, end_time: u64, clock: &Clock): u64 {
    if (end_time <= clock.timestamp_ms()) {
        return 0
    };

    (clock.timestamp_ms() - last_update_time) / 1000
}
