// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::reward_pool;

use deepbook::math;
use margin_trading::margin_constants;
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};

// === Errors ===
const EInvalidRewardPeriod: u64 = 1;
const ERewardAmountTooSmall: u64 = 2;
const ERewardPeriodTooShort: u64 = 3;

// === Structs ===
public struct RewardPool has store {
    reward_token_type: TypeName, // type of the reward token
    total_rewards: u64, // total reward amount for this pool
    start_time: u64, // when rewards start distributing (seconds)
    end_time: u64, // when rewards stop distributing (seconds)
    rewards_per_second: u64, // reward distributed per second
    cumulative_reward_per_share: u64, // cumulative rewards per share (no scaling)
    last_update_time: u64, // last time this pool was updated (seconds)
}

public struct UserRewardInfo has store {
    accumulated_rewards: u64, // tracks user's accumulated rewards for this token type
    last_cumulative_reward_per_share: u64, // tracks user's last cumulative_reward_per_share checkpoint for this token type
}

public struct UserRewards has store {
    rewards_by_token: VecMap<TypeName, UserRewardInfo>, // maps token type to reward info
}

public struct RewardPoolAdded has copy, drop {
    pool_id: ID,
    reward_token_type: TypeName,
    total_rewards: u64,
    start_time: u64,
    end_time: u64,
}

public struct RewardsClaimed has copy, drop {
    pool_id: ID,
    typename: TypeName,
    user: address,
    amount: u64,
}

// === Public(package) Functions ===
public(package) fun create_reward_pool<RewardToken>(
    reward_amount: u64,
    end_time: u64,
    clock: &Clock,
): RewardPool {
    let start_time = clock.timestamp_ms() / 1000;
    assert!(start_time < end_time, EInvalidRewardPeriod);

    let duration = end_time - start_time;
    let rewards_per_second = reward_amount / duration;
    assert!(rewards_per_second > 0, ERewardAmountTooSmall);
    assert!(duration >= margin_constants::min_reward_duration_seconds(), ERewardPeriodTooShort);

    let reward_token_type = type_name::get<RewardToken>();
    let reward_pool = RewardPool {
        reward_token_type,
        total_rewards: reward_amount,
        start_time,
        end_time,
        rewards_per_second,
        cumulative_reward_per_share: 0,
        last_update_time: start_time,
    };

    reward_pool
}

public(package) fun create_user_rewards(): UserRewards {
    UserRewards {
        rewards_by_token: vec_map::empty(),
    }
}

public(package) fun initialize_user_reward_for_type(
    user_rewards: &mut UserRewards,
    reward_type: TypeName,
    cumulative_reward_per_share: u64,
) {
    if (!user_rewards.rewards_by_token.contains(&reward_type)) {
        user_rewards
            .rewards_by_token
            .insert(
                reward_type,
                UserRewardInfo {
                    accumulated_rewards: 0,
                    last_cumulative_reward_per_share: cumulative_reward_per_share,
                },
            );
    };
}

public(package) fun update_reward_pool(
    reward_pool: &mut RewardPool,
    total_supply: u64,
    clock: &Clock,
) {
    if (total_supply == 0) {
        return
    };

    let current_time = clock.timestamp_ms() / 1000;
    // Cap end_time at current_time, but it can be less than current_time if rewards have ended
    let end_time = reward_pool.end_time.min(current_time);

    if (end_time <= reward_pool.last_update_time) {
        return
    };

    let elapsed_time = end_time - reward_pool.last_update_time;

    let rewards_to_distribute = reward_pool.rewards_per_second * elapsed_time;
    let reward_per_share = math::div(rewards_to_distribute, total_supply);

    reward_pool.cumulative_reward_per_share =
        reward_pool.cumulative_reward_per_share + reward_per_share;
    reward_pool.last_update_time = current_time;
}

/// Updates user's accumulated rewards for a specific reward token type
public(package) fun update_user_accumulated_rewards_by_type(
    user_rewards: &mut UserRewards,
    reward_type: TypeName,
    cumulative_reward_per_share: u64,
    user_supply: u64,
) {
    if (!user_rewards.rewards_by_token.contains(&reward_type)) {
        user_rewards
            .rewards_by_token
            .insert(
                reward_type,
                UserRewardInfo {
                    accumulated_rewards: 0,
                    last_cumulative_reward_per_share: 0,
                },
            );
    };

    let reward_info = user_rewards.rewards_by_token.get_mut(&reward_type);

    // Calculate rewards since last checkpoint
    let reward_per_share_diff =
        cumulative_reward_per_share - reward_info.last_cumulative_reward_per_share;
    let incremental_rewards = math::mul(user_supply, reward_per_share_diff);

    reward_info.accumulated_rewards = reward_info.accumulated_rewards + incremental_rewards;
    reward_info.last_cumulative_reward_per_share = cumulative_reward_per_share;
}

