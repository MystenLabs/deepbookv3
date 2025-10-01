// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::referral_fees;

use deepbook::math;
use deepbook_margin::margin_constants;
use std::string::String;
use sui::{event, table::{Self, Table}, vec_map::{Self, VecMap}};

// === Structs ===
public struct ReferralFees has store {
    referrals: Table<address, ReferralTracker>,
    total_shares: u64,
    fees_per_share: u64,
    extra_fields: VecMap<String, u64>,
}

public struct ReferralTracker has store {
    current_shares: u64,
    min_shares: u64,
}

public struct Referral has key {
    id: UID,
    owner: address,
    last_fees_per_share: u64,
}

public struct ReferralFeesIncreasedEvent has copy, drop {
    total_shares: u64,
    fees_accrued: u64,
}

public struct ReferralFeesClaimedEvent has copy, drop {
    referral_id: ID,
    owner: address,
    fees: u64,
}

// Initialize the referral fees with the default referral.
public(package) fun default_referral_fees(ctx: &mut TxContext): ReferralFees {
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
                current_shares: 0,
                min_shares: 0,
            },
        );

    manager
}

/// Mint a referral object.
public(package) fun mint_referral(self: &mut ReferralFees, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let id_inner = id.to_inner();
    self
        .referrals
        .add(
            id.to_address(),
            ReferralTracker {
                current_shares: 0,
                min_shares: 0,
            },
        );
    let referral = Referral {
        id,
        owner: ctx.sender(),
        last_fees_per_share: self.fees_per_share,
    };
    transfer::share_object(referral);

    id_inner
}

/// Increase the fees per share. Given the current fees earned, divide it by current outstanding shares.
public(package) fun increase_fees_per_share(
    self: &mut ReferralFees,
    fees_accrued: u64,
) {
    let fees_per_share_increase = math::div(fees_accrued, self.total_shares);
    self.fees_per_share = self.fees_per_share + fees_per_share_increase;

    event::emit(ReferralFeesIncreasedEvent {
        total_shares: self.total_shares,
        fees_accrued,
    });
}

/// Increase the shares for a referral.
public(package) fun increase_shares(
    self: &mut ReferralFees,
    referral: Option<address>,
    shares: u64,
) {
    let referral_address = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_address);
    referral_tracker.current_shares = referral_tracker.current_shares + shares;
    self.total_shares = self.total_shares + shares;
}

/// Decrease the shares for a referral.
public(package) fun decrease_shares(
    self: &mut ReferralFees,
    referral: Option<address>,
    shares: u64,
) {
    let referral_address = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_address);
    referral_tracker.current_shares = referral_tracker.current_shares - shares;
    referral_tracker.min_shares = referral_tracker.min_shares.min(referral_tracker.current_shares);
    self.total_shares = self.total_shares - shares;
}

/// Calculate the fees for a referral and claim them. Multiply the referred shares by the fees per share delta.
/// Referred fees is set to the minimum of the current and referred shares.
public(package) fun calculate_and_claim(
    self: &mut ReferralFees,
    referral: &mut Referral,
): u64 {
    let referral_tracker = self.referrals.borrow_mut(referral.id.to_address());
    let referred_shares = referral_tracker.min_shares;
    let fees_per_share_delta = self.fees_per_share - referral.last_fees_per_share;
    let fees = math::mul(referred_shares, fees_per_share_delta);

    referral.last_fees_per_share = self.fees_per_share;
    referral_tracker.min_shares = referral_tracker.current_shares;

    event::emit(ReferralFeesClaimedEvent {
        referral_id: referral.id.to_inner(),
        owner: referral.owner,
        fees,
    });

    fees
}
