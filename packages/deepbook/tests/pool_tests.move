// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::pool_tests {
    use sui::{
        clock::{Self, Clock},
        test_scenario::{
            Scenario,
            begin,
            end,
            return_shared,
        },
        coin::{Self, Coin},
        sui::SUI,
        coin::mint_for_testing,
        test_utils,
    };

    use deepbook::{
        pool::{Self, Pool},
        vault::DEEP,
        balance_manager::{Self, BalanceManager},
        order::{Order},
        order_info::OrderInfo,
        big_vector::BigVector,
        math,
        registry,
        constants,
        utils,
        // balance_manager_tests::create_acct_and_share_with_funds as create_acct_and_share_with_funds,
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    public struct USDC {}
    public struct SPAM {}

    #[test]
    fun test_place_order_bid() {
        place_order_ok(true);
    }

    #[test]
    fun test_place_order_ask() {
        place_order_ok(false);
    }

    #[test]
    fun test_place_and_cancel_order_bid() {
        place_and_cancel_order_ok(true);
    }

    #[test]
    fun test_place_and_cancel_order_ask() {
        place_and_cancel_order_ok(false);
    }

    #[test]
    fun test_place_then_fill_bid_ask() {
        place_then_fill(
            true,
            constants::no_restriction(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::filled()
        );
    }

    #[test]
    fun test_place_then_fill_ask_bid() {
        place_then_fill(
            false,
            constants::no_restriction(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::filled()
        );
    }

    #[test]
    fun test_place_then_ioc_bid_ask() {
        place_then_fill(
            true,
            constants::immediate_or_cancel(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::filled()
        );
    }

    #[test]
    fun test_place_then_ioc_ask_bid() {
        place_then_fill(
            false,
            constants::immediate_or_cancel(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::filled()
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_place_then_ioc_no_fill_bid_ask_order_removed_e() {
        place_then_no_fill(
            true,
            constants::immediate_or_cancel(),
            0,
            0,
            0,
            constants::canceled()
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_place_then_ioc_no_fill_ask_bid_order_removed_e() {
        place_then_no_fill(
            false,
            constants::immediate_or_cancel(),
            0,
            0,
            0,
            constants::canceled()
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_expired_order_removed_bid_ask_e(){
        place_order_expire_timestamp_e(
            true,
            constants::no_restriction(),
            0,
            0,
            0,
            constants::live(),
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_expired_order_removed_ask_bid_e(){
        place_order_expire_timestamp_e(
            false,
            constants::no_restriction(),
            0,
            0,
            0,
            constants::live(),
        );
    }

    #[test]
    fun test_partial_fill_order_bid() {
        partial_fill_order(
            true,
            constants::no_restriction(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::partially_filled()
        );
    }

    #[test]
    fun test_partial_fill_order_ask() {
        partial_fill_order(
            false,
            constants::no_restriction(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_fee(), constants::deep_multiplier()),
            constants::partially_filled()
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EOrderBelowMinimumSize)]
    fun test_invalid_order_quantity_e() {
        place_with_price_quantity(
            2 * constants::float_scaling(),
            0
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidLotSize)]
    fun test_invalid_lot_size_e() {
        place_with_price_quantity(
            2 * constants::float_scaling(),
            1_000_000_100,
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
    fun test_invalid_tick_size_e() {
        place_with_price_quantity(
            2_000_000_100,
            1 * constants::float_scaling(),
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
    fun test_price_above_max_e() {
        place_with_price_quantity(
            constants::max_u64(),
            1 * constants::float_scaling(),
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EOrderInvalidPrice)]
    fun test_price_below_min_e() {
        place_with_price_quantity(
            0,
            1 * constants::float_scaling(),
        );
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::ESelfMatchingCancelTaker)]
    fun test_self_matching_cancel_taker_bid() {
        test_self_matching_cancel_taker(true);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::ESelfMatchingCancelTaker)]
    fun test_self_matching_cancel_taker_ask() {
        test_self_matching_cancel_taker(false);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_self_matching_cancel_maker_bid() {
        test_self_matching_cancel_maker(true);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_self_matching_cancel_maker_ask() {
        test_self_matching_cancel_maker(false);
    }

    #[test]
    fun test_swap_exact_amount_bid_ask() {
        test_swap_exact_amount(true);
    }

    #[test]
    fun test_swap_exact_amount_ask_bid() {
        test_swap_exact_amount(false);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_cancel_all_orders_bid() {
        test_cancel_all_orders(true);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun test_cancel_all_orders_ask() {
        test_cancel_all_orders(false);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EPOSTOrderCrossesOrderbook)]
    fun test_post_only_bid_e() {
        test_post_only(true, true);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EPOSTOrderCrossesOrderbook)]
    fun test_post_only_ask_e() {
        test_post_only(false, true);
    }

    #[test]
    fun test_post_only_bid_ok() {
        test_post_only(true, false);
    }

    #[test]
    fun test_post_only_ask_ok() {
        test_post_only(false, false);
    }

    #[test]
    fun test_crossing_multiple_orders_bid_ok() {
        test_crossing_multiple(true, 3)
    }

    #[test]
    fun test_crossing_multiple_orders_ask_ok() {
        test_crossing_multiple(false, 3)
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EFOKOrderCannotBeFullyFilled)]
    fun test_fill_or_kill_bid_e() {
        test_fill_or_kill(true, false);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EFOKOrderCannotBeFullyFilled)]
    fun test_fill_or_kill_ask_e() {
        test_fill_or_kill(false, false);
    }

    #[test]
    fun test_fill_or_kill_bid_ok() {
        test_fill_or_kill(true, true);
    }

    #[test]
    fun test_fill_or_kill_ask_ok() {
        test_fill_or_kill(false, true);
    }

    #[test]
    fun test_market_order_bid_then_ask_ok() {
        test_market_order(true);
    }

    #[test]
    fun test_market_order_ask_then_bid_ok() {
        test_market_order(false);
    }

    #[test]
    fun test_mid_price_ok() {
        test_mid_price();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_bid_ok(){
        test_swap_exact_not_fully_filled(true);
    }

    #[test]
    fun test_swap_exact_not_fully_filled_ask_ok(){
        test_swap_exact_not_fully_filled(false);
    }

    /// Helper function to share a clock and a pool with default values
    public(package) fun setup_test(
        sender: address,
        test: &mut Scenario,
    ): ID {
        let pool_id = setup_pool_with_default_fees<SUI, USDC>(
            constants::tick_size(), // tick size
            constants::lot_size(), // lot size
            constants::min_size(), // min size
            test,
            sender,
        );
        share_clock(test);

        pool_id
    }

    /// Place a limit order
    public(package) fun place_limit_order(
        pool_id: ID,
        trader: address,
        balance_manager_id: ID,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ): OrderInfo {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);

            // Get Proof from BalanceManager
            let proof = balance_manager.generate_proof_as_owner(test.ctx());

            // Place order in pool
            let order_info = pool.place_limit_order<SUI, USDC>(
                &mut balance_manager,
                &proof,
                client_order_id,
                order_type,
                self_matching_option,
                price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(balance_manager);

            order_info
        }
    }

    /// Place an order
    public(package) fun place_market_order(
        pool_id: ID,
        trader: address,
        balance_manager_id: ID,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        test: &mut Scenario,
    ): OrderInfo {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);

            // Get Proof from BalanceManager
            let proof = balance_manager.generate_proof_as_owner(test.ctx());

            // Place order in pool
            let order_info = pool.place_market_order<SUI, USDC>(
                &mut balance_manager,
                &proof,
                client_order_id,
                self_matching_option,
                quantity,
                is_bid,
                pay_with_deep,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(balance_manager);

            order_info
        }
    }

    public(package) fun create_acct_and_share_with_funds(
        sender: address,
        amount_to_deposit: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut acct = balance_manager::new(test.ctx());
            deposit_into_account<SUI>(&mut acct, amount_to_deposit, test);
            deposit_into_account<SPAM>(&mut acct, amount_to_deposit, test);
            deposit_into_account<USDC>(&mut acct, amount_to_deposit, test);
            deposit_into_account<DEEP>(&mut acct, amount_to_deposit, test);
            let id = object::id(&acct);
            acct.share();

            id
        }
    }

    /// Alice places a bid order, Bob places a swap_exact_amount order
    /// Make sure the assets returned to Bob are correct
    /// When swap is not fully filled, assets are returned correctly
    /// Make sure expired orders are skipped over
    fun test_swap_exact_not_fully_filled(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let alice_client_order_id = 1;
        let alice_price = 3 * constants::float_scaling();
        let alice_quantity = 1 * constants::float_scaling();
        let expired_price = if (is_bid) {
            3 * constants::float_scaling()
        } else {
            1 * constants::float_scaling()
        };
        let expire_timestamp = constants::max_u64();
        let expire_timestamp_e = 100;
        let pay_with_deep = true;
        let residual = constants::lot_size() - 1;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            expired_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp_e,
            &mut test,
        );

        set_time(200, &mut test);

        let base_in = if (is_bid) {
            2 * constants::float_scaling() + residual
        } else {
            0
        };
        let quote_in = if (is_bid) {
            0
        } else {
            4 * constants::float_scaling() + residual
        };
        let deep_in = math::mul(constants::deep_multiplier(), constants::taker_fee()) + residual;

        let (base_out, quote_out, deep_out) = place_swap_exact_amount_order(
            pool_id,
            BOB,
            base_in,
            quote_in,
            deep_in,
            &mut test,
        );

        if (is_bid) {
            assert!(base_out.value() == 1 * constants::float_scaling() + residual, constants::e_order_info_mismatch());
            assert!(quote_out.value() == 3 * constants::float_scaling(), constants::e_order_info_mismatch());
        } else {
            assert!(base_out.value() == 1 * constants::float_scaling(), constants::e_order_info_mismatch());
            assert!(quote_out.value() == 1 * constants::float_scaling() + residual, constants::e_order_info_mismatch());
        };

        assert!(deep_out.value() == residual, constants::e_order_info_mismatch());

        base_out.burn_for_testing();
        quote_out.burn_for_testing();
        deep_out.burn_for_testing();

        end(test);
    }

    /// Test getting the mid price of the order book
    /// Expired orders are skipped
    fun test_mid_price() {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let price_bid_1 = 1 * constants::float_scaling();
        let price_bid_best = 2 * constants::float_scaling();
        let price_bid_expired = 2_200_000_000;
        let price_ask_1 = 6 * constants::float_scaling();
        let price_ask_best = 5 * constants::float_scaling();
        let price_ask_expired = 3_200_000_000;
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let expire_timestamp_e = 100;
        let pay_with_deep = true;
        let is_bid = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_bid_1,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_bid_best,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_bid_expired,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp_e,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_ask_1,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_ask_best,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price_ask_expired,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp_e,
            &mut test,
        );

        let expected_mid_price = (price_bid_expired + price_ask_expired) / 2;
        assert!(get_mid_price(pool_id, &mut test) == expected_mid_price, constants::e_incorrect_mid_price());

        set_time(200, &mut test);
        let expected_mid_price = (price_bid_best + price_ask_best) / 2;
        assert!(get_mid_price(pool_id, &mut test) == expected_mid_price, constants::e_incorrect_mid_price());

        end(test);
    }

    /// Places 3 orders at price 1, 2, 3 with quantity 1
    /// Market order of quantity 1.5 should fill one order completely, one partially, and one not at all
    /// Order 3 is fully filled for bid orders then ask market order
    /// Order 1 is fully filled for ask orders then bid market order
    /// Order 2 is partially filled for both
    fun test_market_order(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let base_price = constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;
        let mut i = 0;
        let num_orders = 3;
        let partial_order_client_id = 2;
        let full_order_client_id = if (is_bid) {
            1
        } else {
            3
        };
        let mut partial_order_id = 0;
        let mut full_order_id = 0;

        while (i < num_orders) {
            let order_info = place_limit_order(
                pool_id,
                ALICE,
                balance_manager_id_alice,
                client_order_id + i,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (client_order_id + i) * base_price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &mut test,
            );
            if (order_info.client_order_id() == full_order_client_id) {
                full_order_id = order_info.order_id();
            };
            if (order_info.client_order_id() == partial_order_client_id) {
                partial_order_id = order_info.order_id();
            };
            i = i + 1;
        };

        let client_order_id = num_orders + 1;
        let fee_is_deep = true;
        let quantity_2 = 1_500_000_000;
        let price = if (is_bid) {
            constants::min_price()
        } else {
            constants::max_price()
        };

        let order_info = place_market_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::self_matching_allowed(),
            quantity_2,
            !is_bid,
            pay_with_deep,
            &mut test,
        );

        let current_time = get_time(&mut test);
        let cumulative_quote_quantity = if (is_bid) {
            4_000_000_000
        } else {
            2_000_000_000
        };

        verify_order_info(
            &order_info,
            client_order_id,
            price,
            quantity_2,
            quantity_2,
            cumulative_quote_quantity,
            math::mul(
                quantity_2,
                math::mul(
                    constants::taker_fee(),
                    constants::deep_multiplier())
            ),
            fee_is_deep,
            constants::filled(),
            current_time,
        );

        borrow_and_verify_book_order(
            pool_id,
            partial_order_id,
            is_bid,
            partial_order_client_id,
            quantity,
            500_000_000,
            constants::deep_multiplier(),
            0,
            constants::partially_filled(),
            constants::max_u64(),
            &mut test,
        );

        borrow_and_verify_book_order(
            pool_id,
            full_order_id,
            is_bid,
            full_order_client_id,
            quantity,
            0,
            constants::deep_multiplier(),
            0,
            constants::live(),
            constants::max_u64(),
            &mut test,
        );

        end(test);
    }

    /// Test crossing num_orders orders with a single order
    /// Should be filled with the num_orders orders, with correct quantities
    /// Quantity of 1 for the first num_orders orders, quantity of num_orders for the last order
    fun test_crossing_multiple(
        is_bid: bool,
        num_orders: u64,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        let mut i = 0;
        while (i < num_orders) {
            place_limit_order(
                pool_id,
                ALICE,
                balance_manager_id_alice,
                client_order_id,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        let client_order_id = 3;
        let price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };

        let order_info = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            num_orders * quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        verify_order_info(
            &order_info,
            client_order_id,
            price,
            num_orders * quantity,
            num_orders * quantity,
            2 * num_orders * quantity,
            num_orders * math::mul(constants::taker_fee(), constants::deep_multiplier()),
            true,
            constants::filled(),
            expire_timestamp,
        );

        end(test);
    }

    /// Test fill or kill order that crosses with an order that's smaller in quantity
    /// Should error with EFOKOrderCannotBeFullyFilled if order cannot be fully filled
    /// Should fill correctly if order can be fully filled
    /// First order has quantity 1, second order has quantity 2 for incorrect fill
    /// First two orders have quantity 1, third order is quantity 2 for correct fill
    fun test_fill_or_kill(
        is_bid: bool,
        order_can_be_filled: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;
        let quantity_multiplier = 2;
        let mut num_orders = if (order_can_be_filled) {
            quantity_multiplier
        } else {
            1
        };

        while (num_orders > 0) {
            place_limit_order(
                pool_id,
                ALICE,
                balance_manager_id_alice,
                client_order_id,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                pay_with_deep,
                expire_timestamp,
                &mut test,
            );
            num_orders = num_orders - 1;
        };

        // Place a second order that crosses with the first i orders
        let client_order_id = 2;
        let price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };

        let order_info = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::fill_or_kill(),
            constants::self_matching_allowed(),
            price,
            quantity_multiplier * quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        verify_order_info(
            &order_info,
            client_order_id,
            price,
            quantity_multiplier * quantity,
            quantity_multiplier * quantity,
            2 * quantity_multiplier * quantity,
            quantity_multiplier * math::mul(constants::taker_fee(), constants::deep_multiplier()),
            true,
            constants::filled(),
            expire_timestamp,
        );

        end(test);
    }

    /// Test post only order that crosses with another order
    /// Should error with EPOSTOrderCrossesOrderbook
    fun test_post_only(
        is_bid: bool,
        crosses_order: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let order_type = constants::post_only();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
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

        // Place a second order that crosses with the first order
        let client_order_id = 2;
        let price = if ((is_bid && crosses_order) || (!is_bid && !crosses_order)) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
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

        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidOrderType)]
    /// placing an order > MAX_RESTRICTIONS should fail
    fun place_order_max_restrictions_e() {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        let client_order_id = 1;
        let order_type = constants::max_restriction() + 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    /// Trying to cancel a cancelled order should fail
    fun place_and_cancel_order_empty_e() {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let alice_quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;

        let placed_order_id = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id,
            client_order_id, // client_order_id
            order_type,
            constants::self_matching_allowed(),
            price, // price
            alice_quantity, // quantity
            is_bid,
            pay_with_deep,
            expire_timestamp, // no expiration
            &mut test,
        ).order_id();
        cancel_order(
            pool_id,
            ALICE,
            balance_manager_id,
            placed_order_id,
            &mut test
        );
        cancel_order(
            pool_id,
            ALICE,
            balance_manager_id,
            placed_order_id,
            &mut test
        );
        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidExpireTimestamp)]
    /// Trying to place an order that's expiring should fail
    fun place_order_expired_order_skipped() {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        set_time(100, &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = 0;
        let is_bid = true;
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
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

    fun test_cancel_all_orders(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        let order_info_1 = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
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

        let client_order_id = 2;

        let order_info_2 = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
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

        borrow_order_ok(
            pool_id,
            order_info_1.order_id(),
            &mut test,
        );

        borrow_order_ok(
            pool_id,
            order_info_2.order_id(),
            &mut test,
        );

        cancel_all_orders(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            &mut test
        );

        borrow_order_ok(
            pool_id,
            order_info_1.order_id(),
            &mut test,
        );
        end(test);
    }

    /// Alice places a bid order, Bob places a swap_exact_amount order
    /// Make sure the assets returned to Bob are correct
    /// Make sure expired orders are skipped over
    fun test_swap_exact_amount(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let alice_quantity = 2 * constants::float_scaling();
        let expired_price = if (is_bid) {
            3 * constants::float_scaling()
        } else {
            1 * constants::float_scaling()
        };
        let expire_timestamp = constants::max_u64();
        let expire_timestamp_e = 100;
        let pay_with_deep = true;
        let residual = constants::lot_size() - 1;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            expired_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp_e,
            &mut test,
        );

        set_time(200, &mut test);

        let base_in = if (is_bid) {
            1 * constants::float_scaling() + residual
        } else {
            0
        };
        let quote_in = if (is_bid) {
            0
        } else {
            2 * constants::float_scaling() + residual
        };
        let deep_in = math::mul(constants::deep_multiplier(), constants::taker_fee()) + residual;

        let (base_out, quote_out, deep_out) = place_swap_exact_amount_order(
            pool_id,
            BOB,
            base_in,
            quote_in,
            deep_in,
            &mut test,
        );

        if (is_bid) {
            assert!(base_out.value() == residual, constants::e_order_info_mismatch());
            assert!(quote_out.value() == 2 * constants::float_scaling(), constants::e_order_info_mismatch());
        } else {
            assert!(base_out.value() == 1 * constants::float_scaling(), constants::e_order_info_mismatch());
            assert!(quote_out.value() == residual, constants::e_order_info_mismatch());
        };

        assert!(deep_out.value() == residual, constants::e_order_info_mismatch());

        base_out.burn_for_testing();
        quote_out.burn_for_testing();
        deep_out.burn_for_testing();

        end(test);
    }

    /// Alice places a bid/ask order
    /// Alice then places an ask/bid order that crosses with that order with cancel_taker option
    /// Order should be rejected.
    fun test_self_matching_cancel_taker(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let bid_client_order_id = 1;
        let ask_client_order_id = 2;
        let order_type = constants::no_restriction();
        let price_1 = 2 * constants::float_scaling();
        let price_2 = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;
        let fee_is_deep = true;

        let order_info_1 = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            bid_client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price_1,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        verify_order_info(
            &order_info_1,
            bid_client_order_id,
            price_1,
            quantity,
            0,
            0,
            0,
            fee_is_deep,
            constants::live(),
            expire_timestamp,
        );

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            ask_client_order_id,
            order_type,
            constants::cancel_taker(),
            price_2,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        end(test);
    }

    /// Alice places a bid/ask order
    /// Alice then places an ask/bid order that crosses with that order with cancel_maker option
    /// Maker order should be removed, with the new order placed successfully.
    fun test_self_matching_cancel_maker(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id_1 = 1;
        let client_order_id_2 = 2;
        let order_type = constants::no_restriction();
        let price_1 = 2 * constants::float_scaling();
        let price_2 = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;
        let fee_is_deep = true;

        let order_info_1 = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id_1,
            order_type,
            constants::self_matching_allowed(),
            price_1,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        verify_order_info(
            &order_info_1,
            client_order_id_1,
            price_1,
            quantity,
            0,
            0,
            0,
            fee_is_deep,
            constants::live(),
            expire_timestamp,
        );

        let order_info_2 = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id_2,
            order_type,
            constants::cancel_maker(),
            price_2,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        verify_order_info(
            &order_info_2,
            client_order_id_2,
            price_2,
            quantity,
            0,
            0,
            0,
            fee_is_deep,
            constants::live(),
            expire_timestamp,
        );

        borrow_order_ok(
            pool_id,
            order_info_1.order_id(),
            &mut test,
        );

        end(test);
    }

    fun place_with_price_quantity(
        price: u64,
        quantity: u64,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        end(test);
    }

    fun partial_fill_order(
        is_bid: bool,
        order_type: u8,
        alice_quantity: u64,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        let balance_manager_id_bob = create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let bob_client_order_id = 2;
        let bob_price = 2 * constants::float_scaling();
        let bob_quantity = 2 * constants::float_scaling();

        let bob_order_info = place_limit_order(
            pool_id,
            BOB,
            balance_manager_id_bob,
            bob_client_order_id,
            order_type,
            constants::self_matching_allowed(),
            bob_price,
            bob_quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let fee_is_deep = true;

        verify_order_info(
            &bob_order_info,
            bob_client_order_id,
            bob_price,
            bob_quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            fee_is_deep,
            expected_status,
            expire_timestamp,
        );

        borrow_order_ok(
            pool_id,
            bob_order_info.order_id(),
            &mut test,
        );

        end(test);
    }

    /// Place normal ask order, then try to fill full order.
    /// Alice places first order, Bob places second order.
    fun place_then_fill(
        is_bid: bool,
        order_type: u8,
        alice_quantity: u64,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        let balance_manager_id_bob = create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let bob_client_order_id = 2;
        let bob_price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let bob_quantity = 1 * constants::float_scaling();

        let bob_order_info = place_limit_order(
            pool_id,
            BOB,
            balance_manager_id_bob,
            bob_client_order_id,
            order_type,
            constants::self_matching_allowed(),
            bob_price,
            bob_quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let expire_timestamp = constants::max_u64();
        let fee_is_deep = true;

        verify_order_info(
            &bob_order_info,
            bob_client_order_id,
            bob_price,
            bob_quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            fee_is_deep,
            expected_status,
            expire_timestamp,
        );
        end(test);
    }

    /// Place normal ask order, then try to place without filling.
    /// Alice places first order, Bob places second order.
    fun place_then_no_fill(
        is_bid: bool,
        order_type: u8,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        let balance_manager_id_bob = create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let client_order_id = 2;
        let price = if (is_bid) {
            3 * constants::float_scaling()
        } else {
            1 * constants::float_scaling()
        };

        let order_info = place_limit_order(
            pool_id,
            BOB,
            balance_manager_id_bob,
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

        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let fee_is_deep = true;

        verify_order_info(
            &order_info,
            client_order_id,
            price,
            quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            fee_is_deep,
            expected_status,
            expire_timestamp,
        );

        cancel_order(
            pool_id,
            BOB,
            balance_manager_id_bob,
            order_info.order_id(),
            &mut test
        );
        end(test);
    }

    /// Trying to fill an order that's expired on the book should remove order.
    /// New order should be placed successfully.
    /// Old order no longer exists.
    fun place_order_expire_timestamp_e(
        is_bid: bool,
        order_type: u8,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id_alice = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);
        let balance_manager_id_bob = create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let pay_with_deep = true;
        let fee_is_deep = true;
        let expire_timestamp = 100;

        let order_info_alice = place_limit_order(
            pool_id,
            ALICE,
            balance_manager_id_alice,
            client_order_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        set_time(200, &mut test);
        verify_order_info(
            &order_info_alice,
            client_order_id,
            price,
            quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            fee_is_deep,
            expected_status,
            expire_timestamp,
        );

        let client_order_id = 2;
        let price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let expire_timestamp = constants::max_u64();

        let order_info_bob = place_limit_order(
            pool_id,
            BOB,
            balance_manager_id_bob,
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

        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        verify_order_info(
            &order_info_bob,
            client_order_id,
            price,
            quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            fee_is_deep,
            expected_status,
            expire_timestamp,
        );

        borrow_and_verify_book_order(
            pool_id,
            order_info_bob.order_id(),
            !is_bid,
            client_order_id,
            quantity,
            expected_executed_quantity,
            order_info_bob.deep_per_base(),
            test.ctx().epoch(),
            expected_status,
            expire_timestamp,
            &mut test,
        );

        borrow_order_ok(
            pool_id,
            order_info_alice.order_id(),
            &mut test,
        );
        end(test);
    }

    /// Test to place a limit order, verify the order info and order in the book
    fun place_order_ok(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        // variables to input into order
        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        // variables expected from OrderInfo and Order
        let status = constants::live();
        let executed_quantity = 0;
        let cumulative_quote_quantity = 0;
        let paid_fees = 0;
        let fee_is_deep = true;
        let pay_with_deep = true;

        let order_info = &place_limit_order(
            pool_id,
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

        verify_order_info(
            order_info,
            client_order_id,
            price,
            quantity,
            executed_quantity,
            cumulative_quote_quantity,
            paid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
        );

        borrow_and_verify_book_order(
            pool_id,
            order_info.order_id(),
            is_bid,
            client_order_id,
            quantity,
            executed_quantity,
            order_info.deep_per_base(),
            test.ctx().epoch(),
            status,
            expire_timestamp,
            &mut test,
        );
        end(test);
    }

    /// Test placing and cancelling a limit order.
    fun place_and_cancel_order_ok(
        is_bid: bool,
    ) {
        let mut test = begin(OWNER);
        let pool_id = setup_test(OWNER, &mut test);
        let balance_manager_id = create_acct_and_share_with_funds(ALICE, 1000000 * constants::float_scaling(), &mut test);

        // variables to input into order
        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;
        let executed_quantity = 0;
        let cumulative_quote_quantity = 0;
        let paid_fees = 0;
        let fee_is_deep = true;
        let status = constants::live();

        let order_info = place_limit_order(
            pool_id,
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

        verify_order_info(
            &order_info,
            client_order_id,
            price,
            quantity,
            executed_quantity,
            cumulative_quote_quantity,
            paid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
        );

        cancel_order(
            pool_id,
            ALICE,
            balance_manager_id,
            order_info.order_id(),
            &mut test
        );
        end(test);
    }

    /// Helper, verify OrderInfo.
    /// TODO: create an OrderInfo struct and use that instead of multiple parameters
    fun verify_order_info(
        order_info: &OrderInfo,
        client_order_id: u64,
        price: u64,
        original_quantity: u64,
        executed_quantity: u64,
        cumulative_quote_quantity: u64,
        paid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
    ) {
        assert!(order_info.client_order_id() == client_order_id, constants::e_order_info_mismatch());
        assert!(order_info.price() == price, constants::e_order_info_mismatch());
        assert!(order_info.original_quantity() == original_quantity, constants::e_order_info_mismatch());
        assert!(order_info.executed_quantity() == executed_quantity, constants::e_order_info_mismatch());
        assert!(order_info.cumulative_quote_quantity() == cumulative_quote_quantity, constants::e_order_info_mismatch());
        assert!(order_info.paid_fees() == paid_fees, constants::e_order_info_mismatch());
        assert!(order_info.fee_is_deep() == fee_is_deep, constants::e_order_info_mismatch());
        assert!(order_info.status() == status, constants::e_order_info_mismatch());
        assert!(order_info.expire_timestamp() == expire_timestamp, constants::e_order_info_mismatch());
    }

    /// Helper, borrow orderbook and verify an order.
    fun borrow_and_verify_book_order(
        pool_id: ID,
        book_order_id: u128,
        is_bid: bool,
        client_order_id: u64,
        quantity: u64,
        filled_quantity: u64,
        deep_per_base: u64,
        epoch: u64,
        status: u8,
        expire_timestamp: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(@0x1);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let order = borrow_orderbook(&pool, is_bid).borrow(book_order_id);
        verify_book_order(
            order,
            book_order_id,
            client_order_id,
            quantity,
            filled_quantity,
            deep_per_base,
            epoch,
            status,
            expire_timestamp,
        );
        return_shared(pool);
    }

    /// Internal function to borrow orderbook to ensure order exists
    fun borrow_order_ok(
        pool_id: ID,
        book_order_id: u128,
        test: &mut Scenario,
    ) {
        test.next_tx(@0x1);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let (is_bid, _, _,) = utils::decode_order_id(book_order_id);
        borrow_orderbook(&pool, is_bid).borrow(book_order_id);
        return_shared(pool);
    }

    /// Internal function to verifies an order in the book
    fun verify_book_order(
        order: &Order,
        book_order_id: u128,
        client_order_id: u64,
        quantity: u64,
        filled_quantity: u64,
        deep_per_base: u64,
        epoch: u64,
        status: u8,
        expire_timestamp: u64,
    ) {
        assert!(order.order_id() == book_order_id, constants::e_book_order_mismatch());
        assert!(order.client_order_id() == client_order_id, constants::e_book_order_mismatch());
        assert!(order.quantity() == quantity, constants::e_book_order_mismatch());
        assert!(order.filled_quantity() == filled_quantity, constants::e_book_order_mismatch());
        assert!(order.deep_per_base() == deep_per_base, constants::e_book_order_mismatch());
        assert!(order.epoch() == epoch, constants::e_book_order_mismatch());
        assert!(order.status() == status, constants::e_book_order_mismatch());
        assert!(order.expire_timestamp() == expire_timestamp, constants::e_book_order_mismatch());
    }

    /// Internal function to borrow orderbook
    fun borrow_orderbook<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        is_bid: bool,
    ): &BigVector<Order>{
        let orderbook = if (is_bid) {
            pool.bids()
        } else {
            pool.asks()
        };
        orderbook
    }

    /// Set the time in the global clock
    fun set_time(
        current_time: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(ALICE);
        {
            let mut clock = test.take_shared<Clock>();
            clock.set_for_testing(current_time);
            return_shared(clock);
        };
    }

    /// Set the time in the global clock
    fun get_time(
        test: &mut Scenario,
    ): u64 {
        test.next_tx(ALICE);
        {
            let clock = test.take_shared<Clock>();
            let time =clock.timestamp_ms();
            return_shared(clock);

            time
        }
    }

    /// Place swap exact amount order
    fun place_swap_exact_amount_order(
        pool_id: ID,
        trader: address,
        base_in: u64,
        quote_in: u64,
        deep_in: u64,
        test: &mut Scenario,
    ): (Coin<SUI>, Coin<USDC>, Coin<DEEP>) {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();

            // Place order in pool
            let (base_out, quote_out, deep_out) =
                pool.swap_exact_amount<SUI, USDC>(
                    mint_for_testing<SUI>(base_in, test.ctx()),
                    mint_for_testing<USDC>(quote_in, test.ctx()),
                    mint_for_testing<DEEP>(deep_in, test.ctx()),
                    &clock,
                    test.ctx()
                );
            return_shared(pool);
            return_shared(clock);

            (base_out, quote_out, deep_out)
        }
    }

    /// Cancel an order
    public(package) fun cancel_order(
        pool_id: ID,
        owner: address,
        balance_manager_id: ID,
        order_id: u128,
        test: &mut Scenario,
    ) {
        test.next_tx(owner);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);

            let proof = balance_manager.generate_proof_as_owner(test.ctx());
            pool.cancel_order<SUI, USDC>(
                &mut balance_manager,
                &proof,
                order_id,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(balance_manager);
        }
    }

    fun cancel_all_orders(
        pool_id: ID,
        owner: address,
        balance_manager_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(owner);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);

            let proof = balance_manager.generate_proof_as_owner(test.ctx());
            pool.cancel_all_orders<SUI, USDC>(
                &mut balance_manager,
                &proof,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(balance_manager);
        }
    }

    fun share_clock(
        test: &mut Scenario,
    ) {
        test.next_tx(ALICE);
        {
            clock::create_for_testing(test.ctx()).share_for_testing();
        };
    }

    fun setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        test: &mut Scenario,
        sender: address,
    ): ID {
        test.next_tx(sender);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        test.next_tx(sender);
        let mut registry = registry::test_registry(test.ctx());
        let pool_id;
        {
            pool_id = pool::create_pool_admin<BaseAsset, QuoteAsset>(
                &mut registry,
                tick_size,
                lot_size,
                min_size,
                coin::mint_for_testing(constants::pool_creation_fee(), test.ctx()),
                &admin_cap,
                test.ctx()
            );
        };
        test_utils::destroy(registry);
        test_utils::destroy(admin_cap);

        pool_id
    }

    fun deposit_into_account<T>(
        balance_manager: &mut BalanceManager,
        amount: u64,
        test: &mut Scenario,
    ) {
        balance_manager.deposit(
            mint_for_testing<T>(amount, test.ctx()),
            test.ctx()
        );
    }

    fun get_mid_price(
        pool_id: ID,
        test: &mut Scenario,
    ): u64 {
        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();

            let mid_price = pool.mid_price<SUI, USDC>(&clock);
            return_shared(pool);
            return_shared(clock);

            mid_price
        }
    }
}
