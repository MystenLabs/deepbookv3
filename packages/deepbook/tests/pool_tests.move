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
        balance::Self,
        sui::SUI,
        coin::mint_for_testing,
        test_utils,
    };

    use deepbook::{
        pool::{Self, Pool},
        vault::DEEP,
        account::{Self, Account},
        order::{Order},
        order_info::OrderInfo,
        big_vector::BigVector,
        math,
        registry,
    };

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const MAX_U64: u64 = (1u128 << 64 - 1) as u64;
    // TODO: Cannot import constants, any better options?
    // Restrictions on limit orders.
    const NO_RESTRICTION: u8 = 0;
    // Mandates that whatever amount of an order that can be executed in the current transaction, be filled and then the rest of the order canceled.
    const IMMEDIATE_OR_CANCEL: u8 = 1;
    // Mandates that the entire order size be filled in the current transaction. Otherwise, the order is canceled.
    const FILL_OR_KILL: u8 = 2;
    // Mandates that the entire order be passive. Otherwise, cancel the order.
    const POST_ONLY: u8 = 3;
    // Maximum restriction value.
    const MAX_RESTRICTION: u8 = 3;

    const LIVE: u8 = 0;
    const PARTIALLY_FILLED: u8 = 1;
    const FILLED: u8 = 2;
    const CANCELED: u8 = 3;
    const EXPIRED: u8 = 4;

    const MAKER_FEE: u64 = 500000;
    const TAKER_FEE: u64 = 1000000;
    const TICK_SIZE: u64 = 1000;
    const LOT_SIZE: u64 = 1000;
    const MIN_SIZE: u64 = 10000;
    const DEEP_MULTIPLIER: u64 = 10 * FLOAT_SCALING;

    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    const EOrderInfoMismatch: u64 = 0;
    const EBookOrderMismatch: u64 = 1;

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
    /// Fill information is correct
    fun test_place_then_fill_bid_ask() {
        place_then_fill(true, NO_RESTRICTION);
    }

    #[test]
    /// Fill information is correct
    fun test_place_then_fill_ask_bid() {
        place_then_fill(false, NO_RESTRICTION);
    }

    #[test]
    fun test_place_then_ioc_bid_ask() {
        place_then_fill(true, IMMEDIATE_OR_CANCEL);
    }

    #[test]
    fun test_place_then_ioc_ask_bid() {
        place_then_fill(false, IMMEDIATE_OR_CANCEL);
    }

    /// Place normal ask order, then try to place immediate or cancel bid order
    /// with price that's lower than the ask order.
    /// Alice places first ask order, Bob places bid order.
    /// Other direction can be tested using is_bid = false
    /// Note this function is work in progress
    fun place_then_fill(
        is_bid: bool,
        order_type: u8,
    ) {
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id_alice = create_acct_and_share_with_funds(owner, &mut test);
        let acct_id_bob = create_acct_and_share_with_funds(BOB, &mut test);

        let client_order_id = 1;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;
        let pay_with_deep = true;

        place_order(
            owner,
            acct_id_alice,
            client_order_id,
            NO_RESTRICTION,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );

        let client_order_id = 2;
        let price = if (is_bid) {
            1 * FLOAT_SCALING
        } else {
            3 * FLOAT_SCALING
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

        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;
        let paid_fees = 0;
        let fee_is_deep = true;
        let executed_quantity = 1 * FLOAT_SCALING;
        let cumulative_quote_quantity = 2 * FLOAT_SCALING;
        let status = FILLED;
        let self_matching_prevention = false;

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
            self_matching_prevention,
        );
        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidOrderType)]
    /// placing an order > MAX_RESTRICTIONS should fail
    fun place_order_max_restrictions_e() {
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);
        let client_order_id = 1;
        let order_type = MAX_RESTRICTION + 1;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;
        let pay_with_deep = true;

        place_order(
            owner,
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
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);

        let client_order_id = 1;
        let order_type = NO_RESTRICTION;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;
        let is_bid = true;
        let pay_with_deep = true;

        let placed_order_id = place_order(
            owner,
            acct_id,
            client_order_id, // client_order_id
            order_type,
            price, // price
            quantity, // quantity
            is_bid,
            pay_with_deep,
            expire_timestamp, // no expiration
            &mut test,
        ).order_id();
        cancel_order(
            owner,
            acct_id,
            placed_order_id,
            &mut test
        );
        cancel_order(
            owner,
            acct_id,
            placed_order_id,
            &mut test
        );
        end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::order_info::EInvalidExpireTimestamp)]
    /// Trying to place an order that's expiring should fail
    fun place_order_expire_timestamp_e() {
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);
        set_time(100, &mut test);

        let client_order_id = 1;
        let order_type = NO_RESTRICTION;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = 0;
        let is_bid = true;
        let pay_with_deep = true;

        place_order(
            owner,
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

    /// Test to place a limit order, verify the order info and order in the book
    fun place_order_ok(
        is_bid: bool,
    ) {
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);

        // variables to input into order
        let client_order_id = 1;
        let order_type = NO_RESTRICTION;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;

        // variables expected from OrderInfo and Order
        let status = LIVE;
        let self_matching_prevention = false;
        let executed_quantity = 0;
        let cumulative_quote_quantity = 0;
        let paid_fees = 0;
        let total_fees = math::mul(MAKER_FEE, math::mul(DEEP_MULTIPLIER, quantity));
        let unpaid_fees = total_fees - paid_fees;
        let fee_is_deep = true;
        let pay_with_deep = true;

        let order_info = &place_order(
            owner,
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
            self_matching_prevention,
        );

        borrow_and_verify_book_order(
            order_info.order_id(),
            is_bid,
            client_order_id,
            quantity,
            unpaid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
            self_matching_prevention,
            &mut test,
        );
        end(test);
    }

    /// Test placing and cancelling a limit order
    fun place_and_cancel_order_ok(
        is_bid: bool,
    ) {
        let owner: address = ALICE;
        let mut test = begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);

        // variables to input into order
        let client_order_id = 1;
        let order_type = NO_RESTRICTION;
        let price = 2 * FLOAT_SCALING;
        let quantity = 1 * FLOAT_SCALING;
        let expire_timestamp = MAX_U64;
        let pay_with_deep = true;
        let executed_quantity = 0;
        let cumulative_quote_quantity = 0;
        let paid_fees = 0;
        let fee_is_deep = true;
        let status = LIVE;
        let self_matching_prevention = false;

        let order_info = place_order(
            owner,
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
            self_matching_prevention,
        );

        cancel_order(
            owner,
            acct_id,
            order_info.order_id(),
            &mut test
        );
        end(test);
    }

    /// Helper, verify OrderInfo
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
        self_matching_prevention: bool,
    ) {
        assert!(order_info.client_order_id() == client_order_id, EOrderInfoMismatch);
        assert!(order_info.price() == price, EOrderInfoMismatch);
        assert!(order_info.original_quantity() == original_quantity, EOrderInfoMismatch);
        assert!(order_info.executed_quantity() == executed_quantity, EOrderInfoMismatch);
        assert!(order_info.cumulative_quote_quantity() == cumulative_quote_quantity, EOrderInfoMismatch);
        assert!(order_info.paid_fees() == paid_fees, EOrderInfoMismatch);
        assert!(order_info.fee_is_deep() == fee_is_deep, EOrderInfoMismatch);
        assert!(order_info.status() == status, EOrderInfoMismatch);
        assert!(order_info.expire_timestamp() == expire_timestamp, EOrderInfoMismatch);
        assert!(order_info.self_matching_prevention() == self_matching_prevention, EOrderInfoMismatch);
    }

    /// Helper, borrow orderbook and verify an order
    fun borrow_and_verify_book_order(
        book_order_id: u128,
        is_bid: bool,
        client_order_id: u64,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
        test: &mut Scenario,
    ) {
        test.next_tx(ALICE);
        let pool = test.take_shared<Pool<SUI, USDC>>();
        let order = borrow_orderbook(&pool, is_bid).borrow(book_order_id);
        verify_book_order(
            order,
            book_order_id,
            client_order_id,
            quantity,
            unpaid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
            self_matching_prevention,
        );
        return_shared(pool);
    }

    /// Verify an order in the book, internal function
    fun verify_book_order(
        order: &Order,
        book_order_id: u128,
        client_order_id: u64,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
    ) {
        assert!(order.order_id() == book_order_id, EBookOrderMismatch);
        assert!(order.client_order_id() == client_order_id, EBookOrderMismatch);
        assert!(order.quantity() == quantity, EBookOrderMismatch);
        assert!(order.unpaid_fees() == unpaid_fees, EBookOrderMismatch);
        assert!(order.fee_is_deep() == fee_is_deep, EBookOrderMismatch);
        assert!(order.status() == status, EBookOrderMismatch);
        assert!(order.expire_timestamp() == expire_timestamp, EBookOrderMismatch);
        assert!(order.self_matching_prevention() == self_matching_prevention, EBookOrderMismatch);
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
            let mut account = test.take_shared_by_id<Account>(acct_id);

            // Get Proof from Account
            let proof = account.generate_proof_as_owner(test.ctx());

            // Place order in pool
            let order_info = pool.place_limit_order<SUI, USDC>(
                &mut account,
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
            return_shared(account);

            order_info
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
            let mut account = test.take_shared_by_id<Account>(acct_id);

            let proof = account.generate_proof_as_owner(test.ctx());
            pool.cancel_order<SUI, USDC>(
                &mut account,
                &proof,
                order_id,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(account);
        }
    }

    /// Helper function to share a clock and a pool with default values
    fun setup_test(
        sender: address,
        test: &mut Scenario,
    ) {
        setup_pool_with_default_fees<SUI, USDC>(
            TICK_SIZE, // tick size
            LOT_SIZE, // lot size
            MIN_SIZE, // min size
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
                balance::create_for_testing(POOL_CREATION_FEE),
                test.ctx()
            );
        };
        test_utils::destroy(registry);
    }

    fun deposit_into_account<T>(
        account: &mut Account,
        amount: u64,
        test: &mut Scenario,
    ) {
        account.deposit(
            mint_for_testing<T>(amount, test.ctx()),
            test.ctx()
        );
    }

    public fun create_acct_and_share_with_funds(
        sender: address,
        test: &mut Scenario,
    ): ID {
        let amount_to_deposit = 1000000 * FLOAT_SCALING;
        test.next_tx(sender);
        {
            let mut acct = account::new(test.ctx());
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
