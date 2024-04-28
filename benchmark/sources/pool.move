module benchmark::pool {
    use sui::linked_table::{LinkedTable, Self};
    use sui::table::{Table, Self};
    use sui::event;

    use benchmark::critbit::{CritbitTree, Self};
    use benchmark::big_vector::{BigVector, Self};

    public struct Order has store, drop, copy {
        order_id: u128,
        price: u64,
        quantity: u64,
        owner: address,
    }

    public struct TickLevel has store {
        price: u64,
        open_orders: LinkedTable<u128, Order>
    }

    public struct Pool has key, store {
        id: UID,
        bids_critbit: CritbitTree<TickLevel>,
        asks_critbit: CritbitTree<TickLevel>,
        bids_bigvec: BigVector<Order>,
        asks_bigvec: BigVector<Order>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
        user_open_orders: Table<address, LinkedTable<u128, u128>>,
    }

    fun init(ctx: &mut TxContext) {
        let pool = Pool {
            id: object::new(ctx),
            bids_critbit: critbit::new(ctx),
            asks_critbit: critbit::new(ctx),
            bids_bigvec: big_vector::empty(10000, 1000, ctx),
            asks_bigvec: big_vector::empty(10000, 1000, ctx),
            next_bid_order_id: 0,
            next_ask_order_id: 1000000,
            user_open_orders: table::new(ctx),
        };

        transfer::share_object(pool);
    }

    public fun place_limit_order_critbit(
        pool: &mut Pool,
        price: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): u128 {
        let owner = ctx.sender();
        let order_id: u128;
        let open_orders: &mut CritbitTree<TickLevel>;
        if (is_bid) {
            order_id = pool.next_bid_order_id as u128;
            pool.next_bid_order_id = pool.next_bid_order_id + 1;
            open_orders = &mut pool.bids_critbit;
        } else {
            order_id = pool.next_ask_order_id as u128;
            pool.next_ask_order_id = pool.next_ask_order_id + 1;
            open_orders = &mut pool.asks_critbit;
        };

        let order = Order {
            order_id: order_id,
            price: price,
            quantity: quantity,
            owner: owner,
        };

        let (tick_exists, mut tick_index) = open_orders.find_leaf(price);
        if (!tick_exists) {
            tick_index = open_orders.insert_leaf(
                price,
                TickLevel {
                    price,
                    open_orders: linked_table::new(ctx),
                });
        };

        let tick_level = open_orders.borrow_mut_leaf_by_index(tick_index);
        tick_level.open_orders.push_back(order_id, order);
        event::emit(Order {
            order_id,
            price,
            quantity,
            owner: owner,
        });
        if (!pool.user_open_orders.contains(owner)) {
            pool.user_open_orders.add(owner, linked_table::new(ctx));
        };
        pool.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

        order_id
    }

    public fun cancel_first_ask_critbit(
        self: &mut Pool,
    ) {
        let asks = &mut self.asks_critbit;
        let (_, tick_index) = asks.min_leaf();
        let tick_level = asks.borrow_mut_leaf_by_index(tick_index);
        tick_level.open_orders.pop_front();
    }

    public fun cancel_first_bid_critbit(
        self: &mut Pool,
    ) {
        let bids = &mut self.bids_critbit;
        let (_, tick_index) = bids.max_leaf();
        let tick_level = bids.borrow_mut_leaf_by_index(tick_index);
        tick_level.open_orders.pop_back();
    }

    // fun destroy_empty_level(level: TickLevel) {
    //     let TickLevel {
    //         price: _,
    //         open_orders: orders,
    //     } = level;

    //     orders.destroy_empty();
    // }

    public fun place_limit_order_bigvec(
        self: &mut Pool,
        price: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): u128 {
        let owner = ctx.sender();
        let order_id;
        let open_orders: &mut BigVector<Order>;
        if (is_bid) {
            order_id = encode_order_id(price, self.next_bid_order_id);
            self.next_bid_order_id = self.next_bid_order_id - 1;
            open_orders = &mut self.bids_bigvec;
        } else {
            order_id = encode_order_id(price, self.next_ask_order_id);
            self.next_ask_order_id = self.next_ask_order_id + 1;
            open_orders = &mut self.asks_bigvec;
        };

        let order = Order {
            order_id: order_id,
            price: price,
            quantity: quantity,
            owner: owner,
        };

        open_orders.insert(order_id, order);

        event::emit(Order {
            order_id,
            price,
            quantity,
            owner: owner,
        });
        if (!self.user_open_orders.contains(owner)) {
            self.user_open_orders.add(owner, linked_table::new(ctx));
        };
        self.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

        order_id
    }

    public fun cancel_first_ask_bigvec(
        self: &mut Pool,
    ) {
        let (ref, offset) = self.asks_bigvec.slice_following(0);
        let ask = self.asks_bigvec.borrow_mut_ref_offset(ref, offset);
        self.asks_bigvec.remove(ask.order_id);
    }

    public fun cancel_first_bid_bigvec(
        self: &mut Pool,
    ) {
        let max_order_id = 1 << 128 - 1;
        let (ref, offset) = self.bids_bigvec.slice_before(max_order_id);
        let bid = self.bids_bigvec.borrow_mut_ref_offset(ref, offset);
        self.bids_bigvec.remove(bid.order_id);
    }

    fun encode_order_id(
        price: u64,
        order_id: u64
    ): u128 {
        ((price as u128) << 64) + (order_id as u128)
    }
}
