module deepbook::v3book {

    use deepbook::{
        big_vector::{Self, BigVector},
        utils,

        v3order::{Order, OrderInfo},
    };

    public struct Book has store {
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
    }

    public(package) fun place_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
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

        order_info.emit_order_placed();
    }
}