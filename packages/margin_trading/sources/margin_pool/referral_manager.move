// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::referral_manager;

use deepbook::math;
use sui::vec_map::{Self, VecMap};

public struct ReferralManager has store {
    referrals: VecMap<ID, Referral>,
}

public struct Referral has store {
    referral_shares: u64,
    last_claim_index: u64,
    min_claim_shares: u64,
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
            },
        );

    ReferralCap {
        id: referral_id,
    }
}

public(package) fun empty(): ReferralManager {
    ReferralManager {
        referrals: vec_map::empty(),
    }
}

public(package) fun increase_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        referral.referral_shares = referral.referral_shares + supply_shares;
    };
}

public(package) fun decrease_referral_supply_shares(
    self: &mut ReferralManager,
    referral_id: Option<ID>,
    supply_shares: u64,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
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
