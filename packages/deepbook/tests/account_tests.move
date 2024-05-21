// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::account_tests {
    use sui::{
        test_scenario::{Self as test, Scenario, begin, end},
        sui::SUI,
        coin::mint_for_testing,
    };
    use deepbook::{
        account::{Self, Account, TradeCap},
        vault::{DEEP},
    };

    public struct SPAM has store {}
    public struct USDC has store {}

    #[test]
    fun test_deposit_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            assert!(account.owner() == alice, 0);
            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 200, 0);

            account.share();
        };

        end(test);
    }

    #[test]
    fun test_deposit_with_proof_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            let proof = account.generate_proof_as_owner(test.ctx());
            account.deposit_with_proof(&proof,
                mint_for_testing<SUI>(100, test.ctx()).into_balance()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            account.share();
        };

        end(test);
    }

    #[test]
    fun test_deposit_with_trader_proof_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account_id = object::id(&account);
            let cap = account.mint_trade_cap(test.ctx());
            let proof = account.generate_proof_as_trader(&cap, test.ctx());

            account.deposit_with_proof(&proof,
                mint_for_testing<SUI>(100, test.ctx()).into_balance()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            transfer::public_transfer(cap, bob);
            account.share();
        };

        test.next_tx(bob);
        {
            let mut account = test.take_shared_by_id<Account>(account_id);
            let cap = test.take_from_sender<TradeCap>();
            let proof = account.generate_proof_as_trader(&cap, test.ctx());

            account.deposit_with_proof(&proof,
                mint_for_testing<DEEP>(100000, test.ctx()).into_balance()
            );
            let balance = account.balance<DEEP>();
            assert!(balance == 100000, 0);

            test::return_shared(account);
            test.return_to_sender(cap);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = account::EInvalidOwner)]
    fun test_deposit_as_owner_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;

        test.next_tx(alice);
        {
            let account = account::new(test.ctx());
            account_id = object::id(&account);
            account.share();
        };

        test.next_tx(bob);
        {
            let mut account = test.take_shared_by_id<Account>(account_id);
            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
        };

        abort 0
    }

    #[test, expected_failure(abort_code = account::EInvalidOwner)]
    fun test_revoke_trade_proof_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;

        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account_id = object::id(&account);
            let cap = account.mint_trade_cap(test.ctx());
            transfer::public_transfer(cap, bob);
            account.share();
        };

        test.next_tx(bob);
        {
            let mut account = test.take_shared_by_id<Account>(account_id);
            let cap = test.take_from_sender<TradeCap>();
            account.revoke_trade_cap(&object::id(&cap), test.ctx());
        };

        abort 0
    }

    #[test, expected_failure(abort_code = account::EInvalidTrader)]
    fun test_deposit_with_trader_proof_revoked_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account_id = object::id(&account);
            let cap = account.mint_trade_cap(test.ctx());
            let proof = account.generate_proof_as_trader(&cap, test.ctx());

            account.deposit_with_proof(&proof,
                mint_for_testing<SUI>(100, test.ctx()).into_balance()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            account.revoke_trade_cap(&object::id(&cap), test.ctx());
            transfer::public_transfer(cap, bob);
            account.share();
        };

        test.next_tx(bob);
        {
            let mut account = test.take_shared_by_id<Account>(account_id);
            let cap = test.take_from_sender<TradeCap>();
            let proof = account.generate_proof_as_trader(&cap, test.ctx());

            account.deposit_with_proof(&proof,
                mint_for_testing<DEEP>(100000, test.ctx()).into_balance()
            );
        };

        abort 0
    }

    #[test]
    fun test_withdraw_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = account.withdraw<SUI>(
                50,
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 50, 0);
            coin.burn_for_testing();

            account.share();
        };

        end(test);
    }

    #[test]
    fun test_withdraw_all_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = account.withdraw_all<SUI>(
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 0, 0);
            assert!(coin.burn_for_testing() == 100, 0);

            account.share();
        };

        end(test);
    }

    #[test, expected_failure(abort_code = account::EAccountBalanceTooLow)]
    fun test_withdraw_balance_too_low_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut account = account::new(test.ctx());
            account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = account.balance<SUI>();
            assert!(balance == 100, 0);

            let _coin = account.withdraw<SUI>(
                200,
                test.ctx()
            );
        };

        abort 0
    }

    public fun deposit_into_account<T>(
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
        amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut account = account::new(test.ctx());
            deposit_into_account<SUI>(&mut account, amount, test);
            deposit_into_account<SPAM>(&mut account, amount, test);
            deposit_into_account<USDC>(&mut account, amount, test);
            deposit_into_account<DEEP>(&mut account, amount, test);
            let id = object::id(&account);
            account.share();

            id
        }
    }
}
