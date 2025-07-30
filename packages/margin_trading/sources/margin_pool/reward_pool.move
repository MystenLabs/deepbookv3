module margin_trading::reward_pool;

use std::type_name::{Self, TypeName};
use std::u64::max;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::clock::Clock;

const MAX_REWARD_POOLS: u64 = 5;

const EMaxRewardPoolsExceeded: u64 = 1;
const ERewardCurrentlyLive: u64 = 2;

public struct RewardPoolManager has store {
    typenames: vector<TypeName>,
    cumulative_rewards_per_share: vector<u64>,
    start_timestamps: vector<u64>,
    end_timestamps: vector<u64>,
    reward_per_seconds: vector<u64>,
    reward_index: u64,
    last_updated_timestamp: u64,
    reward_balances: Bag,
}

public(package) fun new(ctx: &mut TxContext): RewardPoolManager {
    RewardPoolManager {
        typenames: vector::empty(),
        cumulative_rewards_per_share: vector::empty(),
        start_timestamps: vector::empty(),
        end_timestamps: vector::empty(),
        reward_per_seconds: vector::empty(),
        reward_index: 0,
        last_updated_timestamp: 0,
        reward_balances: bag::new(ctx),
    }
}

public(package) fun update_reward_pools(
    self: &mut RewardPoolManager,
    shares: u64,
    clock: &Clock,
) {
    let current_timestamp = clock.timestamp_ms();
    let mut i = 0;
    while (i < self.reward_index) {
        let start_timestamp = self.start_timestamps[i];
        let end_timestamp = self.end_timestamps[i];
        // if rewards haven't started yet || rewards have ended since last check, skip
        if (start_timestamp > current_timestamp || end_timestamp < self.last_updated_timestamp) {
            i = i + 1;
            continue
        };

        let reward_end_time = max(end_timestamp, current_timestamp);
        let reward_duration = reward_end_time - self.last_updated_timestamp;
        let reward_duration_seconds = reward_duration / 1000;
        let reward_per_second = self.reward_per_seconds[i];
        let reward_amount = reward_per_second * reward_duration_seconds;

        let cumulative_rewards_per_share = self.cumulative_rewards_per_share[i];
        let new_cumulative_rewards_per_share =
            cumulative_rewards_per_share + reward_amount / shares;
        insert_swap_remove(
            &mut self.cumulative_rewards_per_share,
            i,
            new_cumulative_rewards_per_share,
        );

        i = i + 1;
    };

    self.last_updated_timestamp = current_timestamp;
}

public(package) fun create_reward_pool<RewardToken>(
    self: &mut RewardPoolManager,
    reward_balance: Balance<RewardToken>,
    start_time: u64,
    end_time: u64,
    ctx: &TxContext,
) {
    // check if this reward type already exists
    let reward_pool_index = self.index_of_reward_pool<RewardToken>();
    assert!(
        reward_pool_index == self.reward_index && self.reward_index >= MAX_REWARD_POOLS,
        EMaxRewardPoolsExceeded,
    );

    // insert empty reward pool if not exists
    self.insert_empty_reward_pool<RewardToken>(reward_pool_index);

    // get current reward pool and make sure it's not live
    let current_reward_end_time = self.end_timestamps[reward_pool_index];
    let current_timestamp = ctx.epoch_timestamp_ms();
    assert!(current_reward_end_time < current_timestamp, ERewardCurrentlyLive);

    // set start, end, rewards per second
    let rewards_per_second = reward_balance.value() / (end_time - start_time);
    insert_swap_remove(&mut self.start_timestamps, reward_pool_index, start_time);
    insert_swap_remove(&mut self.end_timestamps, reward_pool_index, end_time);
    insert_swap_remove(&mut self.reward_per_seconds, reward_pool_index, rewards_per_second);
    self.deposit_reward_pool(reward_balance);
}

public(package) fun withdraw_reward_pool<RewardToken>(
    self: &mut RewardPoolManager,
    amount: u64,
): Balance<RewardToken> {
    let key = type_name::get<RewardToken>();
    let balance: &mut Balance<RewardToken> = &mut self.reward_balances[key];

    balance.split(amount)
}

public(package) fun cumulative_rewards_per_share(self: &RewardPoolManager): vector<u64> {
    self.cumulative_rewards_per_share
}

public(package) fun insert_swap_remove(self: &mut vector<u64>, index: u64, value: u64) {
    self.push_back(value);
    self.swap_remove(index);
}

public(package) fun deposit_reward_pool<RewardToken>(
    self: &mut RewardPoolManager,
    reward_balance: Balance<RewardToken>,
) {
    let key = type_name::get<RewardToken>();
    if (self.reward_balances.contains(key)) {
        let balance: &mut Balance<RewardToken> = &mut self.reward_balances[key];
        balance.join(reward_balance);
    } else {
        self.reward_balances.add(key, reward_balance);
    }
}

public(package) fun index_of_reward_pool<RewardToken>(self: &RewardPoolManager): u64 {
    let reward_pool_typename = type_name::get<RewardToken>();
    let mut i = 0;
    while (i < self.reward_index) {
        if (self.typenames[i] == reward_pool_typename) {
            return i
        };
        i = i + 1;
    };

    i
}

fun insert_empty_reward_pool<RewardToken>(self: &mut RewardPoolManager, index: u64) {
    if (index != self.reward_index) {
        return
    };

    let reward_pool_typename = type_name::get<RewardToken>();
    self.typenames.push_back(reward_pool_typename);
    self.cumulative_rewards_per_share.push_back(0);
    self.start_timestamps.push_back(0);
    self.end_timestamps.push_back(0);
    self.reward_per_seconds.push_back(0);
    self.reward_index = self.reward_index + 1;
}

