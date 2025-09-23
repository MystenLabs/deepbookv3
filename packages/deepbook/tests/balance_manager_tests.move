// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::balance_manager_tests;

use deepbook::balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap, DeepBookReferral};
use sui::{coin::mint_for_testing, sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};
use sui::test_utils;
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
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        balance_manager.deposit(
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 200, 0);

        transfer::public_share_object(balance_manager);
    };

    end(test);
}

#[test]
fun test_deposit_custom_manager_ok() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    test.next_tx(alice);
    {
        let balance_manager = balance_manager::new_with_custom_owner(bob, test.ctx());
        assert!(balance_manager.owner() == bob, 0);
        transfer::public_share_object(balance_manager);
    };
    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared<BalanceManager>();
        balance_manager.deposit(
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        balance_manager.deposit(
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 200, 0);

        return_shared(balance_manager);
    };

    end(test);
}

#[test, expected_failure(abort_code = balance_manager::EInvalidOwner)]
fun test_deposit_as_owner_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;

    test.next_tx(alice);
    {
        let balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        balance_manager.deposit(
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
    };

    abort 0
}

#[test, expected_failure(abort_code = balance_manager::EInvalidOwner)]
fun test_remove_trader_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;
    let trade_cap_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        trade_cap_id = object::id(&trade_cap);
        transfer::public_transfer(trade_cap, bob);
        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        balance_manager.revoke_trade_cap(&trade_cap_id, test.ctx());
    };

    abort 0
}

#[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
fun test_deposit_with_removed_trader_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;
    let trade_cap_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        let trade_proof = balance_manager.generate_proof_as_trader(
            &trade_cap,
            test.ctx(),
        );
        trade_cap_id = object::id(&trade_cap);

        balance_manager.deposit_with_proof(
            &trade_proof,
            mint_for_testing<SUI>(100, test.ctx()).into_balance(),
        );
        transfer::public_transfer(trade_cap, bob);
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        balance_manager.revoke_trade_cap(&trade_cap_id, test.ctx());
        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = balance_manager.generate_proof_as_trader(
            &trade_cap,
            test.ctx(),
        );
        balance_manager.deposit_with_proof(
            &trade_proof,
            mint_for_testing<DEEP>(100000, test.ctx()).into_balance(),
        );
    };

    abort 0
}

#[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
fun test_deposit_with_removed_deposit_cap_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;
    let deposit_cap_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let deposit_cap = balance_manager.mint_deposit_cap(test.ctx());
        deposit_cap_id = object::id(&deposit_cap);

        balance_manager.deposit_with_cap<SUI>(
            &deposit_cap,
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        transfer::public_transfer(deposit_cap, bob);
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        balance_manager.revoke_trade_cap(&deposit_cap_id, test.ctx());
        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let deposit_cap = test.take_from_sender<DepositCap>();
        balance_manager.deposit_with_cap<SUI>(
            &deposit_cap,
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
    };

    abort 0
}

#[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
fun test_deposit_with_wrong_deposit_cap_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id_2;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        let balance_manager_2 = balance_manager::new(test.ctx());
        balance_manager_id_2 = object::id(&balance_manager_2);
        let deposit_cap = balance_manager.mint_deposit_cap(test.ctx());

        transfer::public_transfer(deposit_cap, bob);
        transfer::public_share_object(balance_manager);
        transfer::public_share_object(balance_manager_2);
    };

    test.next_tx(bob);
    {
        let mut balance_manager_2 = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_2,
        );
        let deposit_cap = test.take_from_sender<DepositCap>();
        balance_manager_2.deposit_with_cap<SUI>(
            &deposit_cap,
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
    };

    abort 0
}

#[test]
fun test_deposit_with_deposit_cap_ok() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let deposit_cap = balance_manager.mint_deposit_cap(test.ctx());

        balance_manager.deposit_with_cap<SUI>(
            &deposit_cap,
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        transfer::public_transfer(deposit_cap, bob);
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let deposit_cap = test.take_from_sender<DepositCap>();
        balance_manager.deposit_with_cap<SUI>(
            &deposit_cap,
            mint_for_testing<SUI>(100, test.ctx()),
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 200, 0);

        return_shared(balance_manager);
        test.return_to_sender(deposit_cap);
    };

    end(test);
}

#[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
fun test_withdraw_with_removed_withdraw_cap_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;
    let withdraw_cap_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let withdraw_cap = balance_manager.mint_withdraw_cap(test.ctx());
        withdraw_cap_id = object::id(&withdraw_cap);
        balance_manager.deposit(
            mint_for_testing<SUI>(1000, test.ctx()),
            test.ctx(),
        );

        let sui = balance_manager.withdraw_with_cap<SUI>(
            &withdraw_cap,
            100,
            test.ctx(),
        );
        assert!(sui.value() == 100, 0);
        sui.burn_for_testing();
        transfer::public_transfer(withdraw_cap, bob);
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 900, 0);

        balance_manager.revoke_trade_cap(&withdraw_cap_id, test.ctx());
        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let sui = balance_manager.withdraw_with_cap<SUI>(
            &withdraw_cap,
            100,
            test.ctx(),
        );
        sui.burn_for_testing();
    };

    abort 0
}

