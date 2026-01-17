// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
module deepbook::book;

use deepbook::{
    big_vector::{Self, BigVector, slice_borrow, slice_borrow_mut},
    constants,
    deep_price::OrderDeepPrice,
    math,
    order::Order,
    order_info::OrderInfo,
    utils
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

public(package) fun tick_size(self: &Book): u64 {
    self.tick_size
}

public(package) fun lot_size(self: &Book): u64 {
    self.lot_size
}

public(package) fun min_size(self: &Book): u64 {
    self.min_size
}

public(package) fun empty(tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext): Book {
    Book {
        tick_size,
        lot_size,
        min_size,
        bids: big_vector::empty(
            constants::max_slice_size(),
            constants::max_fan_out(),
            ctx,
        ),
        asks: big_vector::empty(
            constants::max_slice_size(),
            constants::max_fan_out(),
            ctx,
        ),
        next_bid_order_id: START_BID_ORDER_ID,
        next_ask_order_id: START_ASK_ORDER_ID,
    }
}

/// Creates a new order.
/// Order is matched against the book and injected into the book if necessary.
/// If order is IOC or fully executed, it will not be injected.
public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
    order_info.validate_inputs(
        self.tick_size,
        self.min_size,
        self.lot_size,
        timestamp,
    );
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

/// Given base_quantity and quote_quantity, calculate the base_quantity_out and
/// quote_quantity_out.
/// Will return (base_quantity_out, quote_quantity_out, deep_quantity_required)
/// if base_amount > 0 or quote_amount > 0.
public(package) fun get_quantity_out(
    self: &Book,
    base_quantity: u64,
    quote_quantity: u64,
    taker_fee: u64,
    deep_price: OrderDeepPrice,
    lot_size: u64,
    pay_with_deep: bool,
    current_timestamp: u64,
): (u64, u64, u64) {
    assert!((base_quantity > 0) != (quote_quantity > 0), EInvalidAmountIn);
    let is_bid = quote_quantity > 0;
    let input_fee_rate = math::mul(
        constants::fee_penalty_multiplier(),
        taker_fee,
    );
    if (base_quantity > 0) {
        let trading_base_quantity = if (pay_with_deep) {
            base_quantity
        } else {
            math::div(base_quantity, constants::float_scaling() + input_fee_rate)
        };
        if (trading_base_quantity < self.min_size) {
            return (base_quantity, quote_quantity, 0)
        }
    };

    let mut quantity_out = 0;
    let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

    let book_side = if (is_bid) &self.asks else &self.bids;
    let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();
    let max_fills = constants::max_fills();
    let mut current_fills = 0;

    while (!ref.is_null() && quantity_in_left > 0 && current_fills < max_fills) {
        let order = slice_borrow(book_side.borrow_slice(ref), offset);
        let cur_price = order.price();
        let cur_quantity = order.quantity() - order.filled_quantity();

        if (current_timestamp <= order.expire_timestamp()) {
            let mut matched_base_quantity;
            let quantity_to_match = if (pay_with_deep) {
                quantity_in_left
            } else {
                math::div(
                    quantity_in_left,
                    constants::float_scaling() + input_fee_rate,
                )
            };
            if (is_bid) {
                matched_base_quantity = math::div(quantity_to_match, cur_price).min(cur_quantity);
                matched_base_quantity =
                    matched_base_quantity -
                    matched_base_quantity % lot_size;
                quantity_out = quantity_out + matched_base_quantity;
                let matched_quote_quantity = math::mul(
                    matched_base_quantity,
                    cur_price,
                );
                quantity_in_left = quantity_in_left - matched_quote_quantity;
                if (!pay_with_deep) {
                    quantity_in_left =
                        quantity_in_left -
                        math::mul(matched_quote_quantity, input_fee_rate);
                };
            } else {
                matched_base_quantity = quantity_to_match.min(cur_quantity);
                matched_base_quantity =
                    matched_base_quantity -
                    matched_base_quantity % lot_size;
                quantity_out = quantity_out + math::mul(matched_base_quantity, cur_price);
                quantity_in_left = quantity_in_left - matched_base_quantity;
                if (!pay_with_deep) {
                    quantity_in_left =
                        quantity_in_left -
                        math::mul(matched_base_quantity, input_fee_rate);
                };
            };

            if (matched_base_quantity == 0) break;
        };

        (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
        else book_side.prev_slice(ref, offset);
        current_fills = current_fills + 1;
    };

    let deep_fee = if (!pay_with_deep) {
        0
    } else {
        let fee_quantity = if (is_bid) {
            deep_price.fee_quantity(
                quantity_out,
                quote_quantity - quantity_in_left,
                is_bid,
            )
        } else {
            deep_price.fee_quantity(
                base_quantity - quantity_in_left,
                quantity_out,
                is_bid,
            )
        };

        math::mul(taker_fee, fee_quantity.deep())
    };

    if (is_bid) {
        if (quantity_out < self.min_size) {
            (base_quantity, quote_quantity, 0)
        } else {
            (quantity_out, quantity_in_left, deep_fee)
        }
    } else {
        (quantity_in_left, quantity_out, deep_fee)
    }
}

/// Given a target quote_quantity to receive from selling, calculate the minimum base_quantity needed.
/// This is the inverse of get_quantity_out for ask orders.
/// Returns (base_quantity_in, actual_quote_quantity_out, deep_quantity_required)
/// Returns (0, 0, 0) if insufficient liquidity or if result would be below min_size.
public(package) fun get_base_quantity_in(
    self: &Book,
    target_quote_quantity: u64,
    taker_fee: u64,
    deep_price: OrderDeepPrice,
    pay_with_deep: bool,
    current_timestamp: u64,
): (u64, u64, u64) {
    self.get_quantity_in(
        0, // target_base_quantity = 0, we want quote
        target_quote_quantity,
        taker_fee,
        deep_price,
        pay_with_deep,
        current_timestamp,
    )
}

/// Given a target base_quantity to receive from buying, calculate the minimum quote_quantity needed.
/// This is the inverse of get_quantity_out for bid orders.
/// Returns (actual_base_quantity_out, quote_quantity_in, deep_quantity_required)
/// Returns (0, 0, 0) if insufficient liquidity or if result would be below min_size.
public(package) fun get_quote_quantity_in(
    self: &Book,
    target_base_quantity: u64,
    taker_fee: u64,
    deep_price: OrderDeepPrice,
    pay_with_deep: bool,
    current_timestamp: u64,
): (u64, u64, u64) {
    self.get_quantity_in(
        target_base_quantity,
        0, // target_quote_quantity = 0, we want base
        taker_fee,
        deep_price,
        pay_with_deep,
        current_timestamp,
    )
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
        let best_ask_order = slice_borrow(
            self.asks.borrow_slice(ask_ref),
            ask_offset,
        );
        best_ask_price = best_ask_order.price();
        if (current_timestamp <= best_ask_order.expire_timestamp()) break;
        (ask_ref, ask_offset) = self.asks.next_slice(ask_ref, ask_offset);
    };

    while (!bid_ref.is_null()) {
        let best_bid_order = slice_borrow(
            self.bids.borrow_slice(bid_ref),
            bid_offset,
        );
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
    assert!(
        price_low >= constants::min_price() &&
        price_low <= constants::max_price(),
        EInvalidPriceRange,
    );
    assert!(
        price_high >= constants::min_price() &&
        price_high <= constants::max_price(),
        EInvalidPriceRange,
    );
    assert!(ticks > 0, EInvalidTicks);

    let mut price_vec = vector[];
    let mut quantity_vec = vector[];

    // convert price_low and price_high to keys for searching
    let msb = if (is_bid) {
        0u128
    } else {
        1u128 << 127
    };
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
            if (
                (is_bid && order_price < price_low) || (
                    !is_bid && order_price > price_high,
                )
            ) break;
            if (
                cur_price == 0 && (
                    (is_bid && order_price <= price_high) || (
                        !is_bid && order_price >= price_low,
                    ),
                )
            ) {
                cur_price = order_price
            };

            if (cur_price != 0 && order_price != cur_price) {
                price_vec.push_back(cur_price);
                quantity_vec.push_back(cur_quantity);
                cur_price = order_price;
                cur_quantity = 0;
                ticks_left = ticks_left - 1;
                if (ticks_left == 0) break;
            };
            if (cur_price != 0) {
                cur_quantity = cur_quantity + order.quantity() - order.filled_quantity();
            };
        };

        (ref, offset) = if (is_bid) book_side.prev_slice(ref, offset)
        else book_side.next_slice(ref, offset);
    };

    if (cur_price != 0 && ticks_left > 0) {
        price_vec.push_back(cur_price);
        quantity_vec.push_back(cur_quantity);
    };

    (price_vec, quantity_vec)
}

