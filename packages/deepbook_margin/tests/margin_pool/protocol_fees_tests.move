// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_margin::protocol_fees_tests;

use deepbook::constants;
use deepbook_margin::{protocol_fees::{Self, SupplyReferral}, test_constants, test_helpers};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

#[test]
fun test_referral_fees_setup() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    // 100 shares increased, 1 reward earned
    test.next_tx(test_constants::admin());
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx());
    protocol_fees.increase_shares(option::none(), 100 * constants::float_scaling());
    protocol_fees.increase_fees_accrued(
        test_constants::test_margin_pool_id(),
        2 * constants::float_scaling(),
    );
    assert_eq!(protocol_fees.total_shares(), 100 * constants::float_scaling());
    assert_eq!(protocol_fees.fees_per_share(), 10_000_000);

    protocol_fees.increase_shares(option::none(), 100 * constants::float_scaling());
    protocol_fees.increase_fees_accrued(
        test_constants::test_margin_pool_id(),
        4 * constants::float_scaling(),
    );
    assert_eq!(protocol_fees.total_shares(), 200 * constants::float_scaling());
    assert_eq!(protocol_fees.fees_per_share(), 20_000_000);

    // so far we have 200 shares and 0.02 rewards per share
    // increase by 1000 and add 5 more rewards. 5 rewards distributed over 1200 total shares
    protocol_fees.increase_shares(option::none(), 1000 * constants::float_scaling());
    protocol_fees.increase_fees_accrued(
        test_constants::test_margin_pool_id(),
        10 * constants::float_scaling(),
    );
    assert_eq!(protocol_fees.total_shares(), 1200 * constants::float_scaling());
    assert_eq!(protocol_fees.fees_per_share(), 24_166_666);

    // decrease shares by 1100, add 10 rewards
    protocol_fees.decrease_shares(option::none(), 1100 * constants::float_scaling());
    protocol_fees.increase_fees_accrued(
        test_constants::test_margin_pool_id(),
        20 * constants::float_scaling(),
    );
    assert_eq!(protocol_fees.total_shares(), 100 * constants::float_scaling());
    assert_eq!(protocol_fees.fees_per_share(), 124_166_666);

    destroy(admin_cap);
    destroy(protocol_fees);
    test.end();
}

#[test]
fun test_referral_fees_ok() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx());

    let referral_id;
    test.next_tx(test_constants::user1());
    {
        referral_id = protocol_fees.mint_supply_referral(test.ctx());
    };

    test.next_tx(test_constants::user2());
    {
        protocol_fees.increase_shares(
            option::some(referral_id),
            100 * constants::float_scaling(),
        );
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            200 * constants::float_scaling(),
        );
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 100 * constants::float_scaling());
        assert_eq!(protocol_fees.fees_per_share(), 1_000_000_000);
    };

    test.next_tx(test_constants::user1());
    {
        // claim fees
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 100 * constants::float_scaling());
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        // claim fees again
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 100 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        return_shared(referral);
    };

    test.next_tx(test_constants::user2());
    {
        // user2 adds more shares
        protocol_fees.increase_shares(
            option::some(referral_id),
            100 * constants::float_scaling(),
        );
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            200 * constants::float_scaling(),
        );
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 100 * constants::float_scaling());
    };

    test.next_tx(test_constants::user1());
    {
        // user1 claims fees. current_shares is 200, last_fees_per_share is 1_000_000_000, fees_per_share is now 1_500_000_000
        // they get 200 shares * (1_500_000_000 - 1_000_000_000) = 200 * 500_000_000 = 100_000_000_000
        assert_eq!(protocol_fees.fees_per_share(), 1_500_000_000);
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 100_000_000_000);
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        // if we try to claim again, it should be 0
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 0);
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        return_shared(referral);
    };

    // increase shares, accrue fees, decrease shares before the claim.
    // referrer should only have 200 shares exposed to fees.
    test.next_tx(test_constants::user1());
    {
        protocol_fees.increase_shares(
            option::some(referral_id),
            100 * constants::float_scaling(),
        );
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            200 * constants::float_scaling(),
        );
        protocol_fees.decrease_shares(
            option::some(referral_id),
            100 * constants::float_scaling(),
        );

        // additional 100 rewards for 300 shares
        assert_eq!(protocol_fees.fees_per_share(), 1_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        // fees_per_share went from 1.5 -> 1.833 since last claim. 200 shares exposed. 200 * (1.833 - 1.5) = 200 * 0.333 = 66.6
        // while current_shares was 300, fees_per_share went from 1.5 -> 1.833, so 300 shares * (1.833 - 1.5) = 300 * 0.333 = 99.9
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 99_999_999_900);
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 200 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        return_shared(referral);
    };

    // decrease referred shares to 0, then increase by 1000. Add 1000 rewards.
    test.next_tx(test_constants::user1());
    {
        protocol_fees.decrease_shares(
            option::some(referral_id),
            200 * constants::float_scaling(),
        );
        protocol_fees.increase_shares(
            option::some(referral_id),
            1000 * constants::float_scaling(),
        );
        // current_shares went from 200 to 0 then to 1000. Then 2000 fees were accrued.
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            2000 * constants::float_scaling(),
        );
        // 1000 rewards for 1000 shares. 1.833 -> 2.833
        assert_eq!(protocol_fees.fees_per_share(), 2_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        // current_shares is 1000, fees_per_share 1.833 -> 2.833. unclaimed_fees is 1000 * (2.833 - 1.833) = 1000 * 1 = 1000
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 1000 * constants::float_scaling());
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 1000 * constants::float_scaling());
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        return_shared(referral);
    };

    // add 1000 more rewards. 2.833 -> 3.833
    // referrer now has 1000 shares exposed. 1000 * (3.833 - 2.833) = 1000 * 1 = 1000
    test.next_tx(test_constants::user1());
    {
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            2000 * constants::float_scaling(),
        );
        assert_eq!(protocol_fees.fees_per_share(), 3_833_333_333);
    };

    test.next_tx(test_constants::user1());
    {
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
        assert_eq!(fees, 1000 * constants::float_scaling());
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        return_shared(referral);
    };

    destroy(admin_cap);
    destroy(protocol_fees);
    test.end();
}