#[test, expected_failure(abort_code = balance_manager::EInvalidTrader)]
fun test_withdraw_with_wrong_withdraw_cap_e() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id_2;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        let mut balance_manager_2 = balance_manager::new(test.ctx());
        balance_manager_id_2 = object::id(&balance_manager_2);
        let withdraw_cap = balance_manager.mint_withdraw_cap(test.ctx());
        balance_manager_2.deposit(
            mint_for_testing<SUI>(1000, test.ctx()),
            test.ctx(),
        );

        transfer::public_transfer(withdraw_cap, bob);

        transfer::public_share_object(balance_manager);
        transfer::public_share_object(balance_manager_2);
    };

    test.next_tx(bob);
    {
        let mut balance_manager_2 = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_2,
        );
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let sui = balance_manager_2.withdraw_with_cap<SUI>(
            &withdraw_cap,
            100,
            test.ctx(),
        );
        sui.burn_for_testing();
    };

    abort 0
}

#[test]
fun test_withdraw_with_withdraw_cap_ok() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let bob = @0xB;
    let balance_manager_id;

    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = object::id(&balance_manager);
        let withdraw_cap = balance_manager.mint_withdraw_cap(test.ctx());
        balance_manager.deposit(
            mint_for_testing<SUI>(1000, test.ctx()),
            test.ctx(),
        );

        let sui = balance_manager.withdraw_with_cap<SUI>(
            &withdraw_cap,
            100,
            test.ctx(),
        );
        assert!(sui.value() == 100, 0);
        sui.burn_for_testing();
        transfer::public_transfer(withdraw_cap, bob);
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 900, 0);

        transfer::public_share_object(balance_manager);
    };

    test.next_tx(bob);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let sui = balance_manager.withdraw_with_cap<SUI>(
            &withdraw_cap,
            100,
            test.ctx(),
        );
        sui.burn_for_testing();
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 800, 0);

        return_shared(balance_manager);
        test.return_to_sender(withdraw_cap);
    };

    end(test);
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
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        let coin = balance_manager.withdraw<SUI>(
            50,
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 50, 0);
        coin.burn_for_testing();

        transfer::public_share_object(balance_manager);
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
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        let coin = balance_manager.withdraw_all<SUI>(test.ctx());
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 0, 0);
        assert!(coin.burn_for_testing() == 100, 0);

        transfer::public_share_object(balance_manager);
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
            test.ctx(),
        );
        let balance = balance_manager.balance<SUI>();
        assert!(balance == 100, 0);

        let _coin = balance_manager.withdraw<SUI>(
            200,
            test.ctx(),
        );
    };

    abort 0
}

#[test]
fun test_referral_ok() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    let referral_id1;
    let referral_id2;
    test.next_tx(alice);
    {
        referral_id1 = balance_manager::mint_referral(test.ctx());
        referral_id2 = balance_manager::mint_referral(test.ctx());
    };

    test.next_tx(alice);
    {
        let referral1 = test.take_shared_by_id<DeepBookReferral>(referral_id1);
        assert!(referral1.referral_owner() == alice, 0);
        let referral2 = test.take_shared_by_id<DeepBookReferral>(referral_id2);
        assert!(referral2.referral_owner() == alice, 0);

        let mut balance_manager = balance_manager::new(test.ctx());
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.set_referral(&referral1, &trade_cap);
        assert!(balance_manager.get_referral_id() == option::some(referral_id1), 0);
        balance_manager.set_referral(&referral2, &trade_cap);
        assert!(balance_manager.get_referral_id() == option::some(referral_id2), 0);

        balance_manager.unset_referral(&trade_cap);
        assert!(balance_manager.get_referral_id() == option::none(), 0);

        transfer::public_share_object(balance_manager);
        return_shared(referral1);
        return_shared(referral2);
        test_utils::destroy(trade_cap);
    };

    end(test);
}

#[test]
fun test_unset_no_referral_ok() {
    let mut test = begin(@0xF);
    let alice = @0xA;
    test.next_tx(alice);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        balance_manager.unset_referral(&trade_cap);
        assert!(balance_manager.get_referral_id() == option::none(), 0);

        transfer::public_share_object(balance_manager);
        test_utils::destroy(trade_cap);
    };

    end(test);
}

public(package) fun deposit_into_account<T>(
    balance_manager: &mut BalanceManager,
    amount: u64,
    test: &mut Scenario,
) {
    balance_manager.deposit(
        mint_for_testing<T>(amount, test.ctx()),
        test.ctx(),
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
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        transfer::public_transfer(trade_cap, sender);
        let id = object::id(&balance_manager);
        transfer::public_share_object(balance_manager);

        id
    }
}

public(package) fun create_acct_and_share_with_funds_typed<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    amount: u64,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    {
        let mut balance_manager = balance_manager::new(test.ctx());
        deposit_into_account<BaseAsset>(&mut balance_manager, amount, test);
        deposit_into_account<QuoteAsset>(&mut balance_manager, amount, test);
        deposit_into_account<ReferenceBaseAsset>(
            &mut balance_manager,
            amount,
            test,
        );
        deposit_into_account<ReferenceQuoteAsset>(
            &mut balance_manager,
            amount,
            test,
        );
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        transfer::public_transfer(trade_cap, sender);
        let id = object::id(&balance_manager);
        transfer::public_share_object(balance_manager);

        id
    }
}