public(package) fun check_limit_order_params(
    self: &Book,
    price: u64,
    quantity: u64,
    expire_timestamp: u64,
    timestamp_ms: u64,
): bool {
    if (expire_timestamp <= timestamp_ms) {
        return false
    };
    if (quantity < self.min_size || quantity % self.lot_size != 0) {
        return false
    };
    if (
        price % self.tick_size != 0 || price < constants::min_price() || price > constants::max_price()
    ) {
        return false
    };

    true
}

public(package) fun check_market_order_params(self: &Book, quantity: u64): bool {
    if (quantity < self.min_size || quantity % self.lot_size != 0) {
        return false
    };

    true
}

public(package) fun get_order(self: &Book, order_id: u128): Order {
    let order = self.book_side(order_id).borrow(order_id);

    order.copy_order()
}

public(package) fun set_tick_size(self: &mut Book, new_tick_size: u64) {
    self.tick_size = new_tick_size;
}

public(package) fun set_lot_size(self: &mut Book, new_lot_size: u64) {
    self.lot_size = new_lot_size;
}

public(package) fun set_min_size(self: &mut Book, new_min_size: u64) {
    self.min_size = new_min_size;
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
    let max_fills = constants::max_fills();
    let mut current_fills = 0;

    while (!ref.is_null() &&
        current_fills < max_fills) {
        let maker_order = slice_borrow_mut(
            book_side.borrow_slice_mut(ref),
            offset,
        );
        if (!order_info.match_maker(maker_order, timestamp)) break;
        (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
        else book_side.prev_slice(ref, offset);
        current_fills = current_fills + 1;
    };

    order_info.fills_ref().do_ref!(|fill| {
        if (fill.expired() || fill.completed()) {
            book_side.remove(fill.maker_order_id());
        };
    });

    if (current_fills == max_fills) {
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

/// Rounds up a quantity to the nearest lot_size multiple.
/// Returns the smallest multiple of lot_size that is >= quantity.
fun round_up_to_lot_size(quantity: u64, lot_size: u64): u64 {
    let remainder = quantity % lot_size;
    if (remainder == 0) quantity else quantity + lot_size - remainder
}

/// If target_base_quantity > 0: Calculate quote needed to buy that base (bid order)
/// If target_quote_quantity > 0: Calculate base needed to get that quote (ask order)
/// Returns (base_result, quote_result, deep_quantity_required)
fun get_quantity_in(
    self: &Book,
    target_base_quantity: u64,
    target_quote_quantity: u64,
    taker_fee: u64,
    deep_price: OrderDeepPrice,
    pay_with_deep: bool,
    current_timestamp: u64,
): (u64, u64, u64) {
    assert!((target_base_quantity > 0) != (target_quote_quantity > 0), EInvalidAmountIn);
    let is_bid = target_base_quantity > 0;
    let input_fee_rate = math::mul(
        constants::fee_penalty_multiplier(),
        taker_fee,
    );
    let lot_size = self.lot_size;

    let mut input_quantity = 0; // This will be quote for bid, base for ask (may include fees)
    let mut output_accumulated = 0; // This will be base for bid, quote for ask
    let mut traded_base = 0; // Raw base traded, used for min_size checks on asks

    // For bid: traverse asks (we're buying base with quote)
    // For ask: traverse bids (we're selling base for quote)
    let book_side = if (is_bid) &self.asks else &self.bids;
    let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();
    let max_fills = constants::max_fills();
    let mut current_fills = 0;
    let target = if (is_bid) target_base_quantity else target_quote_quantity;

    while (!ref.is_null() && output_accumulated < target && current_fills < max_fills) {
        let order = slice_borrow(book_side.borrow_slice(ref), offset);
        let cur_price = order.price();
        let cur_quantity = order.quantity() - order.filled_quantity();

        if (current_timestamp <= order.expire_timestamp()) {
            let output_needed = target - output_accumulated;

            if (is_bid) {
                // Buying base with quote: find smallest lot-multiple >= output_needed, capped by cur_quantity
                let target_lots = round_up_to_lot_size(output_needed, lot_size);
                let matched_base = target_lots.min(cur_quantity);

                if (matched_base > 0) {
                    output_accumulated = output_accumulated + matched_base;
                    let matched_quote = math::mul(matched_base, cur_price);

                    // Calculate quote needed including fees
                    if (pay_with_deep) {
                        input_quantity = input_quantity + matched_quote;
                    } else {
                        // Need extra quote to cover fees (fees taken from input)
                        let quote_with_fee = math::mul(
                            matched_quote,
                            constants::float_scaling() + input_fee_rate,
                        );
                        input_quantity = input_quantity + quote_with_fee;
                    }
                };

                if (matched_base == 0) break;
            } else {
                // Selling base for quote: find smallest lot-multiple of base that yields >= output_needed quote
                let base_for_quote = math::div_round_up(output_needed, cur_price);
                let target_lots = round_up_to_lot_size(base_for_quote, lot_size);
                let matched_base = target_lots.min(cur_quantity);

                if (matched_base > 0) {
                    traded_base = traded_base + matched_base;

                    let matched_quote = math::mul(matched_base, cur_price);
                    output_accumulated = output_accumulated + matched_quote;

                    // Calculate base needed including fees
                    if (pay_with_deep) {
                        input_quantity = input_quantity + matched_base;
                    } else {
                        // Need extra base to cover fees (fees taken from input)
                        let base_with_fee = math::mul(
                            matched_base,
                            constants::float_scaling() + input_fee_rate,
                        );
                        input_quantity = input_quantity + base_with_fee;
                    }
                };

                if (matched_base == 0) break;
            }
        };

        (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
        else book_side.prev_slice(ref, offset);
        current_fills = current_fills + 1;
    };

    // Calculate deep fee if paying with DEEP
    let deep_fee = if (!pay_with_deep) {
        0
    } else {
        let fee_quantity = if (is_bid) {
            deep_price.fee_quantity(
                output_accumulated,
                input_quantity,
                true, // is_bid
            )
        } else {
            deep_price.fee_quantity(
                input_quantity,
                output_accumulated,
                false, // is_ask
            )
        };
        math::mul(taker_fee, fee_quantity.deep())
    };

    // Check if we accumulated enough and meets min_size
    let sufficient = if (is_bid) {
        output_accumulated >= target_base_quantity && output_accumulated >= self.min_size
    } else {
        output_accumulated >= target_quote_quantity && traded_base >= self.min_size
    };

    if (!sufficient) {
        (0, 0, 0) // Couldn't satisfy the requirement
    } else {
        if (is_bid) {
            (output_accumulated, input_quantity, deep_fee)
        } else {
            (input_quantity, output_accumulated, deep_fee)
        }
    }
}
