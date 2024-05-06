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

    const ENotImplemented: u64 = 0;

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const MAX_U64: u64 = (1u128 << 64 - 1) as u64;

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

    fun deposit_into_account(
        account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        account.deposit(
            mint_for_testing<SUI>(amount, ctx),
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
    fun test_place_limit_order() {
        let owner: address = @0xAAAA;
        let mut test = test_scenario::begin(owner);
        test.next_tx(owner);
        {
            setup_test(0, 0, &mut test, owner);
        };
        create_acct_and_share(&mut test, owner);
        test.next_tx(owner);
        {
            let mut pool = test_scenario::take_shared<Pool<SUI, USDC>>(&test);
            let clock = test_scenario::take_shared<Clock>(&test);
            let mut account = test_scenario::take_shared<Account>(&test);

            // Deposit into account
            account.deposit(
                mint_for_testing<SUI>(1000 * FLOAT_SCALING, test_scenario::ctx(&mut test)),
                test.ctx()
            );
            account.deposit(
                mint_for_testing<USDC>(1000 * FLOAT_SCALING, test_scenario::ctx(&mut test)),
                test.ctx()
            );
            account.deposit(
                mint_for_testing<DEEP>(1000 * FLOAT_SCALING, test_scenario::ctx(&mut test)),
                test.ctx()
            );

            // Get Proof from Account
            let proof = account.generate_proof_as_owner(test.ctx());

            // Place order in pool
            pool.place_limit_order<SUI, USDC>(
                &mut account,
                &proof,
                1, // client_order_id
                NO_RESTRICTION, // order_type
                5 * FLOAT_SCALING,
                200 * FLOAT_SCALING,
                true, // is_bid
                MAX_U64, // no expiration
                &clock,
                test.ctx()
            );
            test_scenario::return_shared(pool);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(account);
        };

        test_scenario::end(test);
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
