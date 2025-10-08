// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::referral_fees;

use deepbook::math;
use deepbook_margin::margin_constants;
use std::string::String;
use sui::{event, table::{Self, Table}, vec_map::{Self, VecMap}};

// === Errors ===
const ENotOwner: u64 = 1;
const EInvalidFeesAccrued: u64 = 2;

// === Structs ===
public struct ReferralFees has store {
    referrals: Table<address, ReferralTracker>,
    total_shares: u64,
    fees_per_share: u64,
    maintainer_fees: u64,
    protocol_fees: u64,
    extra_fields: VecMap<String, u64>,
}

public struct ReferralTracker has store {
    current_shares: u64,
    min_shares: u64,
}

public struct SupplyReferral has key {
    id: UID,
    owner: address,
    last_fees_per_share: u64,
}

public struct ProtocolFeesIncreasedEvent has copy, drop {
    total_shares: u64,
    referral_fees: u64,
    maintainer_fees: u64,
    protocol_fees: u64,
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
        maintainer_fees: 0,
        protocol_fees: 0,
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
public(package) fun mint_supply_referral(self: &mut ReferralFees, ctx: &mut TxContext): ID {
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
    let referral = SupplyReferral {
        id,
        owner: ctx.sender(),
        last_fees_per_share: self.fees_per_share,
    };
    transfer::share_object(referral);

    id_inner
}

/// Increase the fees per share. Given the current fees earned, divide it by current outstanding shares.
/// Half of fees goes to referrals, quarter to maintainer, quarter to protocol.
public(package) fun increase_fees_accrued(self: &mut ReferralFees, fees_accrued: u64) {
    assert!(fees_accrued == 0 || self.total_shares > 0, EInvalidFeesAccrued);
    let protocol_fees = fees_accrued / 4;
    let maintainer_fees = fees_accrued / 4;
    let referral_fees = fees_accrued - protocol_fees - maintainer_fees;

    if (self.total_shares > 0) {
        let fees_per_share_increase = math::div(referral_fees, self.total_shares);
        self.fees_per_share = self.fees_per_share + fees_per_share_increase;
        self.maintainer_fees = self.maintainer_fees + maintainer_fees;
        self.protocol_fees = self.protocol_fees + protocol_fees;
    };

    event::emit(ProtocolFeesIncreasedEvent {
        total_shares: self.total_shares,
        referral_fees,
        maintainer_fees,
        protocol_fees,
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
    referral: &mut SupplyReferral,
    ctx: &TxContext,
): u64 {
    assert!(ctx.sender() == referral.owner, ENotOwner);

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

/// Claim the maintainer fees.
public(package) fun claim_maintainer_fees(self: &mut ReferralFees): u64 {
    let fees = self.maintainer_fees;
    self.maintainer_fees = 0;
    fees
}

/// Claim the protocol fees.
public(package) fun claim_protocol_fees(self: &mut ReferralFees): u64 {
    let fees = self.protocol_fees;
    self.protocol_fees = 0;
    fees
}

/// Get the maintainer fees.
public(package) fun maintainer_fees(self: &ReferralFees): u64 {
    self.maintainer_fees
}

/// Get the protocol fees.
public(package) fun protocol_fees(self: &ReferralFees): u64 {
    self.protocol_fees
}

public(package) fun referral_tracker(self: &ReferralFees, referral: address): (u64, u64) {
    let referral_tracker = self.referrals.borrow(referral);
    (referral_tracker.current_shares, referral_tracker.min_shares)
}

public(package) fun total_shares(self: &ReferralFees): u64 {
    self.total_shares
}

public(package) fun fees_per_share(self: &ReferralFees): u64 {
    self.fees_per_share
}
