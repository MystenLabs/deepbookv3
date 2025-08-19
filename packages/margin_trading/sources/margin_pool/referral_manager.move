// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::referral_manager;

use deepbook::math;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

public struct ReferralManager has store {
    referrals: VecMap<ID, Referral>,
    total_shares: u64,
    rewards_per_share_index: u64, // Cumulative rewards per share (9 decimals)
    total_rewards_distributed: u64, // Total rewards ever paid out
}

public struct Referral has store {
    referral_shares: u64,
    last_rewards_index: u64, // Last rewards_per_share_index when user claimed
}

public struct ReferralCap has key, store {
    id: UID,
}

public fun id(referral_cap: &ReferralCap): ID {
    referral_cap.id.to_inner()
}

public fun mint_referral_cap(
    self: &mut ReferralManager,
    _clock: &Clock,
    ctx: &mut TxContext,
): ReferralCap {
    let referral_id = object::new(ctx);
    self
        .referrals
        .insert(
            referral_id.to_inner(),
            Referral {
                referral_shares: 0,
                last_rewards_index: self.rewards_per_share_index,
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
        rewards_per_share_index: 0,
        total_rewards_distributed: 0,
    }
}

public(package) fun increase_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    _clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);

        // Simple: just update shares
        self.total_shares = self.total_shares + supply_shares;
        referral.referral_shares = referral.referral_shares + supply_shares;
    };
}

public(package) fun decrease_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    _clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);

        // Simple: just update shares
        self.total_shares = self.total_shares - supply_shares;
        referral.referral_shares = referral.referral_shares - supply_shares;
    };
}

/// Distributes rewards immediately based on current shares - O(1) operation!
public(package) fun add_rewards(self: &mut ReferralManager, new_rewards: u64) {
    if (new_rewards > 0 && self.total_shares > 0) {
        // Update index based on current shares only - simple and fair
        let rewards_per_share_increment = math::div(new_rewards, self.total_shares);
        self.rewards_per_share_index = self.rewards_per_share_index + rewards_per_share_increment;
    };
}

/// Claims rewards - simple shares-based calculation
public(package) fun claim_referral_rewards(
    self: &mut ReferralManager,
    referral_id: ID,
    _clock: &Clock,
): u64 {
    let referral = self.referrals.get_mut(&referral_id);

    // Calculate rewards based on shares * index_difference
    let index_diff = self.rewards_per_share_index - referral.last_rewards_index;
    let reward_amount = math::mul(referral.referral_shares, index_diff);

    // Update user's last claimed index
    referral.last_rewards_index = self.rewards_per_share_index;
    self.total_rewards_distributed = self.total_rewards_distributed + reward_amount;

    reward_amount
}
