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
        deep_per_base: u64,

    ): Order {

    }

    public fun create_order(
        price: u64,
        quantity: u64,
        deep_per_base: u64,
        epoch: u64,
        expire_timestamp: u64,
    )
}