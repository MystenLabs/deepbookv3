// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::referral_fees_tests;

use deepbook_margin::{constants, referral_fees::{Self, Referral}, test_constants, test_helpers};
use std::unit_test::assert_eq;
use sui::{test_scenario::return_shared, test_utils::destroy};

#[test]
fun test_referral_fees_setup() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    // 100 shares increased, 1 reward earned
    test.next_tx(test_constants::admin());
    let mut referral_fees = referral_fees::default_referral_fees(test.ctx());
    referral_fees.increase_shares(option::none(), 100 * constants::float_scaling());
    referral_fees.increase_fees_accrued(1 * constants::float_scaling());
    assert_eq!(referral_fees.total_shares(), 100 * constants::float_scaling());
    assert_eq!(referral_fees.fees_per_share(), 10_000_000);

    referral_fees.increase_shares(option::none(), 100 * constants::float_scaling());
    referral_fees.increase_fees_accrued(2 * constants::float_scaling());
    assert_eq!(referral_fees.total_shares(), 200 * constants::float_scaling());
    assert_eq!(referral_fees.fees_per_share(), 20_000_000);

    // so far we have 200 shares and 0.02 rewards per share
    // increase by 1000 and add 5 more rewards. 5 rewards distributed over 1200 total shares
    referral_fees.increase_shares(option::none(), 1000 * constants::float_scaling());
    referral_fees.increase_fees_accrued(5 * constants::float_scaling());
    assert_eq!(referral_fees.total_shares(), 1200 * constants::float_scaling());
    assert_eq!(referral_fees.fees_per_share(), 24_166_666);

    // decrease shares by 1100, add 10 rewards
    referral_fees.decrease_shares(option::none(), 1100 * constants::float_scaling());
    referral_fees.increase_fees_accrued(10 * constants::float_scaling());
    assert_eq!(referral_fees.total_shares(), 100 * constants::float_scaling());
    assert_eq!(referral_fees.fees_per_share(), 124_166_666);

    destroy(admin_cap);
    destroy(referral_fees);
    test.end();
}

