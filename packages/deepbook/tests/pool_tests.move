// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only, allow(unused_const)]
module deepbook::pool_tests {
    use sui::{
        clock::{Self, Clock},
        test_scenario::{Self, Scenario},
        balance::Self,
        sui::SUI,
        coin::mint_for_testing,
    };

    use deepbook::{
        pool::{Self, Pool, DEEP},
        account::{Self, Account},
        order::{Order, OrderInfo},
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
    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;

    public struct USDC {}
    public struct SPAM {}

    #[test]
    fun place_order_ok() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);
        place_order(owner, acct_id, NO_RESTRICTION, true, &mut test);
        test_scenario::end(test);
    }

    #[test]
    fun place_and_cancel_order_ok() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);
        let placed_order_id = place_order(owner, acct_id, NO_RESTRICTION, true, &mut test).order_id();
        cancel_order(owner, acct_id, placed_order_id, &mut test);
        let placed_order_id = place_order(owner, acct_id, NO_RESTRICTION, false, &mut test).order_id();
        cancel_order(owner, acct_id, placed_order_id, &mut test);
        test_scenario::end(test);
    }

    #[test, expected_failure(abort_code = ::deepbook::big_vector::ENotFound)]
    fun place_and_cancel_order_empty_e() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        setup_test(owner, &mut test);
        let acct_id = create_acct_and_share_with_funds(owner, &mut test);
        place_order(owner, acct_id, NO_RESTRICTION, true, &mut test);
        cancel_order(owner, acct_id, 0, &mut test);
        test_scenario::end(test);
    }

    /// Helper function to place an order
    fun place_order(
        owner: address,
        acct_id: ID,
        order_type: u8,
        is_bid: bool,
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
                1, // client_order_id
                order_type, // order_type
                2 * FLOAT_SCALING, // price, use float scaling
                1 * FLOAT_SCALING, // quantity, use float scaling
                is_bid, // is_bid
                MAX_U64, // no expiration
                &clock,
                test.ctx()
            );
            test_scenario::return_shared(pool);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(account);

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
            test_scenario::return_shared(pool);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(account);

            cancelled_order
        }
    }

    /// Helper function to share a clock and a pool with default values
    fun setup_test(
        sender: address,
        test: &mut Scenario,
    ) {
        setup_pool_with_tick_min(
            1000000, // 10 bps
            500000, // 5 bps
            1,
            1,
            1,
            test,
            sender,
        );
        share_clock(test);
    }

    fun share_clock(
        test: &mut Scenario,
    ) {
        test.next_tx(@0xAAAA);
        {
            clock::create_for_testing(test.ctx()).share_for_testing();
        };
    }

    fun setup_pool_with_tick_min(
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
        ctx: &mut TxContext,
    ) {
        account.deposit(
            mint_for_testing<T>(amount, ctx),
            ctx
        );
    }

    public fun create_acct_and_share_with_funds(
        sender: address,
        test: &mut Scenario,
    ): ID {
        let amount_to_deposit = 1000000 * FLOAT_SCALING;
        test_scenario::next_tx(test, sender);
        {
            let mut acct = account::new(test.ctx());
            deposit_into_account<SUI>(&mut acct, amount_to_deposit, test.ctx());
            deposit_into_account<SPAM>(&mut acct, amount_to_deposit, test.ctx());
            deposit_into_account<USDC>(&mut acct, amount_to_deposit, test.ctx());
            deposit_into_account<DEEP>(&mut acct, amount_to_deposit, test.ctx());
            let id = acct.id();
            acct.share();

            id
        }
    }
}
