// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
module deepbook::book {
    // === Imports ===
    use deepbook::{
        big_vector::{Self, BigVector, slice_borrow, slice_borrow_mut},
        utils,
        math,
        order::Order,
        order_info::OrderInfo,
        constants,
        deep_price::OrderDeepPrice,
    };

    // === Errors ===
    const EInvalidAmountIn: u64 = 1;
    const EEmptyOrderbook: u64 = 2;
    const EInvalidPriceRange: u64 = 3;
    const EInvalidTicks: u64 = 4;
    const EOrderBelowMinimumSize: u64 = 5;
    const EOrderInvalidLotSize: u64 = 6;
    const ENewQuantityMustBeLessThanOriginal: u64 = 7;

    // === Constants ===
    const START_BID_ORDER_ID: u64 = ((1u128 << 64) - 1) as u64;
    const START_ASK_ORDER_ID: u64 = 1;

    // === Structs ===
    public struct Book has store {
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
    }

    // === Public-Package Functions ===
    public(package) fun bids(self: &Book): &BigVector<Order> {
        &self.bids
    }

    public(package) fun asks(self: &Book): &BigVector<Order> {
        &self.asks
    }

    public(package) fun lot_size(self: &Book): u64 {
        self.lot_size
    }

    public(package) fun min_size(self: &Book): u64 {
        self.min_size
    }

    public(package) fun empty(
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        ctx: &mut TxContext,
    ): Book {
        Book {
            tick_size,
            lot_size,
            min_size,
            bids: big_vector::empty(constants::max_slice_size(), constants::max_fan_out(), ctx),
            asks: big_vector::empty(constants::max_slice_size(), constants::max_fan_out(), ctx),
            next_bid_order_id: START_BID_ORDER_ID,
            next_ask_order_id: START_ASK_ORDER_ID,
        }
    }

