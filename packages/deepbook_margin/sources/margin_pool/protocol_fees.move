// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::protocol_fees;

use deepbook::math;
use deepbook_margin::margin_constants;
use std::string::String;
use sui::{event, table::{Self, Table}, vec_map::{Self, VecMap}};

// === Errors ===
const ENotOwner: u64 = 1;

// === Structs ===
public struct ProtocolFees has store {
    referrals: Table<ID, ReferralTracker>,
    total_shares: u64,
    fees_per_share: u64,
    maintainer_fees: u64,
    protocol_fees: u64,
    extra_fields: VecMap<String, u64>,
}

public struct ReferralTracker has store {
    current_shares: u64,
    last_fees_per_share: u64,
    unclaimed_fees: u64,
}

public struct SupplyReferral has key {
    id: UID,
    owner: address,
}

public struct ProtocolFeesIncreasedEvent has copy, drop {
    margin_pool_id: ID,
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

/// Get the maintainer fees.
public fun maintainer_fees(self: &ProtocolFees): u64 {
    self.maintainer_fees
}

/// Get the protocol fees.
public fun protocol_fees(self: &ProtocolFees): u64 {
    self.protocol_fees
}

public fun referral_tracker(self: &ProtocolFees, referral: ID): (u64, u64) {
    let referral_tracker = self.referrals.borrow(referral);
    let fees_per_share_delta = self.fees_per_share - referral_tracker.last_fees_per_share;
    let unclaimed_fees = math::mul(referral_tracker.current_shares, fees_per_share_delta);
    (referral_tracker.current_shares, referral_tracker.unclaimed_fees + unclaimed_fees)
}

public fun total_shares(self: &ProtocolFees): u64 {
    self.total_shares
}

public fun fees_per_share(self: &ProtocolFees): u64 {
    self.fees_per_share
}

// Initialize the referral fees with the default referral.
public(package) fun default_protocol_fees(ctx: &mut TxContext): ProtocolFees {
    let default_id = margin_constants::default_referral();
    let mut manager = ProtocolFees {
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
                last_fees_per_share: 0,
                unclaimed_fees: 0,
            },
        );

    manager
}

/// Mint a referral object.
public(package) fun mint_supply_referral(self: &mut ProtocolFees, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let id_inner = id.to_inner();
    self
        .referrals
        .add(
            id_inner,
            ReferralTracker {
                current_shares: 0,
                last_fees_per_share: self.fees_per_share,
                unclaimed_fees: 0,
            },
        );
    let referral = SupplyReferral {
        id,
        owner: ctx.sender(),
    };
    transfer::share_object(referral);

    id_inner
}

/// Increase the fees per share. Given the current fees earned, divide it by current outstanding shares.
/// Half of fees goes to referrals, quarter to maintainer, quarter to protocol.
/// If there are no shares (no suppliers), referral fees are redistributed to maintainer and protocol.
public(package) fun increase_fees_accrued(
    self: &mut ProtocolFees,
    margin_pool_id: ID,
    fees_accrued: u64,
) {
    if (fees_accrued == 0) return;
    let protocol_fees = fees_accrued / 4;
    let maintainer_fees = fees_accrued / 4;
    let referral_fees = fees_accrued - protocol_fees - maintainer_fees;

    if (self.total_shares > 0) {
        let fees_per_share_increase = math::div(referral_fees, self.total_shares);
        self.fees_per_share = self.fees_per_share + fees_per_share_increase;
        self.maintainer_fees = self.maintainer_fees + maintainer_fees;
        self.protocol_fees = self.protocol_fees + protocol_fees;
    } else {
        self.maintainer_fees = self.maintainer_fees + maintainer_fees + referral_fees / 2;
        self.protocol_fees =
            self.protocol_fees + protocol_fees + (referral_fees - referral_fees / 2);
    };

    event::emit(ProtocolFeesIncreasedEvent {
        margin_pool_id,
        total_shares: self.total_shares,
        referral_fees,
        maintainer_fees,
        protocol_fees,
    });
}

/// Increase the shares for a referral.
public(package) fun increase_shares(self: &mut ProtocolFees, referral: Option<ID>, shares: u64) {
    let referral_id = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_id);
    referral_tracker.update_unclaimed_fees(self.fees_per_share);

    referral_tracker.current_shares = referral_tracker.current_shares + shares;
    self.total_shares = self.total_shares + shares;
}

/// Decrease the shares for a referral.
public(package) fun decrease_shares(self: &mut ProtocolFees, referral: Option<ID>, shares: u64) {
    let referral_id = referral.destroy_with_default(margin_constants::default_referral());
    let referral_tracker = self.referrals.borrow_mut(referral_id);
    referral_tracker.update_unclaimed_fees(self.fees_per_share);

    referral_tracker.current_shares = referral_tracker.current_shares - shares;
    self.total_shares = self.total_shares - shares;
}

/// Calculate the fees for a referral and claim them. Multiply the referred shares by the fees per share delta.
/// Referred fees is set to the minimum of the current and referred shares.
public(package) fun calculate_and_claim(
    self: &mut ProtocolFees,
    referral: &SupplyReferral,
    ctx: &TxContext,
): u64 {
    assert!(ctx.sender() == referral.owner, ENotOwner);

    let referral_tracker = self.referrals.borrow_mut(referral.id.to_inner());
    referral_tracker.update_unclaimed_fees(self.fees_per_share);
    let fees = referral_tracker.unclaimed_fees;
    referral_tracker.unclaimed_fees = 0;

    event::emit(ReferralFeesClaimedEvent {
        referral_id: referral.id.to_inner(),
        owner: referral.owner,
        fees,
    });

    fees
}

/// Claim the default referral fees (admin only).
/// The default referral at 0x0 doesn't have a SupplyReferral object, so admin must claim these fees.
public(package) fun claim_default_referral_fees(self: &mut ProtocolFees): u64 {
    let default_id = margin_constants::default_referral();
    let referral_tracker = self.referrals.borrow_mut(default_id);
    referral_tracker.update_unclaimed_fees(self.fees_per_share);
    let fees = referral_tracker.unclaimed_fees;
    referral_tracker.unclaimed_fees = 0;

    event::emit(ReferralFeesClaimedEvent {
        referral_id: default_id,
        owner: default_id.to_address(),
        fees,
    });

    fees
}

/// Claim the maintainer fees.
public(package) fun claim_maintainer_fees(self: &mut ProtocolFees): u64 {
    let fees = self.maintainer_fees;
    self.maintainer_fees = 0;
    fees
}

/// Claim the protocol fees.
public(package) fun claim_protocol_fees(self: &mut ProtocolFees): u64 {
    let fees = self.protocol_fees;
    self.protocol_fees = 0;
    fees
}

fun update_unclaimed_fees(referral: &mut ReferralTracker, fees_per_share: u64) {
    let fees_per_share_delta = fees_per_share - referral.last_fees_per_share;
    let unclaimed_fees = math::mul(referral.current_shares, fees_per_share_delta);
    referral.unclaimed_fees = referral.unclaimed_fees + unclaimed_fees;
    referral.last_fees_per_share = fees_per_share;
}
