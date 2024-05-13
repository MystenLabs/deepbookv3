module deepbook::v3book {
    use deepbook::{
        big_vector::{Self, BigVector},
        utils,
        math,

        v3order::{Order, OrderInfo},
    };

    const START_BID_ORDER_ID: u64 = (1u128 << 64 - 1) as u64;
    const START_ASK_ORDER_ID: u64 = 1;

    const EInvalidAmountIn: u64 = 1;

    public struct Book has store {
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
    }

    public(package) fun empty(tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext): Book {
        Book {
            tick_size,
            lot_size,
            min_size,
            bids: big_vector::empty(10000, 1000, ctx),
            asks: big_vector::empty(10000, 1000, ctx),
            next_bid_order_id: START_BID_ORDER_ID,
            next_ask_order_id: START_ASK_ORDER_ID,
        }
    }

    public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        order_info.validate_inputs(self.tick_size, self.min_size, self.lot_size, timestamp);
        let order_id = utils::encode_order_id(order_info.is_bid(), order_info.price(), self.get_order_id(order_info.is_bid()));
        order_info.set_order_id(order_id);
        self.match_against_book(order_info, timestamp);
        order_info.assert_post_only();
        order_info.assert_fill_or_kill();
        if (order_info.is_immediate_or_cancel() || order_info.original_quantity() == order_info.executed_quantity()) {
            return
        };

        if (order_info.remaining_quantity() > 0) {
            self.inject_limit_order(order_info);
        };
    }

    /// Given base_amount and quote_amount, calculate the base_amount_out and quote_amount_out.
    /// Will return (base_amount_out, quote_amount_out) if base_amount > 0 or quote_amount > 0.
    public(package) fun get_amount_out(self: &Book, base_amount: u64, quote_amount: u64): (u64, u64) {
        assert!((base_amount > 0 || quote_amount > 0) && !(base_amount > 0 && quote_amount > 0), EInvalidAmountIn);
        let is_bid = quote_amount > 0;
        let mut amount_out = 0;
        let mut amount_in_left = if (is_bid) quote_amount else base_amount;

        let book_side = if (is_bid) &self.asks else &self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();

        while (!ref.is_null() && amount_in_left > 0) {
            let order = &book_side.borrow_slice(ref)[offset];
            let (_, cur_price, _) = utils::decode_order_id(order.book_order_id());
            let cur_quantity = order.book_quantity();

            if (is_bid) {
                let matched_amount = math::min(amount_in_left, math::mul(cur_quantity, cur_price));
                amount_out = amount_out + math::div(matched_amount, cur_price);
                amount_in_left = amount_in_left - matched_amount;
            } else {
                let matched_amount = math::min(amount_in_left, cur_quantity);
                amount_out = amount_out + math::mul(matched_amount, cur_price);
                amount_in_left = amount_in_left - matched_amount;
            };

            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset) else book_side.prev_slice(ref, offset);
        };

        if (is_bid) {
            (amount_out, amount_in_left)
        } else {
            (amount_in_left, amount_out)
        }
    }

    public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        if (is_bid) {
            self.bids.remove(order_id)
        } else {
            self.asks.remove(order_id)
        }
    }

    public(package) fun modify_order(self: &mut Book, order_id: u128, new_quantity: u64, timestamp: u64): (u64, u64, u64, &Order) {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let order = if (is_bid) {
            self.bids.borrow_mut(order_id)
        } else {
            self.asks.borrow_mut(order_id)
        };
        let book_quantity = order.book_quantity();

        order.validate_modification(
            book_quantity,
            new_quantity,
            self.min_size,
            self.lot_size,
            timestamp,
        );
        order.set_book_quantity(new_quantity);

        let (base, quote, deep) = order.cancel_amounts(book_quantity - new_quantity, true);

        (base, quote, deep, order)
    }

    public(package) fun lot_size(self: &Book): u64 {
        self.lot_size
    }

    /// Matches the given order and quantity against the order book.
    /// If is_bid, it will match against asks, otherwise against bids.
    /// Mutates the order and the maker order as necessary.
    fun match_against_book(
        self: &mut Book,
        order_info: &mut OrderInfo,
        timestamp: u64,
    ) {
        let is_bid = order_info.is_bid();
        let book_side = if (is_bid) &mut self.asks else &mut self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();

        while (!ref.is_null()) {
            let maker_order = &mut book_side.borrow_slice_mut(ref)[offset];
            if (!order_info.match_maker(maker_order, timestamp)) break;
            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset) else book_side.prev_slice(ref, offset);
            
            let (order_id, _, expired, complete) = order_info.last_fill().fill_status();
            if (expired || complete) {
                book_side.remove(order_id);
            };
        };
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
    fun inject_limit_order(
        self: &mut Book,
        order_info: &OrderInfo,
    ) {
        let order = order_info.to_order();
        if (order_info.is_bid()) {
            self.bids.insert(order_info.order_id(), order);
        } else {
            self.asks.insert(order_info.order_id(), order);
        };
    }
}