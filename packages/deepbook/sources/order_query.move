// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module defines the OrderPage struct and its methods to iterate over orders in a pool.
module deepbook::order_query;

use deepbook::{big_vector::slice_borrow, constants, order::Order, pool::Pool};

// === Structs ===
public struct OrderPage has drop {
    orders: vector<Order>,
    has_next_page: bool,
}

// === Public Functions ===
/// Bid minimum order id has 0 for its first bit, 0 for next 63 bits for price, and 1 for next 64 bits for order id.
/// Ask minimum order id has 1 for its first bit, 0 for next 63 bits for price, and 0 for next 64 bits for order id.
/// Bids are iterated from high to low order id, and asks are iterated from low to high order id.
public fun iter_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    start_order_id: Option<u128>,
    end_order_id: Option<u128>,
    min_expire_timestamp: Option<u64>,
    limit: u64,
    bids: bool,
): OrderPage {
    let self = self.load_inner();
    let bid_min_order_id = 0;
    let bid_max_order_id = 1u128 << 127;

    let ask_min_order_id = 1u128 << 127;
    let ask_max_order_id = constants::max_u128();

    let start = start_order_id.get_with_default({
        if (bids) bid_max_order_id else ask_min_order_id
    });

    let end = end_order_id.get_with_default({
        if (bids) bid_min_order_id else ask_max_order_id
    });

    let min_expire = min_expire_timestamp.get_with_default(0);
    let side = if (bids) self.bids() else self.asks();
    let mut orders = vector[];
    let (mut ref, mut offset) = if (bids) {
        side.slice_before(start)
    } else {
        side.slice_following(start)
    };

    while (!ref.is_null() && orders.length() < limit) {
        let order = slice_borrow(side.borrow_slice(ref), offset);
        if (bids && order.order_id() < end) break;
        if (!bids && order.order_id() > end) break;
        if (order.expire_timestamp() >= min_expire) {
            orders.push_back(order.copy_order());
        };

        (ref, offset) = if (bids) side.prev_slice(ref, offset) else side.next_slice(ref, offset);
    };

    OrderPage {
        orders: orders,
        has_next_page: !ref.is_null(),
    }
}

public fun orders(self: &OrderPage): &vector<Order> {
    &self.orders
}

public fun has_next_page(self: &OrderPage): bool {
    self.has_next_page
}
