// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::protocol_fees_tests;
use margin_trading::{
    margin_constants,
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap, MarginPoolCap},
    protocol_config,
    test_constants::{Self, USDC, USDT},
    test_helpers::{Self, mint_coin, advance_time},
    protocol_fees::{Self, ProtocolFees, Referral, referral_owner, referral_stats}
};
use std::unit_test::assert_eq;
use sui::{
    clock::{Clock, Self},
    coin::Coin,
    test_scenario::{Self as test, Scenario, return_shared},
    test_utils::destroy
};
use deepbook::{math, constants};

#[test]
fun test_setup_ok() {
    let (mut test, admin_cap) = test_helpers::setup_test();
    let mut clock = clock::create_for_testing(test.ctx()); 

    test.next_tx(test_constants::admin());
    let referral_id;
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx(), &clock);
    let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(margin_constants::default_referral());
    assert!(shares == 0, 0);
    assert!(share_ms == 0, 0);
    assert!(last_update_timestamp == clock.timestamp_ms(), 0);

    test.next_tx(test_constants::user1());
    {
        referral_id = protocol_fees.mint_referral(&clock, test.ctx());
    };

    test.next_tx(test_constants::user1());
    {
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert!(shares == 0, 0);
        assert!(share_ms == 0, 0);
        assert!(last_update_timestamp == clock.timestamp_ms(), 0);

        let referral = test.take_shared_by_id<Referral>(referral_id);
        assert!(referral_owner(&referral) == test_constants::user1(), 0);
        let (shares, share_ms, last_update_timestamp) = referral_stats(&referral);
        assert!(shares == 0, 0);
        assert!(share_ms == 0, 0);
        assert!(last_update_timestamp == clock.timestamp_ms(), 0);

        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert!(shares == 0, 0);
        assert!(share_ms == 0, 0);
        assert!(last_update_timestamp == clock.timestamp_ms(), 0);

        return_shared(referral);
    };

    // increase shares
    let increase_shares = 100 * constants::float_scaling();
    test.next_tx(test_constants::user1());
    {
        clock.increment_for_testing(1000);
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert!(shares == 100 * constants::float_scaling(), 0);
        assert!(share_ms == 0, 0);
        assert!(last_update_timestamp == 1000, 0);
        assert!(protocol_fees.total_shares() == 100 * constants::float_scaling(), 0);

        clock.increment_for_testing(1000);
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert!(shares == 200 * constants::float_scaling(), 0);
        assert_eq!(share_ms, 100_000);
        assert!(share_ms == 100_000, 0);
        assert!(last_update_timestamp == 2000, 0);
        assert!(protocol_fees.total_shares() == 200 * constants::float_scaling(), 0);

        clock.increment_for_testing(1000);
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert_eq!(shares, 300 * constants::float_scaling());
        assert!(share_ms == 300_000, 0);
        assert!(last_update_timestamp == 3000, 0);
        assert!(protocol_fees.total_shares() == 300 * constants::float_scaling(), 0);

        clock.increment_for_testing(1000);
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert!(shares == 400 * constants::float_scaling(), 0);
        assert!(share_ms == 600_000, 0);
        assert!(last_update_timestamp == 4000, 0);
        assert!(protocol_fees.total_shares() == 400 * constants::float_scaling(), 0);
    };

    test.next_tx(test_constants::user1());
    {
        clock.increment_for_testing(1000);
        protocol_fees.decrease_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert_eq!(shares, 300 * constants::float_scaling());
        assert!(shares == 300 * constants::float_scaling(), 0);
        assert!(share_ms == 1_000_000, 0);
        assert!(last_update_timestamp == 5000, 0);
        assert!(protocol_fees.total_shares() == 300 * constants::float_scaling(), 0);

        clock.increment_for_testing(1000);
        protocol_fees.decrease_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        let (shares, share_ms, last_update_timestamp) = protocol_fees.referral_tracker(referral_id.to_address());
        assert_eq!(shares, 200 * constants::float_scaling());
        assert!(shares == 200 * constants::float_scaling(), 0);
        assert!(share_ms == 1_300_000, 0);
        assert!(last_update_timestamp == 6000, 0);
        assert!(protocol_fees.total_shares() == 200 * constants::float_scaling(), 0);
    };
    
    destroy(admin_cap);
    destroy(clock);
    destroy(protocol_fees);
    test.end();
}

#[test]
fun test_calculate_and_claim() {
    let (mut test, admin_cap) = test_helpers::setup_test();
    let mut clock = clock::create_for_testing(test.ctx()); 

    test.next_tx(test_constants::user1());
    let referral_id;
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx(), &clock);

    test.next_tx(test_constants::user1());
    {
        referral_id = protocol_fees.mint_referral(&clock, test.ctx());
    };

    test.next_tx(test_constants::user2());
    {
        let increase_shares = 100 * constants::float_scaling();
        let referral = test.take_shared_by_id<Referral>(referral_id);
        // increase referred shares by 100
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        // increase fees accrued by 2
        // since only user1 has referred shares, they get all fees
        protocol_fees.increase_fees_accrued(2 * constants::float_scaling());

        return_shared(referral);
    };

    test.next_tx(test_constants::user1());
    {
        clock.increment_for_testing(1000);
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&mut referral, &clock);
        assert_eq!(fees, 2 * constants::float_scaling());
        return_shared(referral);
    };

    // user2 refers more shares, more rewards added
    test.next_tx(test_constants::user2());
    {
        clock.increment_for_testing(1000);
        let increase_shares = 100 * constants::float_scaling();
        let referral = test.take_shared_by_id<Referral>(referral_id);
        // increase referred shares by 100
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        // increase fees accrued by 2
        // since only user1 has referred shares, they get all fees
        protocol_fees.increase_fees_accrued(2 * constants::float_scaling());
        return_shared(referral);
    };

    // user3 refers more shares for user1, more rewards added
    test.next_tx(test_constants::user3());
    {
        clock.increment_for_testing(1000);
        let increase_shares = 100 * constants::float_scaling();
        let referral = test.take_shared_by_id<Referral>(referral_id);
        protocol_fees.increase_shares(option::some(referral_id.to_address()), increase_shares, &clock);
        protocol_fees.increase_fees_accrued(2 * constants::float_scaling());
        return_shared(referral);
    };

    test.next_tx(test_constants::user1());
    {
        clock.increment_for_testing(10000);
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&mut referral, &clock);
        assert_eq!(fees, 4 * constants::float_scaling());
        return_shared(referral);
    };

    destroy(admin_cap);
    destroy(clock);
    destroy(protocol_fees);
    test.end();
}