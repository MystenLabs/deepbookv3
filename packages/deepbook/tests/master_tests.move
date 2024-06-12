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
    };
    use deepbook::{
        balance_manager::{Self, BalanceManager},
        vault::{DEEP},
        constants,
        pool_tests::{Self},
        pool::{Self, Pool},
        balance_manager_tests::{Self, USDC, SPAM},
        math
    };

    public struct ExpectedBalances has drop {
        sui: u64,
        usdc: u64,
        spam: u64,
        deep: u64,
    }

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    const NoError: u64 = 0;
    const EDuplicatePool: u64 = 1;
    const ENotEnoughFunds: u64 = 2;
    const EIncorrectStakeOwner: u64 = 3;
    const ECannotPropose: u64 = 4;
    const EIncorrectRebateClaimer: u64 = 5;

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

    #[test, expected_failure(abort_code = ::deepbook::balance_manager::EInvalidOwner)]
    fun test_master_incorrect_stake_owner_e(){
        test_master(EIncorrectStakeOwner)
    }

    #[test, expected_failure(abort_code = ::deepbook::state::ENoStake)]
    fun test_master_cannot_propose_e(){
        test_master(ECannotPropose)
    }

    #[test, expected_failure(abort_code = ::deepbook::balance_manager::EInvalidOwner)]
    fun test_master_incorrect_rebate_claimer_e(){
        test_master(EIncorrectRebateClaimer)
    }

    fun test_master(
        error_code: u64,
    ) {
        let mut test = begin(OWNER);
        let registry_id = pool_tests::setup_test(OWNER, &mut test);

        // Create two pools, one with SUI as base asset and one with SPAM as base asset
        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(OWNER, registry_id, &mut test);
        if (error_code == EDuplicatePool) {
            pool_tests::setup_pool_with_default_fees<USDC, SUI>(OWNER, registry_id, &mut test);
        };
        let pool2_id = pool_tests::setup_pool_with_default_fees<SPAM, USDC>(OWNER, registry_id, &mut test);
        let starting_balance = 10000 * constants::float_scaling();

        let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
            ALICE,
            starting_balance,
            &mut test
        );
        let bob_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
            BOB,
            starting_balance,
            &mut test
        );

        // variables to input into order
        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let big_quantity = 1_000_000 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;
        let mut maker_fee = constants::maker_fee();
        let taker_fee;
        let deep_multiplier = constants::deep_multiplier();
        let mut alice_balance = ExpectedBalances{
            sui: starting_balance,
            usdc: starting_balance,
            spam: starting_balance,
            deep: starting_balance,
        };
        let mut bob_balance = ExpectedBalances{
            sui: starting_balance,
            usdc: starting_balance,
            spam: starting_balance,
            deep: starting_balance,
        };

        // Epoch 0
        assert!(test.ctx().epoch() == 0, 0);

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
        alice_balance.usdc = alice_balance.usdc - math::mul(price, quantity);
        alice_balance.deep = alice_balance.deep - math::mul(
            math::mul(maker_fee, deep_multiplier),
            quantity
        );

        // Alice places ask order in pool 2
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

        alice_balance.spam = alice_balance.spam - quantity;
        alice_balance.deep = alice_balance.deep - math::mul(
            math::mul(maker_fee, deep_multiplier),
            quantity
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        // Alice stakes 100 DEEP into pool 1 during epoch 0 to be effective in epoch 1
        stake(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            200 * constants::float_scaling(),
            &mut test
        );
        alice_balance.deep = alice_balance.deep - 200 * constants::float_scaling();
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        if (error_code == EIncorrectStakeOwner) {
            stake(
                BOB,
                pool1_id,
                alice_balance_manager_id,
                200 * constants::float_scaling(),
                &mut test
            );
        };

        // Bob stakes 100 DEEP into pool 1 during epoch 1
        stake(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            100 * constants::float_scaling(),
            &mut test
        );
        bob_balance.deep = bob_balance.deep - 100 * constants::float_scaling();
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        if (error_code == ECannotPropose) {
            submit_proposal<SUI, USDC>(
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
        assert!(test.ctx().epoch() == 1, 0);

        submit_proposal<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            600_000,
            200_000,
            100 * constants::float_scaling(),
            &mut test
        );

        // Epoch 2 (Trades happen this epoch)
        // New trading fees are in effect for pool 1
        // Stakes are in effect for both Alice and Bob
        test.next_epoch(OWNER);
        assert!(test.ctx().epoch() == 2, 0);
        let old_maker_fee = maker_fee;
        maker_fee = 200_000;
        taker_fee = 600_000;

        // Alice should get refunded the previous fees for the order
        pool_tests::cancel_order<SUI, USDC>(
            pool1_id,
            ALICE,
            alice_balance_manager_id,
            order_info_1.order_id(),
            &mut test
        );
        alice_balance.usdc = alice_balance.usdc + math::mul(price, quantity);
        alice_balance.deep = alice_balance.deep + math::mul(
            math::mul(old_maker_fee, deep_multiplier),
            quantity
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        let client_order_id = 2;

        // Alice should pay new fees for the order, maker fee should be 0.02%
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
        alice_balance.usdc = alice_balance.usdc - math::mul(price, quantity);
        alice_balance.deep = alice_balance.deep - math::mul(
            math::mul(maker_fee, deep_multiplier),
            quantity
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        let executed_quantity = 1 * constants::float_scaling();
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
        bob_balance.sui = bob_balance.sui - executed_quantity;
        bob_balance.usdc = bob_balance.usdc + math::mul(price, executed_quantity);
        bob_balance.deep = bob_balance.deep - math::mul(
            math::mul(taker_fee, deep_multiplier),
            executed_quantity
        );
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        // Alice withdraws settled amounts twice, should only settle once
        withdraw_settled_amounts<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        alice_balance.sui = alice_balance.sui + executed_quantity;

        withdraw_settled_amounts<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        // Epoch 3, Alice proposes new fees, then unstakes
        // Bob proposes new fees as well after Alice unstakes, but quorum is based on old voting power
        // So neither proposal is passed
        // Stake of 200 deep should be returned to Alice, new proposal not passed
        test.next_epoch(OWNER);
        assert!(test.ctx().epoch() == 3, 0);

        submit_proposal<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            800_000,
            400_000,
            100 * constants::float_scaling(),
            &mut test
        );

        unstake<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        alice_balance.deep = alice_balance.deep + 200 * constants::float_scaling();
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        submit_proposal<SUI, USDC>(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            900_000,
            500_000,
            100 * constants::float_scaling(),
            &mut test
        );

        // Epoch 4
        // Alice earned the 0.08% total fee collected in epoch 2
        // Alice 0.02% maker fee + Bob 0.06% taker = 0.08% total fees
        // Alice will make a claim for the fees collected
        // Bob will get no rebates as he only executed taker orders
        test.next_epoch(OWNER);
        assert!(test.ctx().epoch() == 4, 0);

        claim_rebates<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        alice_balance.deep = alice_balance.deep + math::mul(800_000, deep_multiplier);
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        if (error_code == EIncorrectRebateClaimer) {
            claim_rebates<SUI, USDC>(
                BOB,
                pool1_id,
                alice_balance_manager_id,
                &mut test
            );
        };

        // Bob will get no rebates
        claim_rebates<SUI, USDC>(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            &mut test
        );
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        // Alice restakes 100 DEEP into pool 1 during epoch 4
        stake(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            100 * constants::float_scaling(),
            &mut test
        );
        alice_balance.deep = alice_balance.deep - 100 * constants::float_scaling();
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        // Advance to epoch 28
        let quantity = 1 * constants::float_scaling();
        let mut i = 23;
        // For 23 epochs, Alice and Bob will both make 1 quantity per epoch, and should get the full rebate
        // Alice will place a bid for quantity 1, bob will place ask for quantity 2, then alice will place a bid for quantity 1
        // Fees paid for each should be 0.02%+0.06% = 0.08%, multiplied by deep multiplier
        // Alice should have 48 more SUI at the end of the loop
        // Bob should have 96 more USDC at the end of the loop
        while (i > 0) {
            test.next_epoch(OWNER);
            execute_cross_trading<SUI, USDC>(
                pool1_id,
                alice_balance_manager_id,
                bob_balance_manager_id,
                client_order_id,
                order_type,
                price,
                quantity,
                is_bid,
                pay_with_deep,
                constants::max_u64(),
                &mut test
            );
            i = i - 1;
        };
        let taker_sui_traded = 23 * constants::float_scaling();
        let maker_sui_traded = 23 * constants::float_scaling();
        let quantity_sui_traded = taker_sui_traded + maker_sui_traded;
        alice_balance.sui = alice_balance.sui + quantity_sui_traded;
        alice_balance.usdc = alice_balance.usdc - math::mul(price, quantity_sui_traded);
        alice_balance.deep = alice_balance.deep - math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        bob_balance.sui = bob_balance.sui - quantity_sui_traded;
        bob_balance.usdc = bob_balance.usdc + math::mul(price, quantity_sui_traded);
        bob_balance.deep = bob_balance.deep - math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        test.next_epoch(OWNER);
        assert!(test.ctx().epoch() == 28, 0);

        // Alice claims rebates for the past 23 epochs
        claim_rebates<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        alice_balance.deep = alice_balance.deep + math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );

        // Bob claims rebates for the past 23 epochs
        claim_rebates<SUI, USDC>(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            &mut test
        );
        bob_balance.deep = bob_balance.deep + math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        // Same cross trading happens during epoch 28
        // quantity being traded is halved, each person will make 0.5 quantity and take 0.5 quantity
        let quantity = 500_000_000;
        execute_cross_trading<SUI, USDC>(
            pool1_id,
            alice_balance_manager_id,
            bob_balance_manager_id,
            client_order_id,
            order_type,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            constants::max_u64(),
            &mut test
        );
        let taker_sui_traded = quantity;
        let maker_sui_traded = quantity;
        let quantity_sui_traded = taker_sui_traded + maker_sui_traded;
        alice_balance.sui = alice_balance.sui + quantity_sui_traded;
        alice_balance.usdc = alice_balance.usdc - math::mul(price, quantity_sui_traded);
        alice_balance.deep = alice_balance.deep - math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        bob_balance.sui = bob_balance.sui - quantity_sui_traded;
        bob_balance.usdc = bob_balance.usdc + math::mul(price, quantity_sui_traded);
        bob_balance.deep = bob_balance.deep - math::mul(
            math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee),
            deep_multiplier
        );
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        // Epoch 29. Rebates should now be using the normal calculation
        test.next_epoch(OWNER);
        assert!(test.ctx().epoch() == 29, 0);
        claim_rebates<SUI, USDC>(
            ALICE,
            pool1_id,
            alice_balance_manager_id,
            &mut test
        );
        claim_rebates<SUI, USDC>(
            BOB,
            pool1_id,
            bob_balance_manager_id,
            &mut test
        );
        let fees_generated = math::mul(
            2 * (math::mul(taker_sui_traded, taker_fee) + math::mul(maker_sui_traded, maker_fee)),
            deep_multiplier
        );
        let historic_median = 2 * constants::float_scaling();
        let other_maker_liquidity = 500_000_000;
        let maker_rebate_percentage = if (historic_median > 0) {
            constants::float_scaling() - math::min(constants::float_scaling(), math::div(other_maker_liquidity, historic_median))
        } else {
            0
        }; // 75%

        let maker_volume_proportion = 500_000_000;
        let maker_fee_proportion = math::mul(maker_volume_proportion, fees_generated); // 4000000
        let maker_rebate = math::mul(maker_rebate_percentage, maker_fee_proportion); // 3000000
        alice_balance.deep = alice_balance.deep + maker_rebate;
        check_balance(
            alice_balance_manager_id,
            &alice_balance,
            &mut test
        );
        bob_balance.deep = bob_balance.deep + maker_rebate;
        check_balance(
            bob_balance_manager_id,
            &bob_balance,
            &mut test
        );

        end(test);
    }

    fun execute_cross_trading<BaseAsset, QuoteAsset>(
        pool_id: ID,
        balance_manager_id_1: ID,
        balance_manager_id_2: ID,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ) {
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            ALICE,
            pool_id,
            balance_manager_id_1,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            test,
        );
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            BOB,
            pool_id,
            balance_manager_id_2,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            2 * quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            test,
        );
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            ALICE,
            pool_id,
            balance_manager_id_1,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            test,
        );
        withdraw_settled_amounts<SUI, USDC>(
            BOB,
            pool_id,
            balance_manager_id_2,
            test
        );
    }

    fun claim_rebates<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        balance_manager_id: ID,
        test: &mut Scenario,
    ){
        test.next_tx(sender);
        {
            let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            let proof = my_manager.generate_proof_as_owner(test.ctx());
            pool::claim_rebates<BaseAsset, QuoteAsset>(
                &mut pool,
                &mut my_manager,
                &proof,
                test.ctx()
            );
            return_shared(pool);
            return_shared(my_manager);
        }
    }

    fun unstake<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        balance_manager_id: ID,
        test: &mut Scenario,
    ){
        test.next_tx(sender);
        {
            let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            // Get Proof from BalanceManager
            let trade_proof = my_manager.generate_proof_as_owner(test.ctx());

            pool::unstake<BaseAsset, QuoteAsset>(
                &mut pool,
                &mut my_manager,
                &trade_proof,
                test.ctx()
            );
            return_shared(pool);
            return_shared(my_manager);
        }
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
        balance_manager_id: ID,
        expected_balances: &ExpectedBalances,
        test: &mut Scenario,
    ) {
        test.next_tx(OWNER);
        {
            let my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            let sui = balance_manager::balance<SUI>(&my_manager);
            let usdc = balance_manager::balance<USDC>(&my_manager);
            let spam = balance_manager::balance<SPAM>(&my_manager);
            let deep = balance_manager::balance<DEEP>(&my_manager);
            assert!(sui == expected_balances.sui, 0);
            assert!(usdc == expected_balances.usdc, 0);
            assert!(spam == expected_balances.spam, 0);
            assert!(deep == expected_balances.deep, 0);

            return_shared(my_manager);
        }
    }

    #[allow(unused_function)]
    /// Debug function, remove after code completion
    fun check_balance_and_print(
        balance_manager_id: ID,
        expected_balances: &ExpectedBalances,
        test: &mut Scenario,
    ) {
        test.next_tx(OWNER);
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
            assert!(sui == expected_balances.sui, 0);
            assert!(usdc == expected_balances.usdc, 0);
            assert!(spam == expected_balances.spam, 0);
            assert!(deep == expected_balances.deep, 0);

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

    fun submit_proposal<BaseAsset, QuoteAsset>(
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
            let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let mut my_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
            // Get Proof from BalanceManager
            let trade_proof = my_manager.generate_proof_as_owner(test.ctx());

            pool::submit_proposal<BaseAsset, QuoteAsset>(
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
