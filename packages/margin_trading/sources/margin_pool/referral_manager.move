// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::referral_manager;

use deepbook::math;
use sui::vec_map::{Self, VecMap};

public struct ReferralManager has store {
    referrals: VecMap<ID, Referral>,
    total_global_score: u64,
    last_update_timestamp: u64,
}

public struct Referral has store {
    referral_shares: u64,
    last_claim_index: u64,
    min_claim_shares: u64,
    accumulated_score: u64,
    last_score_update_timestamp: u64,
}

public struct ReferralCap has key, store {
    id: UID,
}

public fun id(referral_cap: &ReferralCap): ID {
    referral_cap.id.to_inner()
}

public fun mint_referral_cap(
    self: &mut ReferralManager,
    current_index: u64,
    current_timestamp: u64,
    ctx: &mut TxContext,
): ReferralCap {
    let referral_id = object::new(ctx);
    self
        .referrals
        .insert(
            referral_id.to_inner(),
            Referral {
                referral_shares: 0,
                last_claim_index: current_index,
                min_claim_shares: 0,
                accumulated_score: 0,
                last_score_update_timestamp: current_timestamp,
            },
        );

    ReferralCap {
        id: referral_id,
    }
}

public(package) fun empty(current_timestamp: u64): ReferralManager {
    ReferralManager {
        referrals: vec_map::empty(),
        total_global_score: 0,
        last_update_timestamp: current_timestamp,
    }
}

public(package) fun increase_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    current_timestamp: u64,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        // Update score before changing shares
        let time_elapsed = current_timestamp - referral.last_score_update_timestamp;
        let score_to_add = math::mul(referral.referral_shares, time_elapsed);

        referral.accumulated_score = referral.accumulated_score + score_to_add;
        self.total_global_score = self.total_global_score + score_to_add;
        referral.last_score_update_timestamp = current_timestamp;

        referral.referral_shares = referral.referral_shares + supply_shares;
    };
}

public(package) fun decrease_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
    current_timestamp: u64,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        // Update score before changing shares
        let time_elapsed = current_timestamp - referral.last_score_update_timestamp;
        let score_to_add = math::mul(referral.referral_shares, time_elapsed);

        referral.accumulated_score = referral.accumulated_score + score_to_add;
        self.total_global_score = self.total_global_score + score_to_add;
        referral.last_score_update_timestamp = current_timestamp;

        referral.referral_shares = referral.referral_shares - supply_shares;
        referral.min_claim_shares = referral.min_claim_shares.min(referral.referral_shares);
    };
}

public(package) fun claim_referral_rewards(
    self: &mut ReferralManager,
    referral_id: ID,
    current_index: u64,
): u64 {
    let referral = self.referrals.get_mut(&referral_id);
    let index_diff = current_index - referral.last_claim_index;
    let counted_shares = referral.min_claim_shares;
    referral.last_claim_index = current_index;
    referral.min_claim_shares = referral.referral_shares;

    math::mul(counted_shares, index_diff)
}

/// Updates all referral scores and global score to current timestamp
public(package) fun update_all_referral_scores(self: &mut ReferralManager, current_timestamp: u64) {
    let keys = self.referrals.keys();
    let mut i = 0;
    let mut total_score_to_add = 0;

    while (i < keys.length()) {
        let key = &keys[i];
        let referral = self.referrals.get_mut(key);

        let time_elapsed = current_timestamp - referral.last_score_update_timestamp;
        let score_to_add = math::mul(referral.referral_shares, time_elapsed);

        referral.accumulated_score = referral.accumulated_score + score_to_add;
        referral.last_score_update_timestamp = current_timestamp;
        total_score_to_add = total_score_to_add + score_to_add;

        i = i + 1;
    };

    self.total_global_score = self.total_global_score + total_score_to_add;
    self.last_update_timestamp = current_timestamp;
}

/// Claims proportional rewards based on accumulated scores
public(package) fun claim_proportional_rewards(
    self: &mut ReferralManager,
    referral_id: ID,
    total_rewards_available: u64,
    current_timestamp: u64,
): u64 {
    // First update all scores to ensure fairness
    self.update_all_referral_scores(current_timestamp);

    if (self.total_global_score == 0) {
        return 0
    };

    let referral = self.referrals.get_mut(&referral_id);
    let user_score = referral.accumulated_score;

    // Calculate proportional reward: (user_score / total_global_score) * total_rewards
    let reward_amount = math::mul(
        math::div(user_score, self.total_global_score),
        total_rewards_available,
    );

    // Reset user's accumulated score after claiming
    self.total_global_score = self.total_global_score - referral.accumulated_score;
    referral.accumulated_score = 0;

    reward_amount
}

/// Get the current score for a referral (including pending score)
public(package) fun get_referral_current_score(
    self: &ReferralManager,
    referral_id: &ID,
    current_timestamp: u64,
): u64 {
    let referral = self.referrals.get(referral_id);
    let time_elapsed = current_timestamp - referral.last_score_update_timestamp;
    let pending_score = math::mul(referral.referral_shares, time_elapsed);

    referral.accumulated_score + pending_score
}

/// Get total global score (including all pending scores)
public(package) fun get_total_global_score(self: &ReferralManager, current_timestamp: u64): u64 {
    let mut total_pending_score = 0;
    let keys = self.referrals.keys();
    let mut i = 0;
    while (i < keys.length()) {
        let key = &keys[i];
        let referral = self.referrals.get(key);
        let time_elapsed = current_timestamp - referral.last_score_update_timestamp;
        let pending_score = math::mul(referral.referral_shares, time_elapsed);
        total_pending_score = total_pending_score + pending_score;
        i = i + 1;
    };

    self.total_global_score + total_pending_score
}
