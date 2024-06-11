// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::master_tests {
    use sui::{
        test_scenario::{
            Scenario,
            begin,
            end,
            return_shared,
        },
        sui::SUI,
        coin::mint_for_testing,
    };
    use deepbook::{
        balance_manager::{Self, BalanceManager, TradeCap},
        vault::{DEEP},
        registry::{Self},
        constants,
        pool_tests::{Self},
        pool::{Self, Pool},
        balance_manager_tests::{Self, USDC, SPAM}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    const NoError: u64 = 0;
    const EDuplicatePool: u64 = 1;
    const ENotEnoughFunds: u64 = 2;
    const ECannotPropose: u64 = 3;

    #[test]
    fun test_master_ok(){
        test_master(NoError)
    }

    #[test, expected_failure(abort_code = ::deepbook::registry::EPoolAlreadyExists)]
    fun test_master_duplicate_pool_e(){
        test_master(EDuplicatePool)
    }

    #[test, expected_failure(abort_code = ::deepbook::balance_manager::EBalanceManagerBalanceTooLow)]
    fun test_master_not_enough_funds_e(){
        test_master(ENotEnoughFunds)
    }

    #[test, expected_failure(abort_code = ::deepbook::state::ENoStake)]
    fun test_master_cannot_propose_e(){
        test_master(ECannotPropose)
    }

    fun test_master(
        error_code: u64,
    ) {
        let mut test = begin(OWNER);
        let registry_id = pool_tests::setup_test(OWNER, &mut test);
        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(OWNER, registry_id, &mut test);
        if (error_code == EDuplicatePool) {
            pool_tests::setup_pool_with_default_fees<USDC, SUI>(OWNER, registry_id, &mut test);
        };
        let pool2_id = pool_tests::setup_pool_with_default_fees<SPAM, USDC>(OWNER, registry_id, &mut test);
        let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
            ALICE,
            10000 * constants::float_scaling(),
            &mut test
        );
        let bob_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
            BOB,
            10000 * constants::float_scaling(),
            &mut test
        );

        // variables to input into order
        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let big_quantity = 100_000 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;

        // Epoch 0
        if (error_code == ENotEnoughFunds) {
            pool_tests::place_limit_order<SUI, USDC>(
                ALICE,
                pool1_id,
                alice_balance_manager_id,
                client_order_id,
                order_type,
                constants::self_matching_allowed(),
                price,
                big_quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &mut test,
            );
        };

        // Alice places bid order in pool 1
        let order_info_1 = pool_tests::place_limit_order<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
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

        // Alice place ask order in pool 2
        pool_tests::place_limit_order<SPAM, USDC>(
            ALICE,
            pool2_id,
            alice_balance_manager_id,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        check_balance(
            ALICE,
            alice_balance_manager_id,
            10000 * constants::float_scaling(),
            9998 * constants::float_scaling(),
            9999 * constants::float_scaling(),
            9999_990_000_000,
            &mut test
        );

        // Alice Stakes 100 DEEP into pool 1
        stake(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            100 * constants::float_scaling(),
            &mut test
        );

        check_balance(
            ALICE,
            alice_balance_manager_id,
            10000 * constants::float_scaling(),
            9998 * constants::float_scaling(),
            9999 * constants::float_scaling(),
            9_899_990_000_000,
            &mut test
        );

        if (error_code == ECannotPropose) {
            submit_proposal(
                ALICE,
                pool1_id,
                alice_balance_manager_id,
                600_000,
                200_000,
                100 * constants::float_scaling(),
                &mut test
            );
        };

        // Epoch 1
        // Alice now has a stake of 100 that's effective
        // Alice proposes a change to the maker fee for epoch 2
        // Governance changed maker fees to 0.02%, taker fees to 0.06%, same deep staking required
        test.next_epoch(OWNER);
        submit_proposal(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            600_000,
            200_000,
            100 * constants::float_scaling(),
            &mut test
        );

        // Epoch 2
        // New trading fees are in effect for pool 1
        test.next_epoch(OWNER);

        pool_tests::cancel_order<SUI, USDC>(
            pool1_id,
            ALICE,
            alice_balance_manager_id,
            order_info_1.order_id(),
            &mut test
        );

        // Alice should get refunded the previous fees for the order
        check_balance(
            ALICE,
            alice_balance_manager_id,
            10000 * constants::float_scaling(), // SUI
            10000 * constants::float_scaling(), // USDC
            9999 * constants::float_scaling(), // SPAM
            9_899_995_000_000, // DEEP
            &mut test
        );

        let client_order_id = 2;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;

        pool_tests::place_limit_order<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
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

        // Alice should pay new fees for the order
        check_balance(
            ALICE,
            alice_balance_manager_id,
            10000 * constants::float_scaling(), // SUI
            9998 * constants::float_scaling(), // USDC
            9999 * constants::float_scaling(), // SPAM
            9_899_993_000_000, // DEEP
            &mut test
        );

        let quantity = 100 * constants::float_scaling();

        // Bob places market ask order with large size in pool 1, only quantity 1 should be filled with Alice's bid order
        // Taker fee paid should be 0.06%
        pool_tests::place_market_order<SUI, USDC>(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            client_order_id,
            constants::self_matching_allowed(),
            quantity,
            !is_bid,
            pay_with_deep,
            &mut test,
        );

        check_balance(
            BOB,
            bob_balance_manager_id,
            9999 * constants::float_scaling(), // SUI
            10002 * constants::float_scaling(), // USDC
            10000 * constants::float_scaling(), // SPAM
            9_999_994_000_000, // DEEP
            &mut test
        );

        withdraw_settled_amounts<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );

        check_balance(
            ALICE,
            alice_balance_manager_id,
            10001 * constants::float_scaling(), // SUI
            9998 * constants::float_scaling(), // USDC
            9999 * constants::float_scaling(), // SPAM
            9_899_993_000_000, // DEEP
            &mut test
        );

        end(test);
    }

    fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        balance_manager_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let proof = my_manager.generate_proof_as_owner(test.ctx());
            pool::withdraw_settled_amounts<BaseAsset, QuoteAsset>(
                &mut pool,
                &mut my_manager,
                &proof
            );
            return_shared(my_manager);
            return_shared(pool);
        }
    }

    fun check_balance(
        sender: address,
        balance_manager_id: ID,
        expected_sui: u64,
        expected_usdc: u64,
        expected_spam: u64,
        expected_deep: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            let sui = balance_manager::balance<SUI>(&my_manager);
            let usdc = balance_manager::balance<USDC>(&my_manager);
            let spam = balance_manager::balance<SPAM>(&my_manager);
            let deep = balance_manager::balance<DEEP>(&my_manager);
            assert!(sui == expected_sui, 0);
            assert!(usdc == expected_usdc, 0);
            assert!(spam == expected_spam, 0);
            assert!(deep == expected_deep, 0);

            return_shared(my_manager);
        }
    }

    fun check_balance_and_print(
        sender: address,
        balance_manager_id: ID,
        expected_sui: u64,
        expected_usdc: u64,
        expected_spam: u64,
        expected_deep: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            let sui = balance_manager::balance<SUI>(&my_manager);
            let usdc = balance_manager::balance<USDC>(&my_manager);
            let spam = balance_manager::balance<SPAM>(&my_manager);
            let deep = balance_manager::balance<DEEP>(&my_manager);
            std::debug::print(&sui);
            std::debug::print(&usdc);
            std::debug::print(&spam);
            std::debug::print(&deep);
            assert!(sui == expected_sui, 0);
            assert!(usdc == expected_usdc, 0);
            assert!(spam == expected_spam, 0);
            assert!(deep == expected_deep, 0);

            return_shared(my_manager);
        }
    }

    fun stake(
        sender: address,
        pool_id: ID,
        balance_manager_id: ID,
        amount: u64,
        test: &mut Scenario,
    ){
        test.next_tx(sender);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            // Get Proof from BalanceManager
            let trade_proof = my_manager.generate_proof_as_owner(test.ctx());

            pool::stake<SUI, USDC>(
                &mut pool,
                &mut my_manager,
                &trade_proof,
                amount,
                test.ctx()
            );
            return_shared(pool);
            return_shared(my_manager);
        }
    }

    fun submit_proposal(
        sender: address,
        pool_id: ID,
        balance_manager_id: ID,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        test: &mut Scenario,
    ){
        test.next_tx(sender);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            // Get Proof from BalanceManager
            let trade_proof = my_manager.generate_proof_as_owner(test.ctx());

            pool::submit_proposal<SUI, USDC>(
                &mut pool,
                &mut my_manager,
                &trade_proof,
                taker_fee,
                maker_fee,
                stake_required,
                test.ctx()
            );
            return_shared(pool);
            return_shared(my_manager);
        }
    }
}
