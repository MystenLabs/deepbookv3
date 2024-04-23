// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool {
    use sui::{
        balance::{Self,Balance},
        table::{Self, Table},
        vec_set::VecSet,
        coin::{Coin, TreasuryCap},
        clock::Clock,
        sui::SUI,
        event,
    };

    use std::{
        ascii::String,
        type_name,
    };

    use deepbook::{
        pool_state::{Self, PoolState, PoolEpochState},
        deep_price::{Self, DeepPrice},
        big_vector::{Self, BigVector},
        account::Account,
        user::User,
        utils::{Self, encode_order_id},
        math,
    };

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EUserNotFound: u64 = 6;
    const EOrderInvalidPrice: u64 = 7;
    const EOrderBelowMinimumSize: u64 = 8;
    const EOrderInvalidLotSize: u64 = 9;
    const EInvalidExpireTimestamp: u64 = 10;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct
    const START_BID_ORDER_ID: u64 = (1u128 << 64 - 1) as u64;
    const START_ASK_ORDER_ID: u64 = 1;
    const MIN_ASK_ORDER_ID: u128 = 1 << 127;
    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;

    // <<<<<<<<<<<<<<<<<<<<<<<< Events <<<<<<<<<<<<<<<<<<<<<<<<
    /// Emitted when a new pool is created
    public struct PoolCreated<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the newly created pool
        pool_id: ID,
        // 10^9 scaling
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        order_id: u128,
        /// ID of the order defined by client
        client_order_id: u64,
        is_bid: bool,
        /// owner ID of the `AccountCap` that placed the order
        owner: address,
        original_quantity: u64,
        base_asset_quantity_placed: u64,
        price: u64,
        expire_timestamp: u64
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        order_id: u128,
        /// ID of the order defined by client
        client_order_id: u64,
        is_bid: bool,
        /// owner ID of the `AccountCap` that canceled the order
        owner: address,
        original_quantity: u64,
        base_asset_quantity_canceled: u64,
        price: u64
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Structs <<<<<<<<<<<<<<<<<<<<<<<<

    /// Temporary to represent DEEP token, remove after we have the open-sourced the DEEP token contract
    public struct DEEP has store {}

    /// For each pool, order id is incremental and unique for each opening order.
    /// Orders that are submitted earlier has lower order ids.
    public struct Order has store, drop {
        // ID of the order within the pool
        order_id: u128,
        // ID of the order defined by client
        client_order_id: u64, // TODO: What does this ID do?
        // Price, only used for limit orders
        price: u64,
        // Quantity (in base asset terms) when the order is placed
        original_quantity: u64,
        // Quantity of the order currently held
        quantity: u64,
        // Quantity of fee (in fee asset terms) when the order is placed
        original_fee_quantity: u64,
        // Quantity of fee currently held
        fee_quantity: u64,
        // Whether or not pool is verified at order placement
        fee_is_deep: bool,
        // Whether the order is a bid or ask
        is_bid: bool,
        // Owner of the order
        owner: address,
        // Expiration timestamp in ms.
        expire_timestamp: u64,
        // reserved field for prevent self_matching
        self_matching_prevention: u8
    }

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
        id: UID,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64, // increments for each bid order
        next_ask_order_id: u64, // increments for each ask order
        deep_config: Option<DeepPrice>,
        users: Table<address, User>,
        // Potentially change to - epoch_data: Table<u64, LinkedTable<address, User>>
        // We can only check 1k dynamic fields in Table for a transaction, cannot verify that all addresses are after epoch x for last_refresh_epoch

        // Where funds will be held while order is live
        base_balances: Balance<BaseAsset>,
        quote_balances: Balance<QuoteAsset>,
        deepbook_balance: Balance<DEEP>,

        // Historical, current, and next PoolData
        pool_state: PoolState,

        // Store burned DEEP tokens
        burnt_balance: Balance<DEEP>,
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Package Functions <<<<<<<<<<<<<<<<<<<<<<<<

    /// Place a limit order to the order book.
    public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        client_order_id: u64,
        price: u64,
        quantity: u64, // in base asset
        is_bid: bool, // true for bid, false for ask
        expire_timestamp: u64, // Expiration timestamp in ms
        clock: &Clock,
        ctx: &mut TxContext,
    ): u128 {
        // Refresh state as necessary if first order of epoch
        self.refresh(ctx);

        assert!(price >= MIN_PRICE && price <= MAX_PRICE, EOrderInvalidPrice);
        assert!(price % self.tick_size == 0, EOrderInvalidPrice);
        assert!(quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(quantity % self.lot_size == 0, EOrderInvalidLotSize);
        assert!(expire_timestamp > clock.timestamp_ms(), EInvalidExpireTimestamp);

        // Calculate total Base, Quote, DEEP to be transferred.
        let maker_fee = self.pool_state.maker_fee();
        let (base_quantity, quote_quantity) = if (is_bid) {
            (0, math::mul(quantity, price))
        } else {
            (quantity, 0)
        };
        let (base_fee, quote_fee, deep_fee) = if (self.fee_is_deep()) {
            let config = self.deep_config.borrow();
            let quote_fee = math::mul(config.deep_per_base(), base_quantity) + 
                math::mul(config.deep_per_quote(), quote_quantity);
            
            (0, 0, quote_fee)
        } else {
            let base_fee = math::mul(base_quantity, maker_fee); // TODO: taker_fee, decimal places
            let quote_fee = math::mul(quote_quantity, maker_fee);
            
            (base_fee, quote_fee, 0)
        };

        // Transfer Base, Quote, Fee to Pool.
        if (base_quantity + base_fee > 0) self.deposit_base(account, base_quantity + base_fee, ctx);
        if (quote_quantity + quote_fee > 0) self.deposit_quote(account, quote_quantity + quote_fee, ctx);
        if (deep_fee > 0) self.deposit_deep(account, deep_fee, ctx);

        let place_quantity = math::max(base_quantity, quote_quantity);
        let fee_quantity = math::max(math::max(base_fee, quote_fee), deep_fee);
        let order_id = self.internal_place_limit_order(client_order_id, price, place_quantity, fee_quantity, is_bid, expire_timestamp, ctx);
        event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
            pool_id: self.id.to_inner(),
            order_id,
            client_order_id,
            is_bid,
            owner: account.owner(),
            original_quantity: quantity,
            base_asset_quantity_placed: quantity,
            price,
            expire_timestamp: 0, // TODO
        });

        order_id
    }

    /// Place a market order to the order book.
    public(package) fun place_market_order<BaseAsset, QuoteAsset>(
        _self: &mut Pool<BaseAsset, QuoteAsset>,
        _account: &mut Account,
        _client_order_id: u64,
        _quantity: u64, // in base asset
        _is_bid: bool, // true for bid, false for ask
        _ctx: &mut TxContext,
    ): u128 {
        // TODO: implement
        0
    }

    /// Given an amount in and direction, calculate amount out
    public(package) fun get_amount_out<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>,
        _amount_in: u64,
        _is_bid: bool,
    ): u64 {
        // TODO: implement
        0
    }

    /// Get the level2 bids between price_low and price_high.
    public(package) fun get_level2_bids<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>,
        _price_low: u64,
        _price_high: u64,
    ): (vector<u64>, vector<u64>) {
        // TODO: implement
        (vector[], vector[])
    }

    /// Get the level2 bids between price_low and price_high.
    public(package) fun get_level2_asks<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>,
        _price_low: u64,
        _price_high: u64,
    ): (vector<u64>, vector<u64>) {
        // TODO: implement
        (vector[], vector[])
    }

    /// Get the n ticks from the mid price
    public(package) fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>,
        _ticks: u64,
    ): (vector<u64>, vector<u64>) {
        // TODO: implement
        (vector[], vector[])
    }

    /// Cancel an order by order_id. Withdraw settled funds back into user account.
    public(package) fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        order_id: u128,
        ctx: &mut TxContext,
    ): Order {
        // Order cancelled and returned
        let order_cancelled = self.internal_cancel_order(order_id);

        // remove order from user's open orders
        let user_data = &mut self.users[account.owner()];
        user_data.remove_open_order(order_id);

        // withdraw main assets back into user account
        if (order_cancelled.is_bid) {
            // deposit quote asset back into user account
            let quote_asset_quantity = math::mul(order_cancelled.quantity, order_cancelled.price);
            self.withdraw_quote(account, quote_asset_quantity, ctx)
        } else {
            // deposit base asset back into user account
            self.withdraw_base(account, order_cancelled.quantity, ctx)
        };

        // withdraw fees into user account
        // if pool is verified at the time of order placement, fees are in deepbook tokens
        if (order_cancelled.fee_is_deep) {
            // withdraw deepbook fees
            self.withdraw_deep(account, order_cancelled.fee_quantity, ctx)
        } else if (order_cancelled.is_bid) {
            // withdraw quote asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw_quote(account, order_cancelled.fee_quantity, ctx)
        } else {
            // withdraw base asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw_base(account, order_cancelled.fee_quantity, ctx)
        };

        // Emit order cancelled event
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id: self.id.to_inner(), // Get inner id from UID
            order_id: order_cancelled.order_id,
            client_order_id: order_cancelled.client_order_id,
            is_bid: order_cancelled.is_bid,
            owner: order_cancelled.owner,
            original_quantity: order_cancelled.original_quantity,
            base_asset_quantity_canceled: order_cancelled.quantity,
            price: order_cancelled.price
        });

        order_cancelled
    }

    /// Claim the rebates for the user
    public(package) fun claim_rebates<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        let user = self.get_user_mut(ctx.sender(), ctx);
        let amount = user.reset_rebates();
        self.deepbook_balance
            .split(amount)
            .into_coin(ctx)
    }

    /// Cancel all orders for an account. Withdraw settled funds back into user account.
    public(package) fun cancel_all<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        ctx: &mut TxContext,
    ): vector<Order>{
        let mut cancelled_orders = vector[];
        let user_open_orders = self.users[ctx.sender()].open_orders();

        let orders_vector = user_open_orders.into_keys();
        let len = orders_vector.length();
        let mut i = 0;
        while (i < len) {
            let key = orders_vector[i];
            let cancelled_order = cancel_order(self, account, key, ctx);
            cancelled_orders.push_back(cancelled_order);
            i = i + 1;
        };

        cancelled_orders
    }

    /// Get all open orders for a user.
    public(package) fun get_open_orders<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        user: address,
    ): VecSet<u128> {
        assert!(self.users.contains(user), EUserNotFound);
        let user_data = &self.users[user];

        user_data.open_orders()
    }

    /// Creates a new pool for trading and returns pool_key, called by state module
    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ): Pool<BaseAsset, QuoteAsset> {
        assert!(creation_fee.value() == POOL_CREATION_FEE, EInvalidFee);
        assert!(tick_size > 0, EInvalidTickSize);
        assert!(lot_size > 0, EInvalidLotSize);
        assert!(min_size > 0, EInvalidMinSize);

        assert!(type_name::get<BaseAsset>() != type_name::get<QuoteAsset>(), ESameBaseAndQuote);

        let pool_uid = object::new(ctx);

        event::emit(PoolCreated<BaseAsset, QuoteAsset> {
            pool_id: pool_uid.to_inner(),
            taker_fee,
            maker_fee,
            tick_size,
            lot_size,
            min_size,
        });

        let pool = (Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            bids: big_vector::empty(10000, 1000, ctx), // TODO: what are these numbers
            asks: big_vector::empty(10000, 1000, ctx), // TODO: ditto
            next_bid_order_id: START_BID_ORDER_ID,
            next_ask_order_id: START_ASK_ORDER_ID,
            users: table::new(ctx),
            deep_config: option::none(),
            tick_size,
            lot_size,
            min_size,
            base_balances: balance::zero(),
            quote_balances: balance::zero(),
            deepbook_balance: balance::zero(),
            burnt_balance: balance::zero(),
            pool_state: pool_state::new(0, taker_fee, maker_fee, ctx),
        });

        // TODO: reconsider sending the Coin here. User pays gas;
        // TODO: depending on the frequency of the event;
        transfer::public_transfer(creation_fee.into_coin(ctx), TREASURY_ADDRESS);

        pool
    }

    /// Increase a user's stake
    public(package) fun increase_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        amount: u64,
        ctx: &TxContext,
    ): u64 {
        self.get_user_mut(user, ctx).increase_stake(amount)
    }

    /// Removes a user's stake
    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): (u64, u64) {
        self.get_user_mut(user, ctx).remove_stake()
    }

    /// Get the user's (current, next) stake amounts
    public(package) fun get_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext,
    ): (u64, u64) {
        if (!self.users.contains(user)) {
            (0, 0)
        } else {
            self.get_user_mut(user, ctx).stake()
        }
    }

    /// Add a new price point to the pool.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        base_conversion_rate: u64,
        quote_conversion_rate: u64,
        timestamp: u64,
    ) {
        if (self.deep_config.is_none()) {
            self.deep_config.fill(deep_price::empty());
        };
        self.deep_config
            .borrow_mut()
            .add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    /// First interaction of each epoch processes this state update
    public(package) fun refresh<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        self.pool_state.refresh(ctx); // change to by account?
    }

    /// Update the pool's next pool state.
    /// During an epoch refresh, the current pool state is moved to historical pool state.
    /// The next pool state is moved to current pool state.
    public(package) fun set_next_epoch<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        next_epoch_pool_state: Option<PoolEpochState>,
    ) {
        self.pool_state.set_next_epoch(next_epoch_pool_state);
    }

    /// Get the base and quote asset of pool, return as ascii strings
    public(package) fun get_base_quote_types<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>
    ): (String, String) {
        (
            type_name::get<BaseAsset>().into_string(),
            type_name::get<QuoteAsset>().into_string()
        )
    }

    /// Get the pool key string base+quote (if base, quote in lexicographic order) otherwise return quote+base
    /// TODO: Why is this needed as a key? Why don't we just use the ID of the pool as an ID?
    public(package) fun key<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>
    ): String {
        let (base, quote) = get_base_quote_types(self);
        if (utils::compare(&base, &quote)) {
            utils::concat_ascii(base, quote)
        } else {
            utils::concat_ascii(quote, base)
        }
    }

    #[allow(lint(share_owned))]
    /// Share the Pool.
    public(package) fun share<BaseAsset, QuoteAsset>(self: Pool<BaseAsset, QuoteAsset>) {
        transfer::share_object(self)
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Internal Functions <<<<<<<<<<<<<<<<<<<<<<<<

    /// Get the user object, refresh the user, and burn the DEEP tokens if necessary
    ///
    /// TODO: remove hidden mutation from access function.
    /// TODO: context should not be an argument here.
    fun get_user_mut<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): &mut User {
        assert!(self.users.contains(user), EUserNotFound);

        let user = &mut self.users[user];
        let burn_amount = user.refresh(ctx);
        if (burn_amount > 0) {
            let burnt_balance = self.deepbook_balance.split(burn_amount);
            self.burnt_balance.join(burnt_balance);
        };

        user
    }

    /// This will be automatically called if not enough assets in settled_funds for a trade
    /// User cannot manually deposit. Funds are withdrawn from user account and merged into pool balances.
    fun deposit_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let base = user_account.withdraw(amount, ctx);
        self.base_balances.join(base.into_balance());
    }

    fun deposit_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let quote = user_account.withdraw(amount, ctx);
        self.quote_balances.join(quote.into_balance());
    }

    fun deposit_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = user_account.withdraw(amount, ctx);
        self.deepbook_balance.join(coin.into_balance());
    }

    fun withdraw_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.base_balances.split(amount).into_coin(ctx);
        user_account.deposit(coin);
    }

    fun withdraw_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.quote_balances.split(amount).into_coin(ctx);
        user_account.deposit(coin);
    }

    fun withdraw_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.deepbook_balance.split(amount).into_coin(ctx);
        user_account.deposit(coin);
    }

    #[allow(unused_function)]
    /// Send fees collected in input tokens to treasury
    fun send_treasury<T>(fee: Coin<T>) {
        transfer::public_transfer(fee, TREASURY_ADDRESS)
    }

    /// Balance accounting happens before this function is called
    fun internal_place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        fee_quantity: u64,
        is_bid: bool, // true for bid, false for ask
        expire_timestamp: u64, // Expiration timestamp in ms
        ctx: &TxContext,
    ): u128 {
        let order_id = encode_order_id(is_bid, price, get_order_id(self, is_bid));

        // Create Order
        let order = Order {
            order_id,
            client_order_id,
            price,
            original_quantity: quantity,
            quantity,
            original_fee_quantity: fee_quantity,
            fee_quantity,
            fee_is_deep: self.fee_is_deep(),
            is_bid,
            owner: ctx.sender(),
            expire_timestamp,
            self_matching_prevention: 0, // TODO
        };

        // Insert order into order books
        if (is_bid){
            self.bids.insert(order_id, order);
        } else {
            self.asks.insert(order_id, order);
        };

        // Add order to user's open orders
        let user_data = &mut self.users[ctx.sender()];
        user_data.add_open_order(order_id);

        order_id
    }

    /// Cancels an order and returns the order details
    fun internal_cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        order_id: u128,
    ): Order {
        if (order_is_bid(order_id)) {
            self.bids.remove(order_id)
        } else {
            self.asks.remove(order_id)
        }
    }

    /// Returns 0 if the order is a bid order, 1 if the order is an ask order
    fun order_is_bid(order_id: u128): bool {
        (order_id < MIN_ASK_ORDER_ID)
    }

    fun get_order_id<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        is_bid: bool
    ): u64 {
        if (is_bid) {
            self.next_bid_order_id = self.next_bid_order_id - 1;
            self.next_bid_order_id
        } else {
            self.next_ask_order_id = self.next_ask_order_id + 1;
            self.next_ask_order_id
        }
    }

    /// Returns if the order fee is paid in deep tokens
    fun fee_is_deep<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>
    ): bool {
        self.deep_config.is_some()
    }

    #[allow(unused_function)]
    fun correct_supply<B, Q>(self: &mut Pool<B, Q>, tcap: &mut TreasuryCap<DEEP>) {
        let amount = self.burnt_balance.value();
        let burnt = self.burnt_balance.split(amount);
        tcap.supply_mut().decrease_supply(burnt);
    }
    // Will be replaced by actual deep token package dependency

    // // Other helpful functions
    // TODO: taker order, send fees directly to treasury
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
}
