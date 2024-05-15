module benchmark::pool {
    use sui::linked_table::{LinkedTable, Self};
    use sui::table::{Table, Self};

    use benchmark::critbit::{CritbitTree, Self};
    use benchmark::big_vector::{BigVector, Self};

    public struct Order has store, drop, copy {
        account_id: ID,
        order_id: u128,
        client_order_id: u64,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_match_prevention: bool,
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
            next_bid_order_id: 1000000,
            next_ask_order_id: 0,
            user_open_orders: table::new(ctx),
        };

        transfer::share_object(pool);
    }

    fun new_order(
        self: &mut Pool,
        price: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &TxContext,
    ): Order {
        let order_id = if (is_bid) {
            self.next_bid_order_id = self.next_bid_order_id - 1;
            self.next_bid_order_id
        } else {
            self.next_ask_order_id = self.next_ask_order_id + 1;
            self.next_ask_order_id
        };
        
        Order {
            account_id: object::id_from_address(ctx.sender()),
            order_id: encode_order_id(is_bid, price, order_id),
            client_order_id: order_id,
            quantity,
            unpaid_fees: 123456789,
            fee_is_deep: false,
            status: 0,
            expire_timestamp: 123456789,
            self_match_prevention: false,
        }
    }

    fun encode_order_id(
        is_bid: bool,
        price: u64,
        order_id: u64
    ): u128 {
        if (is_bid) {
            ((price as u128) << 64) + (order_id as u128)
        } else {
            (1u128 << 127) + ((price as u128) << 64) + (order_id as u128)
        }
    }

    public fun place_limit_order_critbit(
        self: &mut Pool,
        price: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): u128 {
        let order = self.new_order(price, quantity, is_bid, ctx);
        let order_id = order.order_id;
        let owner = ctx.sender();

        let open_orders: &mut CritbitTree<TickLevel>;
        if (is_bid) {
            open_orders = &mut self.bids_critbit;
        } else {
            open_orders = &mut self.asks_critbit;
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
        if (!self.user_open_orders.contains(owner)) {
            self.user_open_orders.add(owner, linked_table::new(ctx));
        };
        self.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

        order_id
    }

    public fun place_limit_order_bigvec(
        pool: &mut Pool,
        price: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): u128 {
        let order = pool.new_order(price, quantity, is_bid, ctx);
        let order_id = order.order_id;
        let owner = ctx.sender();

        let open_orders: &mut BigVector<Order>;
        if (is_bid) {
            open_orders = &mut pool.bids_bigvec;
        } else {
            open_orders = &mut pool.asks_bigvec;
        };

        open_orders.insert(order_id, order);

        if (!pool.user_open_orders.contains(owner)) {
            pool.user_open_orders.add(owner, linked_table::new(ctx));
        };
        pool.user_open_orders.borrow_mut(owner).push_back(order_id, order_id);

        order_id
    }
}
