// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::balance_manager_tests {
    use sui::{
        test_scenario::{Scenario, begin, end},
        sui::SUI,
        coin::mint_for_testing,
    };
    use deepbook::{
        balance_manager::{Self, BalanceManager},
    };
    use token::deep::DEEP;

    public struct SPAM has store {}
    public struct USDC has store {}
    public struct USDT has store {}

    #[test]
    fun test_deposit_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            assert!(balance_manager.owner() == alice, 0);
            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 100, 0);

            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 200, 0);

            balance_manager.share();
        };

        end(test);
    }

    #[test, expected_failure(abort_code = balance_manager::EInvalidOwner)]
    fun test_deposit_as_owner_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;

        test.next_tx(alice);
        {
            let balance_manager = balance_manager::new(test.ctx());
            account_id = object::id(&balance_manager);
            balance_manager.share();
        };

        test.next_tx(bob);
        {
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(account_id);
            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
        };

        abort 0
    }

    #[test, expected_failure(abort_code = balance_manager::EInvalidOwner)]
    fun test_remove_trader_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;

        test.next_tx(alice);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            account_id = object::id(&balance_manager);
            balance_manager.authorize_trader(bob, test.ctx());
            balance_manager.share();
        };

        test.next_tx(bob);
        {
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(account_id);
            balance_manager.remove_trader(bob, test.ctx());
        };

        abort 0
    }

    #[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
    fun test_deposit_with_removed_trader_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let account_id;
        test.next_tx(alice);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            account_id = object::id(&balance_manager);
            balance_manager.authorize_trader(bob, test.ctx());

            balance_manager.deposit_protected(
                mint_for_testing<SUI>(100, test.ctx()).into_balance(), test.ctx(),
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 100, 0);

            balance_manager.remove_trader(bob, test.ctx());
            balance_manager.share();
        };

        test.next_tx(bob);
        {
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(account_id);

            balance_manager.deposit_protected(
                mint_for_testing<DEEP>(100000, test.ctx()).into_balance(), test.ctx()
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
            let mut balance_manager = balance_manager::new(test.ctx());
            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = balance_manager.withdraw<SUI>(
                50,
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 50, 0);
            coin.burn_for_testing();

            balance_manager.share();
        };

        end(test);
    }

    #[test]
    fun test_withdraw_all_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = balance_manager.withdraw_all<SUI>(
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 0, 0);
            assert!(coin.burn_for_testing() == 100, 0);

            balance_manager.share();
        };

        end(test);
    }

    #[test, expected_failure(abort_code = balance_manager::EBalanceManagerBalanceTooLow)]
    fun test_withdraw_balance_too_low_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            balance_manager.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx()
            );
            let balance = balance_manager.balance<SUI>();
            assert!(balance == 100, 0);

            let _coin = balance_manager.withdraw<SUI>(
                200,
                test.ctx()
            );
        };

        abort 0
    }

    public(package) fun deposit_into_account<T>(
        balance_manager: &mut BalanceManager,
        amount: u64,
        test: &mut Scenario,
    ) {
        balance_manager.deposit(
            mint_for_testing<T>(amount, test.ctx()),
            test.ctx()
        );
    }

    public(package) fun create_acct_and_share_with_funds(
        sender: address,
        amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut balance_manager = balance_manager::new(test.ctx());
            deposit_into_account<SUI>(&mut balance_manager, amount, test);
            deposit_into_account<SPAM>(&mut balance_manager, amount, test);
            deposit_into_account<USDC>(&mut balance_manager, amount, test);
            deposit_into_account<DEEP>(&mut balance_manager, amount, test);
            deposit_into_account<USDT>(&mut balance_manager, amount, test);
            let id = object::id(&balance_manager);
            balance_manager.share();

            id
        }
    }
}
