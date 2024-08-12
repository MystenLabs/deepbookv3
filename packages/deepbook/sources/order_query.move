// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module defines the OrderPage struct and its methods to iterate over orders in a pool.
module deepbook::order_query;
use deepbook::big_vector::slice_borrow;
use deepbook::constants;
use deepbook::order::Order;
use deepbook::pool::Pool;

// === Structs ===
public struct OrderPage has drop {
    orders: vector<Order>,
    has_next_page: bool,
}

// === Public Functions ===
public fun iter_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    start_order_id: Option<u128>,
    end_order_id: Option<u128>,
    min_expire_timestamp: Option<u64>,
    limit: u64,
    bids: bool,
): OrderPage {
    let self = self.load_inner();
    let key_low = 0;
    let key_high = ((constants::max_price() as u128) << 64) + (
        ((1u128 << 64) - 1) as u128,
    );
    let start = if (start_order_id.is_some()) {
        *start_order_id.borrow()
    } else {
        if (bids) {
            key_high
        } else {
            key_low
        }
    };
    let end = if (end_order_id.is_some()) {
        *end_order_id.borrow()
    } else {
        if (bids) {
            key_low
        } else {
            key_high
        }
    };
    let min_expire = if (min_expire_timestamp.is_some()) {
        *min_expire_timestamp.borrow()
    } else {
        0
    };
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

        (ref, offset) =
            if (bids) side.prev_slice(ref, offset)
            else side.next_slice(ref, offset);
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
