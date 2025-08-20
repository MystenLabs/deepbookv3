module margin_trading::referral_manager2;

use deepbook::math;
use sui::clock::Clock;
use sui::vec_map::{Self, VecMap};

public struct ReferralManager2 has store {
    referrals: VecMap<ID, Referral>,
}

public struct Referral has store {
    referral_shares: u64,
    share_seconds: u64,
    last_claim_index: u64,
    last_claim_timestamp: u64,
    last_update_timestamp: u64,
}

public(package) fun default(): ReferralManager2 {
    ReferralManager2 {
        referrals: vec_map::empty(),
    }
}

public struct ReferralCap has key, store {
    id: UID,
}

public fun id(referral_cap: &ReferralCap): ID {
    referral_cap.id.to_inner()
}

public(package) fun mint_referral_cap(
    self: &mut ReferralManager2,
    current_index: u64,
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
                share_seconds: 0,
                last_claim_index: current_index,
                last_claim_timestamp: clock.timestamp_ms(),
                last_update_timestamp: clock.timestamp_ms(),
            },
        );

    ReferralCap {
        id: referral_id,
    }
}

public(package) fun increase_referral_supply_shares(
    self: &mut ReferralManager2,
    referral_id: Option<ID>,
    supply_shares: u64,
    clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        referral.update_share_seconds(clock);
        referral.referral_shares = referral.referral_shares + supply_shares;
    }
}

public(package) fun decrease_referral_supply_shares(
    self: &mut ReferralManager2,
    referral_id: Option<ID>,
    supply_shares: u64,
    clock: &Clock,
) {
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral = self.referrals.get_mut(&referral_id);
        referral.update_share_seconds(clock);
        referral.referral_shares = referral.referral_shares - supply_shares;
    }
}

public(package) fun claim_referral_rewards(
    self: &mut ReferralManager2,
    referral_id: ID,
    current_index: u64,
    clock: &Clock,
): u64 {
    let referral = self.referrals.get_mut(&referral_id);
    let index_diff = current_index - referral.last_claim_index;
    let counted_shares = self.reset_referral_share_seconds(referral_id, current_index, clock);

    math::mul(counted_shares, index_diff)
}

fun reset_referral_share_seconds(self: &mut ReferralManager2, referral_id: ID, current_index: u64, clock: &Clock): u64 {
    let referral = self.referrals.get_mut(&referral_id);
    referral.update_share_seconds(clock);

    let elapsed_claim_seconds = (clock.timestamp_ms() - referral.last_claim_timestamp) / 1000;
    let referred_shares = math::div(referral.share_seconds, elapsed_claim_seconds);
    referral.share_seconds = 0;
    referral.last_claim_timestamp = clock.timestamp_ms();
    referral.last_claim_index = current_index;

    referred_shares
}

fun update_share_seconds(self: &mut Referral, clock: &Clock) {
    let current_timestamp = clock.timestamp_ms();
    let elapsed_seconds = (current_timestamp - self.last_update_timestamp) / 1000;
    self.share_seconds = self.share_seconds + math::mul(self.referral_shares, elapsed_seconds);
    self.last_update_timestamp = current_timestamp;
}