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
    use deepbook::order::{
        NO_RESTRICTION,
        IMMEDIATE_OR_CANCEL,
        FILL_OR_KILL,
        POST_ONLY,
        MAX_RESTRICTION
    };
    use deepbook::account::{Self, Account};
    use sui::test_scenario::{Self, Scenario};

    const ENotImplemented: u64 = 0;

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated

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
    #[expected_failure(abort_code = EInvalidRestriction)]
    fun test_place_limit_order_with_invalid_restrictions_() {
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
            let account = test_scenario::take_shared<Account>(&test);

            // Deposit into account
            account.deposit(
                mint_for_testing<SUI>(1000 * 100000000, test_scenario::ctx(&mut test)),
                test.ctx()
            );
            account.deposit(
                mint_for_testing<USDC>(1000 * 100000000, test_scenario::ctx(&mut test)),
                test.ctx()
            );
            account.deposit(
                mint_for_testing<DEEP>(1000 * 100000000, test_scenario::ctx(&mut test)),
                test.ctx()
            );

            // Get Proof from Account
            let proof = account.generate_proof_as_owner(test.ctx());

            // Deposit into pool
            account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,

            pool.place_limit_order<SUI, USDC>(
                account,
                proof,
                1, // client_order_id
                1, // order_type
                5 * FLOAT_SCALING,
                200 * 100000000,
                PREVENT_SELF_MATCHING_DEFAULT,
                true,
                TIMESTAMP_INF,
                5,
                &clock,
                &account_cap,
                test_scenario::ctx(&mut test)
            );
            test_scenario::return_shared(pool);
            test_scenario::return_shared(clock);
            test_scenario::return_to_address<AccountCap>(alice, account_cap);
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
