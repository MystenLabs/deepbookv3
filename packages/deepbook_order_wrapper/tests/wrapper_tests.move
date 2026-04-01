// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_order_wrapper::wrapper_tests;

use deepbook::{
    balance_manager::{Self, BalanceManager},
    constants,
    pool::{Self, Pool},
    registry::{Self, Registry},
};
use deepbook_order_wrapper::wrapper;
use sui::{
    clock,
    coin::mint_for_testing,
    test_scenario::{Scenario, begin, end, return_shared},
};
use token::deep::DEEP;

public struct BASE has store {}
public struct QUOTE has store {}

const OWNER: address = @0xA;

#[test]
fun test_cancel_order_if_exists_noop_when_missing() {
    let mut test = begin(OWNER);
    let (pool_id, balance_manager_id) = setup(&mut test, 10 * constants::float_scaling());

    test.next_tx(OWNER);
    {
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        let clock = clock::create_for_testing(test.ctx());

        assert!(
            !wrapper::cancel_order_if_exists(
                &mut pool,
                &mut balance_manager,
                &trade_proof,
                42,
                &clock,
                test.ctx(),
            ),
        );

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

#[test]
fun test_place_limit_order_if_balance_sufficient_returns_none_when_underfunded() {
    let mut test = begin(OWNER);
    let (pool_id, balance_manager_id) = setup(&mut test, 0);

    test.next_tx(OWNER);
    {
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        let clock = clock::create_for_testing(test.ctx());

        let placed = wrapper::place_limit_order_if_balance_sufficient(
            &mut pool,
            &mut balance_manager,
            &trade_proof,
            1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            3 * constants::float_scaling(),
            true,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(placed == option::none());

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

#[test]
fun test_cancel_then_place_limit_order_if_possible_reuses_canceled_balance() {
    let mut test = begin(OWNER);
    let (pool_id, balance_manager_id) = setup(&mut test, 10 * constants::float_scaling());

    test.next_tx(OWNER);
    {
        let mut pool = test.take_shared_by_id<Pool<BASE, QUOTE>>(pool_id);
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        let clock = clock::create_for_testing(test.ctx());

        let initial_order = wrapper::place_limit_order_if_balance_sufficient(
            &mut pool,
            &mut balance_manager,
            &trade_proof,
            1,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            3 * constants::float_scaling(),
            true,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(initial_order.is_some());
        let initial_order = initial_order.destroy_some();

        let direct_replace = wrapper::place_limit_order_if_balance_sufficient(
            &mut pool,
            &mut balance_manager,
            &trade_proof,
            2,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3 * constants::float_scaling(),
            2 * constants::float_scaling(),
            true,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(direct_replace == option::none());

        let (canceled, replaced) = wrapper::cancel_order_if_exists_then_place_limit_order_if_possible(
            &mut pool,
            &mut balance_manager,
            &trade_proof,
            initial_order.order_id(),
            3,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3 * constants::float_scaling(),
            2 * constants::float_scaling(),
            true,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(canceled);
        assert!(replaced.is_some());
        let replaced = replaced.destroy_some();
        assert!(wrapper::order_exists(&pool, &balance_manager, replaced.order_id()));
        assert!(!wrapper::order_exists(&pool, &balance_manager, initial_order.order_id()));

        clock.destroy_for_testing();
        return_shared(pool);
        return_shared(balance_manager);
    };

    end(test);
}

fun setup(test: &mut Scenario, quote_balance: u64): (ID, ID) {
    let registry_id;
    let pool_id;
    let balance_manager_id;

    test.next_tx(OWNER);
    {
        registry_id = registry::test_registry(test.ctx());
    };

    test.next_tx(OWNER);
    {
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        pool_id = pool::create_permissionless_pool<BASE, QUOTE>(
            &mut registry,
            constants::float_scaling(),
            constants::float_scaling(),
            constants::float_scaling(),
            mint_for_testing<DEEP>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );
        return_shared(registry);

        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager_id = balance_manager.id();
        if (quote_balance > 0) {
            balance_manager.deposit(
                mint_for_testing<QUOTE>(quote_balance, test.ctx()),
                test.ctx(),
            );
        };
        transfer::public_share_object(balance_manager);
    };

    (pool_id, balance_manager_id)
}
