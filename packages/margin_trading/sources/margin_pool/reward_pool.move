// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::reward_pool;

use std::type_name::TypeName;
use sui::{
    balance::{Self, Balance}, 
    clock::Clock, 
    coin::Coin, 
    event,
    vec_map::{Self, VecMap}
};

// === Errors ===
const EInvalidRewardPeriod: u64 = 10;
const ERewardAmountTooSmall: u64 = 11;
const ERewardPeriodTooShort: u64 = 12;

// === Reward Constraints ===
const MIN_REWARD_AMOUNT: u64 = 1000;
const MIN_REWARD_DURATION_SECONDS: u64 = 3600; // 1 hour in seconds

// === Structs ===
// ID is used to distinguish between different reward pools of the same type
#[allow(lint(missing_key))]
public struct RewardPool<phantom T> has store {
    id: UID, // unique identifier for this reward pool
    reward_balance: Balance<T>, // stores the reward token balance
    total_rewards: u64, // total reward amount for this pool
    start_time: u64, // when rewards start distributing (seconds)
    end_time: u64, // when rewards stop distributing (seconds)
    reward_per_second: u64, // reward distributed per second
    cumulative_reward_per_share: u64, // cumulative rewards per share (no scaling)
    last_update_time: u64, // last time this pool was updated (seconds)
}

public struct UserRewards has store {
    accumulated_rewards: VecMap<TypeName, u64>, // tracks user's accumulated rewards per reward token type
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
    user: address,
    amount: u64,
}

// === Public Functions ===

public(package) fun create_reward_pool<RewardToken>(
    reward_coin: Coin<RewardToken>,
    start_time: u64,
    end_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): RewardPool<RewardToken> {
    let current_time_seconds = clock.timestamp_ms() / 1000;
    let reward_amount = reward_coin.value();
    
    assert!(start_time < end_time, EInvalidRewardPeriod);
    assert!(end_time > current_time_seconds, EInvalidRewardPeriod);
    assert!(reward_amount >= MIN_REWARD_AMOUNT, ERewardAmountTooSmall);
    
    let duration = end_time - start_time; 
    let reward_per_second = reward_amount / duration;
    let last_update_time = start_time.max(current_time_seconds);
    
    assert!(duration >= MIN_REWARD_DURATION_SECONDS, ERewardPeriodTooShort);
    
    RewardPool {
        id: object::new(ctx),
        reward_balance: reward_coin.into_balance(),
        total_rewards: reward_amount,
        start_time,
        end_time,
        reward_per_second,
        cumulative_reward_per_share: 0,
        last_update_time,
    }
}

public(package) fun create_user_rewards(): UserRewards {
    UserRewards {
        accumulated_rewards: vec_map::empty(),
    }
}

public(package) fun update_reward_pool<T>(
    reward_pool: &mut RewardPool<T>,
    current_time_ms: u64,
    total_supply: u64,
) {
    if (total_supply == 0) {
        return
    };
    
    let current_time = current_time_ms / 1000;
    let end_time = reward_pool.end_time.min(current_time);
    
    if (current_time <= reward_pool.last_update_time || current_time < reward_pool.start_time || end_time <= reward_pool.last_update_time) {
        return
    };
    
    let time_elapsed = end_time - reward_pool.last_update_time;
    
    let rewards_to_distribute = reward_pool.reward_per_second * time_elapsed;
    let reward_per_share = ((rewards_to_distribute as u128) * 1_000_000_000 / (total_supply as u128)) as u64;
    
    reward_pool.cumulative_reward_per_share = reward_pool.cumulative_reward_per_share + reward_per_share;
    reward_pool.last_update_time = end_time;
}

public(package) fun update_user_accumulated_rewards_for_token<T>(
    user_rewards: &mut UserRewards,
    cumulative_reward_per_share: u64,
    user_supply: u64
) {
    let reward_type = std::type_name::get<T>();
    let new_accumulated = ((user_supply as u128) * (cumulative_reward_per_share as u128) / 1_000_000_000) as u64;
    
    if (user_rewards.accumulated_rewards.contains(&reward_type)) {
        *user_rewards.accumulated_rewards.get_mut(&reward_type) = new_accumulated;
    } else {
        user_rewards.accumulated_rewards.insert(reward_type, new_accumulated);
    };
}

/// Calculates pending rewards for a user for a specific reward pool
public(package) fun calculate_pending_rewards<T>(
    user_rewards: &UserRewards,
    reward_pool: &RewardPool<T>,
    user_supply: u64,
): u64 {
    let reward_type = std::type_name::get<T>();
    let pool_rewards = ((user_supply as u128) * (reward_pool.cumulative_reward_per_share as u128) / 1_000_000_000) as u64;
    
    if (user_rewards.accumulated_rewards.contains(&reward_type)) {
        let user_accumulated = *user_rewards.accumulated_rewards.get(&reward_type);
        if (pool_rewards > user_accumulated) {
            pool_rewards - user_accumulated
        } else {
            0
        }
    } else {
        pool_rewards
    }
}