    /// Creates a new order.
    /// Order is matched against the book and injected into the book if necessary.
    /// If order is IOC or fully executed, it will not be injected.
    public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        order_info.validate_inputs(self.tick_size, self.min_size, self.lot_size, timestamp);
        let order_id = utils::encode_order_id(
            order_info.is_bid(),
            order_info.price(),
            self.get_order_id(order_info.is_bid()),
        );
        order_info.set_order_id(order_id);
        self.match_against_book(order_info, timestamp);
        if (order_info.assert_execution()) return;
        self.inject_limit_order(order_info);
        order_info.set_order_inserted();
        order_info.emit_order_placed();
    }

    /// Given base_quantity and quote_quantity, calculate the base_quantity_out and quote_quantity_out.
    /// Will return (base_quantity_out, quote_quantity_out, deep_quantity_required) if base_amount > 0 or quote_amount > 0.
    public(package) fun get_quantity_out(
        self: &Book,
        base_quantity: u64,
        quote_quantity: u64,
        taker_fee: u64,
        deep_price: OrderDeepPrice,
        lot_size: u64,
        current_timestamp: u64,
    ): (u64, u64, u64) {
        assert!(
            (base_quantity > 0 || quote_quantity > 0) && !(base_quantity > 0 && quote_quantity > 0),
            EInvalidAmountIn,
        );
        let is_bid = quote_quantity > 0;
        let mut quantity_out = 0;
        let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

        let book_side = if (is_bid) &self.asks else &self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();

        while (!ref.is_null() && quantity_in_left > 0) {
            let order = slice_borrow(book_side.borrow_slice(ref), offset);
            let cur_price = order.price();
            let cur_quantity = order.quantity() - order.filled_quantity();

            if (current_timestamp <= order.expire_timestamp()) {
                let mut matched_base_quantity;
                if (is_bid) {
                    matched_base_quantity = math::div(quantity_in_left, cur_price).min(cur_quantity);
                    matched_base_quantity = matched_base_quantity -
                    matched_base_quantity % lot_size;
                    quantity_out = quantity_out + matched_base_quantity;
                    quantity_in_left = quantity_in_left -
                    math::mul(matched_base_quantity, cur_price);
                } else {
                    matched_base_quantity = quantity_in_left.min(cur_quantity);
                    matched_base_quantity = matched_base_quantity -
                    matched_base_quantity % lot_size;
                    quantity_out = quantity_out + math::mul(matched_base_quantity, cur_price);
                    quantity_in_left = quantity_in_left - matched_base_quantity;
                };

                if (matched_base_quantity == 0) break;
            };

            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
            else book_side.prev_slice(ref, offset);
        };

        let quantity_in_deep = if (is_bid) {
            deep_price.deep_quantity(quantity_out, quote_quantity - quantity_in_left)
        } else {
            deep_price.deep_quantity(base_quantity - quantity_in_left, quantity_out)
        };
        let deep_fee = math::mul(taker_fee, quantity_in_deep);

        if (is_bid) {
            (quantity_out, quantity_in_left, deep_fee)
        } else {
            (quantity_in_left, quantity_out, deep_fee)
        }
    }

    /// Cancels an order given order_id
    public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
        self.book_side_mut(order_id).remove(order_id)
    }

    /// Modifies an order given order_id and new_quantity.
    /// New quantity must be less than the original quantity.
    /// Order must not have already expired.
    public(package) fun modify_order(
        self: &mut Book,
        order_id: u128,
        new_quantity: u64,
        timestamp: u64,
    ): (u64, &Order) {
        assert!(new_quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(new_quantity % self.lot_size == 0, EOrderInvalidLotSize);

        let order = self.book_side_mut(order_id).borrow_mut(order_id);
        assert!(new_quantity < order.quantity(), ENewQuantityMustBeLessThanOriginal);
        let cancel_quantity = order.quantity() - new_quantity;
        order.modify(new_quantity, timestamp);

        (cancel_quantity, order)
    }

    /// Returns the mid price of the order book.
    public(package) fun mid_price(self: &Book, current_timestamp: u64): u64 {
        let (mut ask_ref, mut ask_offset) = self.asks.min_slice();
        let (mut bid_ref, mut bid_offset) = self.bids.max_slice();
        let mut best_ask_price = 0;
        let mut best_bid_price = 0;

        while (!ask_ref.is_null()) {
            let best_ask_order = slice_borrow(self.asks.borrow_slice(ask_ref), ask_offset);
            best_ask_price = best_ask_order.price();
            if (current_timestamp <= best_ask_order.expire_timestamp()) break;
            (ask_ref, ask_offset) = self.asks.next_slice(ask_ref, ask_offset);
        };

        while (!bid_ref.is_null()) {
            let best_bid_order = slice_borrow(self.bids.borrow_slice(bid_ref), bid_offset);
            best_bid_price = best_bid_order.price();
            if (current_timestamp <= best_bid_order.expire_timestamp()) break;
            (bid_ref, bid_offset) = self.bids.prev_slice(bid_ref, bid_offset);
        };

        assert!(!ask_ref.is_null() && !bid_ref.is_null(), EEmptyOrderbook);

        math::mul(best_ask_price + best_bid_price, constants::half())
    }

    /// Returns the best bids and asks.
    /// The number of ticks is the number of price levels to return.
    /// The price_low and price_high are the range of prices to return.
    public(package) fun get_level2_range_and_ticks(
        self: &Book,
        price_low: u64,
        price_high: u64,
        ticks: u64,
        is_bid: bool,
        current_timestamp: u64,
    ): (vector<u64>, vector<u64>) {
        assert!(price_low <= price_high, EInvalidPriceRange);
        assert!(price_low >= constants::min_price() && price_low <= constants::max_price(), EInvalidPriceRange);
        assert!(price_high >= constants::min_price() && price_high <= constants::max_price(), EInvalidPriceRange);
        assert!(ticks > 0, EInvalidTicks);

        let mut price_vec = vector[];
        let mut quantity_vec = vector[];

        // convert price_low and price_high to keys for searching
        let msb = if (is_bid) {(0 as u128)} else {(1 as u128) << 127};
        let key_low = ((price_low as u128) << 64) + msb;
        let key_high = ((price_high as u128) << 64) + (((1u128 << 64) - 1) as u128) + msb;
        let book_side = if (is_bid) &self.bids else &self.asks;
        let (mut ref, mut offset) = if (is_bid) {
            book_side.slice_before(key_high)
        } else {
            book_side.slice_following(key_low)
        };
        let mut ticks_left = ticks;
        let mut cur_price = 0;
        let mut cur_quantity = 0;

        while (!ref.is_null() && ticks_left > 0) {
            let order = slice_borrow(book_side.borrow_slice(ref), offset);
            if (current_timestamp <= order.expire_timestamp()) {
                let (_, order_price, _) = utils::decode_order_id(order.order_id());
                if ((is_bid && order_price < price_low) || (!is_bid && order_price > price_high)) break;
                if (cur_price == 0 && ((is_bid && order_price <= price_high) || (!is_bid && order_price >= price_low))) {
                    cur_price = order_price
                };

                if (cur_price != 0 && order_price != cur_price) {
                    price_vec.push_back(cur_price);
                    quantity_vec.push_back(cur_quantity);
                    cur_price = order_price;
                    cur_quantity = 0;
                    ticks_left = ticks_left - 1;
                };
                if (cur_price != 0) {
                    cur_quantity = cur_quantity + order.quantity() - order.filled_quantity();
                };
            };

            (ref, offset) = if (is_bid) book_side.prev_slice(ref, offset) else book_side.next_slice(ref, offset);
        };

        if (cur_price != 0) {
            price_vec.push_back(cur_price);
            quantity_vec.push_back(cur_quantity);
        };

        (price_vec, quantity_vec)
    }

    public(package) fun get_order(self: &Book, order_id: u128): Order {
        let order = self.book_side(order_id).borrow(order_id);

        order.copy_order()
    }

    // === Private Functions ===
    // Access side of book where order_id belongs
    fun book_side_mut(self: &mut Book, order_id: u128): &mut BigVector<Order> {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        if (is_bid) {
            &mut self.bids
        } else {
            &mut self.asks
        }
    }

    fun book_side(self: &Book, order_id: u128): &BigVector<Order> {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        if (is_bid) {
            &self.bids
        } else {
            &self.asks
        }
    }

    /// Matches the given order and quantity against the order book.
    /// If is_bid, it will match against asks, otherwise against bids.
    /// Mutates the order and the maker order as necessary.
    fun match_against_book(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        let is_bid = order_info.is_bid();
        let book_side = if (is_bid) &mut self.asks else &mut self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();

        while (!ref.is_null() && order_info.fills().length() < constants::max_fills()) {
            let maker_order = slice_borrow_mut(book_side.borrow_slice_mut(ref), offset);
            if (!order_info.match_maker(maker_order, timestamp)) break;
            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
            else book_side.prev_slice(ref, offset);
        };

        order_info.emit_orders_filled(timestamp);
        order_info.fills().do_ref!(|fill| {
            if (fill.expired() || fill.completed()) {
                book_side.remove(fill.maker_order_id());
            };
        });

        if (order_info.fills().length() == constants::max_fills()) {
            order_info.set_fill_limit_reached();
        }
    }

    fun get_order_id(self: &mut Book, is_bid: bool): u64 {
        if (is_bid) {
            self.next_bid_order_id = self.next_bid_order_id - 1;
            self.next_bid_order_id
        } else {
            self.next_ask_order_id = self.next_ask_order_id + 1;
            self.next_ask_order_id
        }
    }

    /// Balance accounting happens before this function is called
    fun inject_limit_order(self: &mut Book, order_info: &OrderInfo) {
        let order = order_info.to_order();
        if (order_info.is_bid()) {
            self.bids.insert(order_info.order_id(), order);
        } else {
            self.asks.insert(order_info.order_id(), order);
        };
    }
}
