// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::referral_manager;

use deepbook::math;
use sui::{clock::Clock, vec_map::{Self, VecMap}};

public struct ReferralManager has store {
    referrals: VecMap<ID, Referral>,
    total_shares: u64,
    total_score: u64,
}

public struct Referral has store {
    referral_shares: u64,
    score: u64,
    claimed_rewards: u64,
    last_update_timestamp: u64,
    last_claim_total_score: u64,
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
                last_claim_total_score: 0,
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

/// Returns the propotion of total rewards that the referral is entitled to
public(package) fun claim_referral_rewards(
    self: &mut ReferralManager,
    referral_id: ID,
    current_rewards: u64,
    clock: &Clock,
): u64 {
    let referral = self.referrals.get_mut(&referral_id);
    let current_time = clock.timestamp_ms();
    let time_diff = current_time - referral.last_update_timestamp;
    let score_increase = math::mul(time_diff, referral.referral_shares);

    self.total_score = self.total_score + score_increase;
    referral.score = referral.score + score_increase;
    referral.last_update_timestamp = current_time;

    if (self.total_score == 0) {
        return 0
    };

    let proportion = math::div(referral.score, self.total_score);

    math::mul(proportion, current_rewards)
}
