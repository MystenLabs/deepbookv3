// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::supply_referral;

use margin_trading::margin_constants;
use sui::{clock::Clock, table::{Self, Table}};
use deepbook::math;

public struct SupplyReferral has store {
    share_seconds: Table<address, ReferralTracker>,
    fees_per_share: u64,
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

public(package) fun mint_referral(self: &mut SupplyReferral, fees_per_share: u64, clock: &Clock, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let id_inner = id.to_inner();
    self.share_seconds.add(id.to_address(), ReferralTracker {
        shares: 0,
        share_ms: 0,
        last_update_timestamp: clock.timestamp_ms(),
    });
    let referral = Referral {
        id,
        owner: ctx.sender(),
        last_claim_timestamp: clock.timestamp_ms(),
        last_claim_share_ms: 0,
        last_fees_per_share: fees_per_share,
    };
    transfer::share_object(referral);

    id_inner
}

public(package) fun new_referral_manager(ctx: &mut TxContext, clock: &Clock): SupplyReferral {
    let default_id = margin_constants::default_referral();
    let mut manager = SupplyReferral {
        share_seconds: table::new(ctx),
        fees_per_share: 0,
    };
    manager.share_seconds.add(default_id, ReferralTracker {
        shares: 0,
        share_ms: 0,
        last_update_timestamp: clock.timestamp_ms(),
    });

    manager
}

public(package) fun increase_shares(self: &mut SupplyReferral, referral: &Referral, shares: u64, clock: &Clock) {
    let referral_tracker = self.share_seconds.borrow_mut(referral.id.to_address());
    referral_tracker.update_share_ms(clock);
    referral_tracker.shares = referral_tracker.shares + shares;
}

public(package) fun decrease_shares(self: &mut SupplyReferral, referral: &Referral, shares: u64, clock: &Clock) {
    let referral_tracker = self.share_seconds.borrow_mut(referral.id.to_address());
    referral_tracker.update_share_ms(clock);
    referral_tracker.shares = referral_tracker.shares - shares;
}

public(package) fun calculate_claim(self: &mut SupplyReferral, referral: &mut Referral, fees_per_share: u64, clock: &Clock): u64 {
    let referral_tracker = self.share_seconds.borrow_mut(referral.id.to_address());
    referral_tracker.update_share_ms(clock);
    
    let now = clock.timestamp_ms();
    let elapsed = now - referral.last_claim_timestamp;
    let share_ms_delta = referral_tracker.share_ms - referral.last_claim_share_ms;
    let shares = math::div(share_ms_delta, elapsed);

    referral.last_claim_share_ms = now;
    referral.last_claim_share_ms = referral_tracker.share_ms;

    shares
}

fun update_share_ms(referral_tracker: &mut ReferralTracker, clock: &Clock) {
    let now = clock.timestamp_ms();
    let elapsed = now - referral_tracker.last_update_timestamp;
    referral_tracker.share_ms = referral_tracker.share_ms + math::mul(referral_tracker.shares, elapsed);
    referral_tracker.last_update_timestamp = now;
}
