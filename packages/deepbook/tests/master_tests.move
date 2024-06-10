// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::master_tests {
    use sui::{
        test_scenario::{Self as test, Scenario, begin, end},
        sui::SUI,
        coin::mint_for_testing,
    };
    use deepbook::{
        balance_manager::{Self, BalanceManager, TradeCap},
        vault::{DEEP},
        registry::{Self}
    };

    public struct SPAM has store {}
    public struct USDC has store {}

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    #[test]
    fun test_master_ok(){
        test_master()
    }

    fun test_master() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        // let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
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

    public fun deposit_into_account<T>(
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
            let id = object::id(&balance_manager);
            balance_manager.share();

            id
        }
    }
}
