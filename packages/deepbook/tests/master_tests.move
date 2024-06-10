// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::master_tests {
    use sui::{
        test_scenario::{Self as test, Scenario, begin, end},
        sui::SUI,
        coin::mint_for_testing,
    };
    use deepbook::{
        balance_manager::{Self, BalanceManager, TradeCap},
        vault::{DEEP},
        registry::{Self},
        constants,
        pool_tests,
    };

    public struct SPAM has store {}
    public struct USDC has store {}

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    #[test]
    fun test_master_ok(){
        test_master()
    }

    fun test_master() {
        let mut test = begin(OWNER);
        let pool1_id = pool_tests::setup_test(OWNER, &mut test);
        let pool2_id = pool_tests::setup_test(OWNER, &mut test);
        let balance_manager_id = pool_tests::create_acct_and_share_with_funds(ALICE, 10 * constants::float_scaling(), &mut test);

        // variables to input into order
        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;

        pool_tests::place_limit_order(
            pool1_id,
            ALICE,
            balance_manager_id,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        pool_tests::place_limit_order(
            pool2_id,
            ALICE,
            balance_manager_id,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );


        end(test);
    }

    // fun check_balance_ok(
    //     balance_manager_id: ID,
    //     expected_deep: u64,
    //     expected_usdc: u64,
    //     expected_spam: u64,
    //     test: &mut Scenario,
    // ) {
    //     let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    //     let acct = balance_manager::balance<DEEP>();
    //     test.assert_eq(acct.deep, expected_deep);
    //     test.assert_eq(acct.usdc, expected_usdc);
    //     test.assert_eq(acct.spam, expected_spam);
    // }
    // )
}
