// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::referral_fees;

use deepbook::math;
use deepbook_margin::margin_constants;
use std::string::String;
use sui::{clock::Clock, table::{Self, Table}, vec_map::{Self, VecMap}};

// === Errors ===
const EInvalidFeesOnZeroShares: u64 = 1;

// === Structs ===
public struct ReferralFees has store {
    referrals: Table<address, ReferralTracker>,
    total_shares: u64,
    fees_per_share: u64,
    extra_fields: VecMap<String, u64>,
}

public struct ReferralTracker has store {
    shares: u64,
    share_ms: u64,
    last_update_timestamp: u64,
}

public struct Referral has key {
    id: UID,
    owner: address,
    last_claim_timestamp: u64,
    last_claim_share_ms: u64,
    last_fees_per_share: u64,
}

// Initialize the protocol fees with the default referral.
public(package) fun default_referral_fees(ctx: &mut TxContext, clock: &Clock): ReferralFees {
    let default_id = margin_constants::default_referral();
    let mut manager = ReferralFees {
        referrals: table::new(ctx),
        total_shares: 0,
        fees_per_share: 0,
        extra_fields: vec_map::empty(),
    };
    manager
        .referrals
        .add(
            default_id,
            ReferralTracker {
                shares: 0,
                share_ms: 0,
                last_update_timestamp: clock.timestamp_ms(),
            },
        );

    manager
}

/// Mint a referral object.
public(package) fun mint_referral(self: &mut ReferralFees, clock: &Clock, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let id_inner = id.to_inner();
    self
        .referrals
        .add(
            id.to_address(),
            ReferralTracker {
                shares: 0,
                share_ms: 0,
                last_update_timestamp: clock.timestamp_ms(),
            },
        );
    let referral = Referral {
        id,
        owner: ctx.sender(),
        last_claim_timestamp: clock.timestamp_ms(),
        last_claim_share_ms: 0,
        last_fees_per_share: self.fees_per_share,
    };
    transfer::share_object(referral);

    id_inner
}

/// Increase the fees per share.
public(package) fun increase_fees_per_share(
    self: &mut ReferralFees,
    total_shares: u64,
    fees_accrued: u64,
) {
    assert!(!(self.total_shares == 0 && fees_accrued > 0), EInvalidFeesOnZeroShares);
    if (self.total_shares > 0) {
        let fees_per_share_increase = math::div(fees_accrued, self.total_shares);
        self.fees_per_share = self.fees_per_share + fees_per_share_increase;
    };

    self.total_shares = total_shares;
}

public(package) fun increase_shares(
    self: &mut ReferralFees,
    referral: Option<address>,
    shares: u64,
    clock: &Clock,
) {
    let referral_address = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_address);
    referral_tracker.update_share_ms(clock);
    referral_tracker.shares = referral_tracker.shares + shares;
}

public(package) fun decrease_shares(
    self: &mut ReferralFees,
    referral: Option<address>,
    shares: u64,
    clock: &Clock,
) {
    let referral_address = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_address);
    referral_tracker.update_share_ms(clock);
    referral_tracker.shares = referral_tracker.shares - shares;
}

public(package) fun calculate_and_claim(
    self: &mut ReferralFees,
    referral: &mut Referral,
    clock: &Clock,
): u64 {
    let referral_tracker = self.referrals.borrow_mut(referral.id.to_address());
    referral_tracker.update_share_ms(clock);

    let now = clock.timestamp_ms();
    let elapsed = now - referral.last_claim_timestamp;
    if (elapsed == 0) return 0;
    let share_ms_delta = referral_tracker.share_ms - referral.last_claim_share_ms;
    let shares = math::div(share_ms_delta, elapsed);
    let fees_per_share_delta = self.fees_per_share - referral.last_fees_per_share;
    let fees = math::mul(shares, fees_per_share_delta);

    referral.last_claim_timestamp = now;
    referral.last_claim_share_ms = referral_tracker.share_ms;
    referral.last_fees_per_share = self.fees_per_share;

    fees
}

fun update_share_ms(referral_tracker: &mut ReferralTracker, clock: &Clock) {
    let now = clock.timestamp_ms();
    let elapsed = now - referral_tracker.last_update_timestamp;
    referral_tracker.share_ms =
        referral_tracker.share_ms + math::mul(referral_tracker.shares, elapsed);
    referral_tracker.last_update_timestamp = now;
}
