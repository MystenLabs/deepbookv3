// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::order_query_tests;

use deepbook::{
    balance_manager_tests::{
        USDC,
        create_acct_and_share_with_funds as create_acct_and_share_with_funds
    },
    constants,
    order_query::iter_orders,
    pool::Pool,
    pool_tests::{setup_test, setup_pool_with_default_fees_and_reference_pool, place_limit_order}
};
use std::unit_test::destroy;
use sui::{sui::SUI, test_scenario::{begin, end, return_shared}};
use token::deep::DEEP;

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;

#[test]
fun test_place_orders_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, DEEP>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let mut client_order_id = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let mut expire_timestamp = constants::max_u64();
    let is_bid = true;
    let pay_with_deep = true;

    while (client_order_id <= 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        client_order_id = client_order_id + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(orders.orders().length() == 10);
    assert!(orders.has_next_page() == false);
    let mut i = 1;
    while (i <= 10) {
        let order = &orders.orders()[i - 1];
        assert!(order.client_order_id() == i);
        assert!(order.price() == price);
        assert!(order.quantity() == quantity);
        assert!(order.is_bid() == is_bid);
        assert!(order.expire_timestamp() == expire_timestamp);
        i = i + 1;
    };
    return_shared(pool);

    let ask_price = 3 * constants::float_scaling();
    let ask_is_bid = false;
    while (client_order_id <= 20) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            client_order_id,
            order_type,
            constants::self_matching_allowed(),
            ask_price,
            quantity,
            ask_is_bid,
            pay_with_deep,
            expire_timestamp,
            &mut test,
        );
        client_order_id = client_order_id + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        false,
    );
    assert!(orders.orders().length() == 10);
    assert!(orders.has_next_page() == false);
    return_shared(pool);

    expire_timestamp = 100000000;
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        client_order_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::some(100000001),
        100,
        true,
    );
    assert!(orders.orders().length() == 10);

    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        5,
        true,
    );
    assert!(orders.orders().length() == 5);
    assert!(orders.has_next_page() == true);

    destroy(pool);
    end(test);
}
