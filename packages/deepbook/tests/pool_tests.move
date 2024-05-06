// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::pool_tests {
    use deepbook::deepbook;
    use sui::{
        balance::{Self, Balance},
        clock::{Self, Clock},
        sui::SUI,
        coin::mint_for_testing
    };
    use deepbook::pool::{
        Self,
        Pool,
        DEEP
    };
    use deepbook::account::{Self, Account};
    use sui::test_scenario::{Self, Scenario};
    use deepbook::math;
    use deepbook::order::{Order, OrderInfo};

    const ENotImplemented: u64 = 0;

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const MAX_U64: u64 = (1u128 << 64 - 1) as u64;

    // Cannot import constants, any better options?
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

    public struct USDC {}

    // #[test]
    // fun test_deepbook() {
    //     // pass
    // }

    // #[test, expected_failure(abort_code = ::deepbook::pool_tests::ENotImplemented)]
    // fun test_deepbook_fail() {
    //     abort ENotImplemented
    // }

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

    fun create_acct_and_share(
        scenario: &mut Scenario,
        owner: address,
    ) {
        test_scenario::next_tx(scenario, owner);
        {
            account::share(account::new(test_scenario::ctx(scenario)))
        };
    }

    #[test]
    fun place_order_ok() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        place_order(&mut test, owner);
        test_scenario::end(test);
    }

    #[test]
    fun test_place_and_cancel_order() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        let placed_order_id = place_order(&mut test, owner).order_id();
        cancel_order(&mut test, owner, placed_order_id);
        test_scenario::end(test);
    }

    fun place_order(
        test: &mut Scenario,
        owner: address,
    ): OrderInfo {
        test.next_tx(owner);
        {
            setup_test(0, 0, test, owner);
        };
        create_acct_and_share(test, owner);
        test.next_tx(owner);
        {
            let mut pool = test_scenario::take_shared<Pool<SUI, USDC>>(test);
            let clock = test_scenario::take_shared<Clock>(test);
            let mut account = test_scenario::take_shared<Account>(test);

            // Deposit into account
            deposit_into_account<SUI>(&mut account, 1000000 * FLOAT_SCALING, test.ctx());
            deposit_into_account<USDC>(&mut account, 1000000 * FLOAT_SCALING, test.ctx());
            deposit_into_account<DEEP>(&mut account, 1000000 * FLOAT_SCALING, test.ctx());

            // Get Proof from Account
            let proof = account.generate_proof_as_owner(test.ctx());

            // Place order in pool
            let order_info = pool.place_limit_order<SUI, USDC>(
                &mut account,
                &proof,
                1, // client_order_id
                NO_RESTRICTION, // order_type
                20 * FLOAT_SCALING, // price, use float scaling
                1, // quantity
                true, // is_bid
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

    fun cancel_order(
        test: &mut Scenario,
        owner: address,
        order_id: u128,
    ): Order {
        test.next_tx(owner);
        {
            let mut pool = test_scenario::take_shared<Pool<SUI, USDC>>(test);
            let clock = test_scenario::take_shared<Clock>(test);
            let mut account = test_scenario::take_shared<Account>(test);

            // Get Proof from Account
            let proof = account.generate_proof_as_owner(test.ctx());

            // Place order in pool
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

    fun setup_test(
        taker_fee: u64,
        maker_fee: u64,
        scenario: &mut Scenario,
        sender: address,
    ) {
        setup_test_with_tick_min(
            taker_fee,
            maker_fee,
            1,
            1,
            1,
            scenario,
            sender,
        );
    }

    #[test_only]
    public fun setup_test_with_tick_min(
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        scenario: &mut Scenario,
        sender: address,
    ) {
        test_scenario::next_tx(scenario, sender);
        {
            clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
        };

        test_scenario::next_tx(scenario, sender);
        {
            pool::create_pool<SUI, USDC>(
                taker_fee,
                maker_fee,
                tick_size,
                lot_size,
                min_size,
                balance::create_for_testing(POOL_CREATION_FEE),
                test_scenario::ctx(scenario)
            );
        };
    }
}
