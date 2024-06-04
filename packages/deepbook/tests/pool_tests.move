// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only, allow(unused_const)]
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
    };

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
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidOrderType)]
    /// placing an order > MAX_RESTRICTIONS should fail
    fun place_order_max_restrictions_e() {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);
        let client_order_id = 1;
        let order_type = constants::max_restriction() + 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id,
            client_order_id,
            order_type,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let alice_quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;
        let pay_with_deep = true;

        let placed_order_id = place_order(
            ALICE,
            acct_id,
            client_order_id, // client_order_id
            order_type,
            price, // price
            alice_quantity, // quantity
            is_bid,
            pay_with_deep,
            expire_timestamp, // no expiration
            &mut test,
        ).order_id();
        cancel_order(
            ALICE,
            acct_id,
            placed_order_id,
            &mut test
        );
        cancel_order(
            ALICE,
            acct_id,
            placed_order_id,
            &mut test
        );
        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidExpireTimestamp)]
    /// Trying to place an order that's expiring should fail
    fun place_order_expired_order_skipped() {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);
        set_time(100, &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = 0;
        let is_bid = true;
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id,
            client_order_id,
            order_type,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        end(test);
    }

    #[test]
    fun test_partial_fill_order_bid() {
        partial_fill_order(
            true,
            constants::no_restriction(),
            1 * constants::float_scaling(),
            1 * constants::float_scaling(),
            2 * constants::float_scaling(),
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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
            math::mul(constants::taker_discount(), math::mul(constants::taker_fee(), constants::deep_multiplier())),
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

    #[test, expected_failure(abort_code = ::deepbook::book::ESelfMatching)]
    fun test_self_matching_bid() {
        test_self_matching(true);
    }

    #[test, expected_failure(abort_code = ::deepbook::book::ESelfMatching)]
    fun test_self_matching_ask() {
        test_self_matching(false);
    }

    #[test]
    fun test_swap_exact_amount_bid_ask() {
        test_swap_exact_amount(true);
    }

    #[test]
    fun test_swap_exact_amount_ask_bid() {
        test_swap_exact_amount(false);
    }

    /// Alice places a bid order, Bob places a swap_exact_amount order
    /// Make sure the assets returned to Bob are correct
    fun test_swap_exact_amount(
        is_bid: bool,
    ) {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let alice_quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
            alice_price,
            alice_quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let base_in = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            0
        };
        let quote_in = if (is_bid) {
            0
        } else {
            2 * constants::float_scaling()
        };
        let deep_in = math::mul(constants::taker_discount(), math::mul(constants::deep_multiplier(), constants::taker_fee()));

        let (base_out, quote_out, deep_out) = place_swap_exact_amount_order(
            BOB,
            base_in,
            quote_in,
            deep_in,
            &mut test,
        );

        if (is_bid) {
            assert!(base_out.value() == 0, constants::e_order_info_mismatch());
            assert!(quote_out.value() == 2 * constants::float_scaling(), constants::e_order_info_mismatch());
        } else {
            assert!(base_out.value() == 1 * constants::float_scaling(), constants::e_order_info_mismatch());
            assert!(quote_out.value() == 0, constants::e_order_info_mismatch());
        };

        assert!(deep_out.value() == 0, constants::e_order_info_mismatch());

        base_out.burn_for_testing();
        quote_out.burn_for_testing();
        deep_out.burn_for_testing();

        end(test);
    }

    /// Alice places a bid/ask order, Alice then places an ask/bid order that crosses with that order
    /// Order should be rejected.
    fun test_self_matching(
        is_bid: bool,
    ) {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);

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

        let order_info_1 = place_order(
            ALICE,
            acct_id_alice,
            bid_client_order_id,
            order_type,
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

        place_order(
            ALICE,
            acct_id_alice,
            ask_client_order_id,
            order_type,
            price_2,
            quantity,
            !is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        end(test);
    }

    fun place_with_price_quantity(
        price: u64,
        quantity: u64,
    ) {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);

        let client_order_id = 1;
        let order_type = constants::no_restriction();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id,
            client_order_id,
            order_type,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);
        let acct_id_bob = create_acct_and_share_with_funds(BOB, &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
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

        let bob_order_info = place_order(
            BOB,
            acct_id_bob,
            bob_client_order_id,
            order_type,
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
            bob_order_info.order_id(),
            !is_bid,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);
        let acct_id_bob = create_acct_and_share_with_funds(BOB, &mut test);

        let alice_client_order_id = 1;
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id_alice,
            alice_client_order_id,
            constants::no_restriction(),
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

        let bob_order_info = place_order(
            BOB,
            acct_id_bob,
            bob_client_order_id,
            order_type,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);
        let acct_id_bob = create_acct_and_share_with_funds(BOB, &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let pay_with_deep = true;

        place_order(
            ALICE,
            acct_id_alice,
            client_order_id,
            constants::no_restriction(),
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

        let order_info = place_order(
            BOB,
            acct_id_bob,
            client_order_id,
            order_type,
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
            BOB,
            acct_id_bob,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(ALICE, &mut test);
        let acct_id_bob = create_acct_and_share_with_funds(BOB, &mut test);

        let client_order_id = 1;
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let pay_with_deep = true;
        let fee_is_deep = true;
        let expire_timestamp = 100;

        let order_info_alice = place_order(
            ALICE,
            acct_id_alice,
            client_order_id,
            constants::no_restriction(),
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

        let order_info_bob = place_order(
            BOB,
            acct_id_bob,
            client_order_id,
            order_type,
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
            order_info_alice.order_id(),
            !is_bid,
            &mut test,
        );
        end(test);
    }

    /// Test to place a limit order, verify the order info and order in the book
    fun place_order_ok(
        is_bid: bool,
    ) {
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);

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

        let order_info = &place_order(
            ALICE,
            acct_id,
            client_order_id,
            order_type,
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
        let owner: address = @0x1;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(ALICE, &mut test);

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

        let order_info = place_order(
            ALICE,
            acct_id,
            client_order_id,
            order_type,
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
            ALICE,
            acct_id,
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
        let pool = test.take_shared<Pool<SUI, USDC>>();
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
        book_order_id: u128,
        is_bid: bool,
        test: &mut Scenario,
    ) {
        test.next_tx(@0x1);
        let pool = test.take_shared<Pool<SUI, USDC>>();
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

    /// Place an order
    fun place_order(
        trader: address,
        acct_id: ID,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ): OrderInfo {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared<Pool<SUI, USDC>>();
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(acct_id);

            // Get Proof from BalanceManager
            let proof = balance_manager.generate_proof_as_owner(test.ctx());

            // Place order in pool
            let order_info = pool.place_limit_order<SUI, USDC>(
                &mut balance_manager,
                &proof,
                client_order_id,
                order_type,
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

    /// Place swap exact amount order
    fun place_swap_exact_amount_order(
        trader: address,
        base_in: u64,
        quote_in: u64,
        deep_in: u64,
        test: &mut Scenario,
    ): (Coin<SUI>, Coin<USDC>, Coin<DEEP>) {
        test.next_tx(trader);
        {
            let mut pool = test.take_shared<Pool<SUI, USDC>>();
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
    fun cancel_order(
        owner: address,
        acct_id: ID,
        order_id: u128,
        test: &mut Scenario,
    ) {
        test.next_tx(owner);
        {
            let mut pool = test.take_shared<Pool<SUI, USDC>>();
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(acct_id);

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

    /// Helper function to share a clock and a pool with default values
    fun setup_test(
        sender: address,
        test: &mut Scenario,
    ) {
        setup_pool_with_default_fees<SUI, USDC>(
            constants::tick_size(), // tick size
            constants::lot_size(), // lot size
            constants::min_size(), // min size
            test,
            sender,
        );
        share_clock(test);
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
    ) {
        test.next_tx(sender);
        let mut registry = registry::test_registry(test.ctx());
        {
            pool::create_pool<BaseAsset, QuoteAsset>(
                &mut registry,
                tick_size,
                lot_size,
                min_size,
                balance::create_for_testing(constants::pool_creation_fee()),
                test.ctx()
            );
        };
        test_utils::destroy(registry);
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

    public fun create_acct_and_share_with_funds(
        sender: address,
        test: &mut Scenario,
    ): ID {
        let amount_to_deposit = 1000000 * constants::float_scaling();
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
}