#[test]
fun test_referral_fees_ok() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut referral_fees = referral_fees::default_referral_fees(test.ctx());

    let referral_id;
    test.next_tx(test_constants::user1());
    {
        referral_id = referral_fees.mint_referral(test.ctx());
    };

    test.next_tx(test_constants::user2());
    {
        referral_fees.increase_shares(
            option::some(referral_id.to_address()),
            100 * constants::float_scaling(),
        );
        referral_fees.increase_fees_accrued(100 * constants::float_scaling());
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(min_shares, 0);
        assert_eq!(referral_fees.fees_per_share(), 1_000_000_000);
    };

    test.next_tx(test_constants::user1());
    {
        // first claim checks min_shares, initially set to 0. first claim has no fees.
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(min_shares, 100 * constants::float_scaling());

        // now min_shares is 100, but last_fees_per_share is also updated. If we try to claim again, it should have no fees.
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(min_shares, 100 * constants::float_scaling());

        return_shared(referral);
    };

    test.next_tx(test_constants::user2());
    {
        // user2 adds more shares
        referral_fees.increase_shares(
            option::some(referral_id.to_address()),
            100 * constants::float_scaling(),
        );
        referral_fees.increase_fees_accrued(100 * constants::float_scaling());
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(min_shares, 100 * constants::float_scaling());
    };

    test.next_tx(test_constants::user1());
    {
        // user1 claims fees. min_shares is 100, last_fees_per_share is 1_000_000_000, fees_per_share is now 1_500_000_000
        // they get 100 shares * (1_500_000_000 - 1_000_000_000) = 100 * 500_000_000 = 50_000_000_000
        assert_eq!(referral_fees.fees_per_share(), 1_500_000_000);
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 50_000_000_000);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(min_shares, 200 * constants::float_scaling());

        // if we try to claim again, it should be 0
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(min_shares, 200 * constants::float_scaling());

        return_shared(referral);
    };

    // increase shares, accrue fees, decrease shares before the claim.
    // referrer should only have 200 shares exposed to fees.
    test.next_tx(test_constants::user1());
    {
        referral_fees.increase_shares(
            option::some(referral_id.to_address()),
            100 * constants::float_scaling(),
        );
        referral_fees.increase_fees_accrued(100 * constants::float_scaling());
        referral_fees.decrease_shares(
            option::some(referral_id.to_address()),
            100 * constants::float_scaling(),
        );

        // additional 100 rewards for 300 shares
        assert_eq!(referral_fees.fees_per_share(), 1_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        // fees_per_share went from 1.5 -> 1.833 since last claim. 200 shares exposed. 200 * (1.833 - 1.5) = 200 * 0.333 = 66.6
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 66_666_666_600);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(min_shares, 200 * constants::float_scaling());

        return_shared(referral);
    };

    // decrease referred shares to 0, then increase by 1000. Add 1000 rewards.
    // since referrer didn't claim, their min_shares is 0, they get 0 rewards.
    test.next_tx(test_constants::user1());
    {
        referral_fees.decrease_shares(
            option::some(referral_id.to_address()),
            200 * constants::float_scaling(),
        );
        referral_fees.increase_shares(
            option::some(referral_id.to_address()),
            1000 * constants::float_scaling(),
        );
        referral_fees.increase_fees_accrued(1000 * constants::float_scaling());
        // 1000 rewards for 1000 shares. 1.833 -> 2.833
        assert_eq!(referral_fees.fees_per_share(), 2_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(min_shares, 0);
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(min_shares, 1000 * constants::float_scaling());

        return_shared(referral);
    };

    // add 1000 more rewards. 2.833 -> 3.833
    // referrer now has 1000 shares exposed. 1000 * (3.833 - 2.833) = 1000 * 1 = 1000
    test.next_tx(test_constants::user1());
    {
        referral_fees.increase_fees_accrued(1000 * constants::float_scaling());
        assert_eq!(referral_fees.fees_per_share(), 3_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
        assert_eq!(fees, 1000 * constants::float_scaling());
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(min_shares, 1000 * constants::float_scaling());

        return_shared(referral);
    };

    destroy(admin_cap);
    destroy(referral_fees);
    test.end();
}

#[test]
fun test_referra_fees_many() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut referral_fees = referral_fees::default_referral_fees(test.ctx());

    // create 10 referrals, each with 1000 shares referred.
    // total shares is 10 * 1000 = 10000
    let mut i = 0;
    let mut referral_ids = vector::empty();
    while (i < 10) {
        let referral_id = referral_fees.mint_referral(test.ctx());
        referral_ids.push_back(referral_id);
        referral_fees.increase_shares(
            option::some(referral_id.to_address()),
            1000 * constants::float_scaling(),
        );
        let (current_shares, min_shares) = referral_fees.referral_tracker(referral_id.to_address());
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(min_shares, 0);

        i = i + 1;
    };

    // claim and set min_shares to current_shares
    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            let mut referral = test.take_shared_by_id<Referral>(referral_ids[i]);
            let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
            assert_eq!(fees, 0);
            let (current_shares, min_shares) = referral_fees.referral_tracker(referral_ids[
                i,
            ].to_address());
            assert_eq!(current_shares, 1000 * constants::float_scaling());
            assert_eq!(min_shares, 1000 * constants::float_scaling());
            return_shared(referral);
            i = i + 1;
        };
    };

    // add 5000 rewards. 10000 shares. 0 -> 0.5
    test.next_tx(test_constants::admin());
    {
        referral_fees.increase_fees_accrued(5000 * constants::float_scaling());
        assert_eq!(referral_fees.fees_per_share(), 500_000_000);
    };

    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            let mut referral = test.take_shared_by_id<Referral>(referral_ids[i]);
            let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
            assert_eq!(fees, 500 * constants::float_scaling());
            let (current_shares, min_shares) = referral_fees.referral_tracker(referral_ids[
                i,
            ].to_address());
            assert_eq!(current_shares, 1000 * constants::float_scaling());
            assert_eq!(min_shares, 1000 * constants::float_scaling());
            return_shared(referral);
            i = i + 1;
        };
    };

    // reduce all even referrer's shares by 1000, down to 0.
    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            if (i % 2 == 0) {
                referral_fees.decrease_shares(
                    option::some(referral_ids[i].to_address()),
                    1000 * constants::float_scaling(),
                );
            };
            i = i + 1;
        };
    };

    // add 5000 rewards. 5000 outstanding shares. 0.5 -> 1.5
    test.next_tx(test_constants::admin());
    {
        referral_fees.increase_fees_accrued(5000 * constants::float_scaling());
        assert_eq!(referral_fees.fees_per_share(), 1_500_000_000);
    };

    // referrers that were reduced to 0 shoul get 0 rewards.
    // rest of them should get 1000 * (1.5 - 0.5) = 1000 * 1 = 1000
    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            let mut referral = test.take_shared_by_id<Referral>(referral_ids[i]);
            let fees = referral_fees.calculate_and_claim(&mut referral, test.ctx());
            let (current_shares, min_shares) = referral_fees.referral_tracker(referral_ids[
                i,
            ].to_address());
            if (i % 2 == 0) {
                assert_eq!(fees, 0);
                assert_eq!(min_shares, 0);
                assert_eq!(current_shares, 0);
            } else {
                assert_eq!(fees, 1000 * constants::float_scaling());
                assert_eq!(min_shares, 1000 * constants::float_scaling());
                assert_eq!(current_shares, 1000 * constants::float_scaling());
            };
            return_shared(referral);
            i = i + 1;
        };
    };

    destroy(admin_cap);
    destroy(referral_fees);
    test.end();
}

#[test, expected_failure(abort_code = referral_fees::ENotOwner)]
fun test_referral_fees_not_owner_e() {
    let (mut test, _admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut referral_fees = referral_fees::default_referral_fees(test.ctx());

    let referral_id;
    test.next_tx(test_constants::user1());
    {
        referral_id = referral_fees.mint_referral(test.ctx());
    };

    test.next_tx(test_constants::user2());
    {
        let mut referral = test.take_shared_by_id<Referral>(referral_id);
        referral_fees.calculate_and_claim(&mut referral, test.ctx());
    };

    abort (0)
}

#[test, expected_failure(abort_code = referral_fees::EInvalidFeesAccrued)]
fun test_referral_fees_invalid_fees_accrued_e() {
    let (mut test, _admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut referral_fees = referral_fees::default_referral_fees(test.ctx());
    referral_fees.increase_fees_accrued(1);

    abort (0)
}
