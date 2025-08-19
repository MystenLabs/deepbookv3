// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::referral_manager;

use deepbook::math;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

public struct ReferralManager has store {
    referrals: VecMap<ID, Referral>,
    total_shares: u64,
    total_score: u64,
    rewards_per_score_index: u64, // Cumulative rewards per score point (9 decimals)
    total_rewards_distributed: u64, // Total rewards ever paid out
}

public struct Referral has store {
    referral_shares: u64,
    score: u64,
    claimed_rewards: u64,
    last_update_timestamp: u64,
    last_rewards_index: u64, // Last rewards_per_score_index when user claimed
}

public struct ReferralCap has key, store {
    id: UID,
}

public fun id(referral_cap: &ReferralCap): ID {
    referral_cap.id.to_inner()
}

public fun mint_referral_cap(
    self: &mut ReferralManager,
    clock: &Clock,
    ctx: &mut TxContext,
): ReferralCap {
    let referral_id = object::new(ctx);
    self
        .referrals
        .insert(
            referral_id.to_inner(),
            Referral {
                referral_shares: 0,
                score: 0,
                claimed_rewards: 0,
                last_update_timestamp: clock.timestamp_ms(),
                last_rewards_index: self.rewards_per_score_index,
            },
        );

    ReferralCap {
        id: referral_id,
    }
}

public(package) fun empty(): ReferralManager {
    ReferralManager {
        referrals: vec_map::empty(),
        total_shares: 0,
        total_score: 0,
        rewards_per_score_index: 0,
        total_rewards_distributed: 0,
    }
}

public(package) fun increase_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        let current_time = clock.timestamp_ms();
        let time_diff = current_time - referral.last_update_timestamp;
        let score_increase = math::mul(time_diff, referral.referral_shares);

        self.total_shares = self.total_shares + supply_shares;
        referral.referral_shares = referral.referral_shares + supply_shares;

        self.total_score = self.total_score + score_increase;
        referral.score = referral.score + score_increase;

        referral.last_update_timestamp = current_time;
    };
}

public(package) fun decrease_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        let current_time = clock.timestamp_ms();
        let time_diff = current_time - referral.last_update_timestamp;
        let score_increase = math::mul(time_diff, referral.referral_shares);

        self.total_shares = self.total_shares - supply_shares;
        referral.referral_shares = referral.referral_shares - supply_shares;

        self.total_score = self.total_score + score_increase;
        referral.score = referral.score + score_increase;

        referral.last_update_timestamp = current_time;
    };
}

/// Adds new rewards to the system, updating the rewards index fairly
/// This should be called whenever new referral profits are available
public(package) fun add_rewards(self: &mut ReferralManager, new_rewards: u64) {
    if (new_rewards > 0 && self.total_score > 0) {
        // Increase the rewards per score index
        let rewards_per_score_increment = math::div(new_rewards, self.total_score);
        self.rewards_per_score_index = self.rewards_per_score_index + rewards_per_score_increment;
    };
}

/// Claims rewards using the fair index-based system
/// Everyone gets the same rewards per score point regardless of timing
public(package) fun claim_referral_rewards(
    self: &mut ReferralManager,
    referral_id: ID,
    clock: &Clock,
): u64 {
    let referral = self.referrals.get_mut(&referral_id);
    let current_time = clock.timestamp_ms();
    let time_diff = current_time - referral.last_update_timestamp;
    let score_increase = math::mul(time_diff, referral.referral_shares);

    // Update individual and total scores
    self.total_score = self.total_score + score_increase;
    referral.score = referral.score + score_increase;
    referral.last_update_timestamp = current_time;

    // Calculate rewards based on index difference (this ensures fairness)
    let index_diff = self.rewards_per_score_index - referral.last_rewards_index;
    let reward_amount = math::mul(referral.score, index_diff);

    // Update tracking
    referral.claimed_rewards = referral.claimed_rewards + reward_amount;
    referral.last_rewards_index = self.rewards_per_score_index;
    self.total_rewards_distributed = self.total_rewards_distributed + reward_amount;

    reward_amount
}

/// View function to check claimable rewards without claiming
/// Useful for UI to show pending rewards
public fun get_claimable_rewards(
    self: &ReferralManager,
    referral_id: &ID,
    current_timestamp: u64,
): u64 {
    let referral = self.referrals.get(referral_id);
    let time_diff = current_timestamp - referral.last_update_timestamp;
    let score_increase = math::mul(time_diff, referral.referral_shares);
    let total_score = referral.score + score_increase;

    // Calculate rewards based on index difference
    let index_diff = self.rewards_per_score_index - referral.last_rewards_index;
    math::mul(total_score, index_diff)
}
