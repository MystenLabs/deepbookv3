// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook::order_tests {
    use sui::{
        test_scenario::{next_tx, begin, end},
        test_utils::assert_eq,
        object::id_from_address,
    };
    use deepbook::{
        order::{Self, Order},
        utils,
        balances,
        constants,
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;



    public fun create_order_base(
        price: u64,
        quantity: u64,
        is_bid: bool,
    ): Order {
        let deep_per_base = 1 * constants::float_scaling();
        let order_id = 1;
        let balance_manager_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = constants::max_u64();

        create_order(
            price,
            quantity,
            is_bid,
            order_id,
            balance_manager_id,
            deep_per_base,
            epoch,
            expire_timestamp,
        )
    }

    public fun create_order(
        price: u64,
        quantity: u64,
        is_bid: bool,
        order_id: u64,
        balance_manager_id: ID,
        deep_per_base: u64,
        epoch: u64,
        expire_timestamp: u64,
    ): Order {
        let order_id = utils::encode_order_id(is_bid, price, order_id);

        order::new(
            order_id,
            balance_manager_id,
            1,
            quantity,
            deep_per_base,
            epoch,
            constants::live(),
            expire_timestamp,
        )
    }
}