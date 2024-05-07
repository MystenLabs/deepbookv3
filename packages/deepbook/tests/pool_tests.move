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
        balance::Self,
        sui::SUI,
        coin::mint_for_testing,
    };

    use deepbook::{
        pool::{Self, Pool, DEEP},
        account::{Self, Account},
        order::{Order, OrderInfo},
        big_vector::BigVector,
        math,
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

    const ALICE: address = @0xAAAA;

    public struct USDC {}
    public struct SPAM {}

    #[test]
    fun test_place_order() {
        place_order_ok(true);
        place_order_ok(false);
    }

    #[test]
    fun test_place_and_cancel_order() {
        place_and_cancel_order_ok(true);
        place_and_cancel_order_ok(false);
    }

    #[test, expected_failure(abort_code = ::deepbook::order::EInvalidOrderType)]
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
        place_order(
            owner,
            acct_id,
            client_order_id,
            order_type,
            price,
            quantity,
            true,
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
        let placed_order_id = place_order(
            owner,
            acct_id,
            1, // client_order_id
            NO_RESTRICTION,
            2 * FLOAT_SCALING, // price
            1 * FLOAT_SCALING, // quantity
            true,
            MAX_U64, // no expiration
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

    #[test, expected_failure(abort_code = ::deepbook::order::EInvalidExpireTimestamp)]
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

        place_order(
            owner,
            acct_id,
            client_order_id,
            order_type,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        end(test);
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
        let total_fees = if (is_bid) {
            math::mul(MAKER_FEE, math::mul(price, quantity))
        } else {
            math::mul(MAKER_FEE, quantity)
        };
        let unpaid_fees = total_fees - paid_fees;
        let fee_is_deep = false;

        let order_info = &place_order(
            owner,
            acct_id,
            client_order_id,
            order_type,
            price,
            quantity,
            is_bid,
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
            total_fees,
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

        // variables expected from Order that's cancelled
        let status = CANCELED;
        let self_matching_prevention = false;
        let paid_fees = 0;
        let total_fees = if (is_bid) {
            math::mul(MAKER_FEE, math::mul(price, quantity))
        } else {
            math::mul(MAKER_FEE, quantity)
        };
        let unpaid_fees = total_fees - paid_fees;
        let fee_is_deep = false;

        let order_id = place_order(
            owner,
            acct_id,
            client_order_id,
            order_type,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        ).order_id();

        let cancelled_order = &cancel_order(
            owner,
            acct_id,
            order_id,
            &mut test
        );

        verify_book_order(
            cancelled_order,
            order_id,
            client_order_id,
            quantity,
            unpaid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
            self_matching_prevention,
        );
        end(test);
    }

    fun verify_order_info(
        order_info: &OrderInfo,
        client_order_id: u64,
        price: u64,
        original_quantity: u64,
        executed_quantity: u64,
        cumulative_quote_quantity: u64,
        paid_fees: u64,
        total_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
    ) {
        assert!(order_info.client_order_id() == client_order_id, 0);
        assert!(order_info.price() == price, 0);
        assert!(order_info.original_quantity() == original_quantity, 0);
        assert!(order_info.executed_quantity() == executed_quantity, 0);
        assert!(order_info.cumulative_quote_quantity() == cumulative_quote_quantity, 0);
        assert!(order_info.paid_fees() == paid_fees, 0);
        assert!(order_info.total_fees() == total_fees, 0);
        assert!(order_info.fee_is_deep() == fee_is_deep, 0);
        assert!(order_info.status() == status, 0);
        assert!(order_info.expire_timestamp() == expire_timestamp, 0);
        assert!(order_info.self_matching_prevention() == self_matching_prevention, 0);
    }

    /// Verify an order in the book
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
        assert!(order.book_order_id() == book_order_id, 0);
        assert!(order.book_client_order_id() == client_order_id, 0);
        assert!(order.book_quantity() == quantity, 0);
        assert!(order.book_unpaid_fees() == unpaid_fees, 0);
        assert!(order.book_fee_is_deep() == fee_is_deep, 0);
        assert!(order.book_status() == status, 0);
        assert!(order.book_expire_timestamp() == expire_timestamp, 0);
        assert!(order.book_self_matching_prevention() == self_matching_prevention, 0);
    }

    /// Borrow orderbook and verify an order
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

    fun borrow_orderbook(
        pool: &Pool<SUI, USDC>,
        is_bid: bool,
    ): &BigVector<Order>{
        let orderbook = if (is_bid) {
            pool.bids()
        } else {
            pool.asks()
        };
        orderbook
    }

    /// Place an order
    fun place_order(
        owner: address,
        acct_id: ID,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ): OrderInfo {
        test.next_tx(owner);
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

    /// Helper function to cancel an order
    fun cancel_order(
        owner: address,
        acct_id: ID,
        order_id: u128,
        test: &mut Scenario,
    ): Order {
        test.next_tx(owner);
        {
            let mut pool = test.take_shared<Pool<SUI, USDC>>();
            let clock = test.take_shared<Clock>();
            let mut account = test.take_shared_by_id<Account>(acct_id);

            let proof = account.generate_proof_as_owner(test.ctx());
            let cancelled_order = pool.cancel_order<SUI, USDC>(
                &mut account,
                &proof,
                order_id,
                &clock,
                test.ctx()
            );
            return_shared(pool);
            return_shared(clock);
            return_shared(account);

            cancelled_order
        }
    }

    /// Helper function to share a clock and a pool with default values
    fun setup_test(
        sender: address,
        test: &mut Scenario,
    ) {
        setup_pool(
            TAKER_FEE, // 10 bps
            MAKER_FEE, // 5 bps
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

    fun setup_pool(
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        test: &mut Scenario,
        sender: address,
    ) {
        test.next_tx(sender);
        {
            pool::create_pool<SUI, USDC>(
                taker_fee,
                maker_fee,
                tick_size,
                lot_size,
                min_size,
                balance::create_for_testing(POOL_CREATION_FEE),
                test.ctx()
            );
        };
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

    fun create_acct_and_share_with_funds(
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
            let id = acct.id();
            acct.share();

            id
        }
    }
}