/// Adds new rewards to an existing reward pool and resets the timing
/// All existing rewards (both accrued and unaccrued) are combined with new rewards
/// and redistributed over the new time period
public(package) fun add_rewards_and_reset_timing(
    reward_pool: &mut RewardPool,
    existing_balance: u64,
    new_reward_amount: u64,
    end_time: u64,
    clock: &Clock,
) {
    let start_time = clock.timestamp_ms() / 1000;
    let duration = end_time - start_time;
    assert!(new_reward_amount >= margin_constants::min_reward_amount(), ERewardAmountTooSmall);
    assert!(duration >= margin_constants::min_reward_duration_seconds(), ERewardPeriodTooShort);

    let total_combined_rewards = existing_balance + new_reward_amount;
    reward_pool.total_rewards = total_combined_rewards;
    reward_pool.start_time = start_time;
    reward_pool.end_time = end_time;
    reward_pool.rewards_per_second = total_combined_rewards / duration;
    reward_pool.last_update_time = start_time;
}

/// Destroys a reward pool
public(package) fun destroy_reward_pool(reward_pool: RewardPool) {
    let RewardPool {
        reward_token_type: _,
        total_rewards: _,
        start_time: _,
        end_time: _,
        rewards_per_second: _,
        cumulative_reward_per_share: _,
        last_update_time: _,
    } = reward_pool;
}

/// Emits a RewardPoolAdded event
public(package) fun emit_reward_pool_added(pool_id: ID, reward_pool: &RewardPool) {
    event::emit(RewardPoolAdded {
        pool_id,
        reward_token_type: reward_pool.reward_token_type,
        total_rewards: reward_pool.total_rewards,
        start_time: reward_pool.start_time,
        end_time: reward_pool.end_time,
    });
}

/// Emits a RewardsClaimed event
public(package) fun emit_rewards_claimed(
    pool_id: ID,
    typename: TypeName,
    user: address,
    amount: u64,
) {
    event::emit(RewardsClaimed {
        pool_id,
        typename,
        user,
        amount,
    });
}

public(package) fun claim_from_pool<RewardToken>(user_rewards: &mut UserRewards): u64 {
    let reward_type = type_name::get<RewardToken>();
    if (!user_rewards.rewards_by_token.contains(&reward_type)) {
        user_rewards
            .rewards_by_token
            .insert(
                reward_type,
                UserRewardInfo {
                    accumulated_rewards: 0,
                    last_cumulative_reward_per_share: 0,
                },
            );
    };

    let claimable_rewards = user_rewards.rewards_by_token.get(&reward_type).accumulated_rewards;
    user_rewards.rewards_by_token.get_mut(&reward_type).accumulated_rewards = 0;
    claimable_rewards
}

// === Getter Functions ===
/// Returns the cumulative reward per share
public(package) fun cumulative_reward_per_share(reward_pool: &RewardPool): u64 {
    reward_pool.cumulative_reward_per_share
}

/// Returns the user's rewards by token
public(package) fun rewards_by_token(
    user_rewards: &UserRewards,
): &VecMap<TypeName, UserRewardInfo> {
    &user_rewards.rewards_by_token
}

/// Returns the user's accumulated rewards for a specific token type
public(package) fun accumulated_rewards_for_token(
    user_rewards: &UserRewards,
    reward_type: TypeName,
): u64 {
    if (user_rewards.rewards_by_token.contains(&reward_type)) {
        user_rewards.rewards_by_token.get(&reward_type).accumulated_rewards
    } else {
        0
    }
}

/// Returns the user's last cumulative reward per share checkpoint for a specific token type
public(package) fun last_cumulative_reward_per_share_for_token(
    user_rewards: &UserRewards,
    reward_type: TypeName,
): u64 {
    if (user_rewards.rewards_by_token.contains(&reward_type)) {
        user_rewards.rewards_by_token.get(&reward_type).last_cumulative_reward_per_share
    } else {
        0
    }
}

/// Returns the reward token type
public(package) fun reward_token_type(reward_pool: &RewardPool): TypeName {
    reward_pool.reward_token_type
}