/// Claims rewards from a specific reward pool
public(package) fun claim_from_pool<RewardToken>(
    reward_pool: &mut RewardPool<RewardToken>,
    _user_rewards: &UserRewards,
    user_supply: u64,
    _ctx: &TxContext,
): Balance<RewardToken> {
    let pool_rewards = ((user_supply as u128) * (reward_pool.cumulative_reward_per_share as u128) / 1_000_000_000) as u64;
    let can_claim = pool_rewards > 0 && reward_pool.reward_balance.value() >= pool_rewards;
    
    if (can_claim) {
        reward_pool.reward_balance.split(pool_rewards)
    } else {
        balance::zero<RewardToken>()
    }
}

/// Emits a RewardPoolAdded event
public(package) fun emit_reward_pool_added<T>(
    pool_id: ID,
    reward_pool: &RewardPool<T>,
) {
    event::emit(RewardPoolAdded {
        pool_id,
        reward_token_type: std::type_name::get<T>(),
        total_rewards: reward_pool.total_rewards,
        start_time: reward_pool.start_time,
        end_time: reward_pool.end_time,
    });
}

/// Updates all reward pools in a vector
public(package) fun update_all_reward_pools<T>(
    pools: &mut vector<RewardPool<T>>,
    current_time_ms: u64,
    total_supply: u64,
) {
    pools.do_mut!(|pool| update_reward_pool(pool, current_time_ms, total_supply));
}

/// Calculates total pending rewards from all pools of a token type
public(package) fun calculate_total_pending_rewards<T>(
    pools: &vector<RewardPool<T>>,
    user_rewards: &UserRewards,
    user_supply: u64,
): u64 {
    let mut total_pending = 0;
    pools.do_ref!(|pool| total_pending = total_pending + calculate_pending_rewards(user_rewards, pool, user_supply));
    
    total_pending
}

/// Claims rewards from all pools of a token type and returns the total balance
public(package) fun claim_from_all_pools<T>(
    pools: &mut vector<RewardPool<T>>,
    user_rewards: &UserRewards,
    user_supply: u64,
    ctx: &TxContext,
): Balance<T> {
    let mut total_claimed_balance = balance::zero<T>();
    pools.do_mut!(|pool| total_claimed_balance.join(claim_from_pool(pool, user_rewards, user_supply, ctx)));
    total_claimed_balance
}

/// Calculates the sum of cumulative reward per share from all pools
public(package) fun calculate_cumulative_reward_per_share_sum<T>(
    pools: &vector<RewardPool<T>>
): u64 {
    let mut cumulative_per_share_sum = 0;
    let mut i = 0;
    while (i < pools.length()) {
        cumulative_per_share_sum = cumulative_per_share_sum + pools[i].cumulative_reward_per_share;
        i = i + 1;
    };
    cumulative_per_share_sum
}

/// Complete reward claiming process for a token type
/// Returns the claimed balance and claimed amount
public(package) fun process_reward_claim<T>(
    pools: &mut vector<RewardPool<T>>,
    user_rewards: &mut UserRewards,
    user_supply: u64,
    current_time_ms: u64,
    total_supply: u64,
    ctx: &TxContext,
): (Balance<T>, u64) {
    update_all_reward_pools(pools, current_time_ms, total_supply);
    
    let total_pending = calculate_total_pending_rewards(pools, user_rewards, user_supply);
    if (total_pending == 0) {
        return (balance::zero<T>(), 0)
    };
    
    let cumulative_per_share_sum = calculate_cumulative_reward_per_share_sum(pools);
    let total_claimed_balance = claim_from_all_pools(pools, user_rewards, user_supply, ctx);
    let total_claimed_amount = total_claimed_balance.value();
    update_user_accumulated_rewards_for_token<T>(user_rewards, cumulative_per_share_sum, user_supply);
    
    (total_claimed_balance, total_claimed_amount)
}

/// Emits a RewardsClaimed event
public(package) fun emit_rewards_claimed(
    pool_id: ID,
    user: address,
    amount: u64,
) {
    event::emit(RewardsClaimed {
        pool_id,
        user,
        amount,
    });
}

// === Getter Functions ===

/// Returns the cumulative reward per share
public(package) fun cumulative_reward_per_share<T>(reward_pool: &RewardPool<T>): u64 {
    reward_pool.cumulative_reward_per_share
}

/// Returns the user's accumulated rewards
public(package) fun accumulated_rewards(user_rewards: &UserRewards): &VecMap<TypeName, u64> {
    &user_rewards.accumulated_rewards
}

/// Returns the reward pool ID
public(package) fun reward_pool_id<T>(reward_pool: &RewardPool<T>): ID {
    reward_pool.id.to_inner()
}

/// Checks if a user has accumulated rewards for a specific reward token type
public(package) fun has_accumulated_rewards_for_token<T>(user_rewards: &UserRewards): bool {
    let reward_type = std::type_name::get<T>();
    user_rewards.accumulated_rewards.contains(&reward_type)
}

/// Destroys a reward pool and returns any remaining balance
public(package) fun destroy_reward_pool<T>(reward_pool: RewardPool<T>): Balance<T> {
    let RewardPool {
        id,
        reward_balance,
        total_rewards: _,
        start_time: _,
        end_time: _,
        reward_per_second: _,
        cumulative_reward_per_share: _,
        last_update_time: _,
    } = reward_pool;
    
    object::delete(id);
    reward_balance
}