#[test]
fun test_referra_fees_many() {
    let (mut test, admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx());

    // create 10 referrals, each with 1000 shares referred.
    // total shares is 10 * 1000 = 10000
    let mut i = 0;
    let mut referral_ids = vector::empty();
    while (i < 10) {
        let referral_id = protocol_fees.mint_supply_referral(test.ctx());
        referral_ids.push_back(referral_id);
        protocol_fees.increase_shares(
            option::some(referral_id),
            1000 * constants::float_scaling(),
        );
        let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_id);
        assert_eq!(current_shares, 1000 * constants::float_scaling());
        assert_eq!(unclaimed_fees, 0);

        i = i + 1;
    };

    // add 5000 rewards. 10000 shares. 0 -> 0.5
    test.next_tx(test_constants::admin());
    {
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            10000 * constants::float_scaling(),
        );
        assert_eq!(protocol_fees.fees_per_share(), 500_000_000);
    };

    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            let referral = test.take_shared_by_id<SupplyReferral>(referral_ids[i]);
            let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
            assert_eq!(fees, 500 * constants::float_scaling());
            let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_ids[i]);
            assert_eq!(current_shares, 1000 * constants::float_scaling());
            assert_eq!(unclaimed_fees, 0);
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
                protocol_fees.decrease_shares(
                    option::some(referral_ids[i]),
                    1000 * constants::float_scaling(),
                );
            };
            i = i + 1;
        };
    };

    // add 5000 rewards. 5000 outstanding shares. 0.5 -> 1.5
    test.next_tx(test_constants::admin());
    {
        protocol_fees.increase_fees_accrued(
            test_constants::test_margin_pool_id(),
            10000 * constants::float_scaling(),
        );
        assert_eq!(protocol_fees.fees_per_share(), 1_500_000_000);
    };

    // referrers that were reduced to 0 shoul get 0 rewards.
    // rest of them should get 1000 * (1.5 - 0.5) = 1000 * 1 = 1000
    test.next_tx(test_constants::admin());
    {
        i = 0;
        while (i < 10) {
            let referral = test.take_shared_by_id<SupplyReferral>(referral_ids[i]);
            let fees = protocol_fees.calculate_and_claim(&referral, test.ctx());
            let (current_shares, unclaimed_fees) = protocol_fees.referral_tracker(referral_ids[i]);
            if (i % 2 == 0) {
                assert_eq!(fees, 0);
                assert_eq!(unclaimed_fees, 0);
                assert_eq!(current_shares, 0);
            } else {
                assert_eq!(fees, 1000 * constants::float_scaling());
                assert_eq!(unclaimed_fees, 0);
                assert_eq!(current_shares, 1000 * constants::float_scaling());
            };
            return_shared(referral);
            i = i + 1;
        };
    };

    destroy(admin_cap);
    destroy(protocol_fees);
    test.end();
}

#[test, expected_failure(abort_code = protocol_fees::ENotOwner)]
fun test_referral_fees_not_owner_e() {
    let (mut test, _admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx());

    let referral_id;
    test.next_tx(test_constants::user1());
    {
        referral_id = protocol_fees.mint_supply_referral(test.ctx());
    };

    test.next_tx(test_constants::user2());
    {
        let referral = test.take_shared_by_id<SupplyReferral>(referral_id);
        protocol_fees.calculate_and_claim(&referral, test.ctx());
    };

    abort
}

#[test]
fun test_referral_fees_redistributed_when_no_shares() {
    let (mut test, _admin_cap) = test_helpers::setup_test();

    test.next_tx(test_constants::admin());
    let mut protocol_fees = protocol_fees::default_protocol_fees(test.ctx());

    let fees_accrued = 1000;
    protocol_fees.increase_fees_accrued(test_constants::test_margin_pool_id(), fees_accrued);

    let expected_protocol = 500;
    let expected_maintainer = 500;

    let actual_protocol = protocol_fees.protocol_fees();
    let actual_maintainer = protocol_fees.maintainer_fees();

    assert_eq!(actual_protocol, expected_protocol);
    assert_eq!(actual_maintainer, expected_maintainer);
    assert_eq!(protocol_fees.total_shares(), 0);

    destroy(protocol_fees);
    destroy(_admin_cap);
    test.end();
}
