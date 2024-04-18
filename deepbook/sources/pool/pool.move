// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool {
    use sui::{
        balance::{Self,Balance},
        table::{Self, Table},
        coin::{Self, Coin, TreasuryCap},
        sui::SUI,
        event,
    };

    use std::{
        ascii::String,
        type_name::{Self, TypeName},
    };

    use deepbook::{
        pool_state::{Self, PoolState, PoolEpochState},
        deep_price::{Self, DeepPrice},
        big_vector::{Self, BigVector},
        account::Account,
        user::User,
        utils::{compare, append},
        math::mul,
    };

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EUserNotFound: u64 = 6;
    const EOrderInvalidTickSize: u64 = 7;
    const EOrderBelowMinimumSize: u64 = 8;
    const EOrderInvalidLotSize: u64 = 9;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct

    // <<<<<<<<<<<<<<<<<<<<<<<< Events <<<<<<<<<<<<<<<<<<<<<<<<
    /// Emitted when a new pool is created
    public struct PoolCreated has copy, store, drop {
        /// object ID of the newly created pool
        pool_id: ID,
        base_asset: TypeName,
        quote_asset: TypeName,
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
        order_id: u64,
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
        order_id: u64,
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

    /// Temporary to represent DEEP token, remove after on-chain dependency possible
    public struct DEEP has store {}

    /// For each pool, order id is incremental and unique for each opening order.
    /// Orders that are submitted earlier has lower order ids.
    public struct Order has store, drop {
        // ID of the order within the pool
        order_id: u64,
        // ID of the order defined by client
        client_order_id: u64,
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

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key, store {
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

    /// Place a maker order
    public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        client_order_id: u64,
        price: u64,
        quantity: u64, // in base asset
        is_bid: bool, // true for bid, false for ask
        ctx: &mut TxContext,
    ): u64 {
        // Refresh state as necessary if first order of epoch
        self.refresh_state(ctx);

        assert!(price % self.tick_size == 0, EOrderInvalidTickSize);
        // Check quantity is above minimum quantity (in base asset)
        assert!(quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(quantity % self.lot_size == 0, EOrderInvalidLotSize);

        let maker_fee = self.pool_state.maker_fee();
        let mut fee_quantity;
        let mut place_quantity = quantity;
        // If order fee is paid in DEEP tokens
        if (self.fee_is_deep()) {
            let config = self.deep_config.borrow();
            // quantity is always in terms of base asset
            // TODO: option to use deep_per_quote if base not available
            // TODO: make sure there is mul_down and mul_up for rounding
            let deep_quantity = mul(config.deep_per_base(), quantity);
            fee_quantity = mul(deep_quantity, maker_fee);
            // Deposit the deepbook fees
            self.deposit(account, fee_quantity, 2, ctx);
        }
        // If unverified pool
        else {
            fee_quantity = mul(quantity, maker_fee); // if q = 100, fee = 0.1, fee_q = 10 (in base assets)
            place_quantity = place_quantity - fee_quantity; // if q = 100, fee_q = 10, place_q = 90 (in base assets)
            if (is_bid) {
                fee_quantity = mul(fee_quantity, price); // if price = 5, fee_q = 50 (in quote assets)
                // deposit quote asset fees
                self.deposit(account, fee_quantity, 1, ctx);
            } else {
                // deposit base asset fees
                self.deposit(account, fee_quantity, 0, ctx);
            };
        };

        let user_data = &mut self.users[account.owner()];
        let (available_base_amount, available_quote_amount) = user_data.settle_amounts();

        if (is_bid) {
            // Deposit quote asset if there's not enough in custodian
            // Convert input quantity into quote quantity
            let quote_quantity = mul(quantity, price);
            if (available_quote_amount < quantity){
                let difference = quote_quantity - available_quote_amount;
                let coin: Coin<QuoteAsset> = account.withdraw(difference, ctx);
                let balance: Balance<QuoteAsset> = coin.into_balance();
                self.quote_balances.join(balance);
                user_data.set_settle_amounts(available_base_amount, 0, ctx);
            } else {
                user_data.set_settle_amounts(available_base_amount, available_quote_amount - quote_quantity, ctx);
            };
        } else {
            // Deposit base asset if there's not enough in custodian
            if (available_base_amount < quantity){
                let difference = quantity - available_base_amount;
                let coin: Coin<BaseAsset> = account.withdraw(difference, ctx);
                let balance: Balance<BaseAsset> = coin.into_balance();
                self.base_balances.join(balance);
                user_data.set_settle_amounts(0, available_quote_amount, ctx);
            } else {
                user_data.set_settle_amounts(available_base_amount - quantity, available_quote_amount, ctx);
            };
        };

        let order_id = self.place_maker_order_int(client_order_id, price, place_quantity, fee_quantity, is_bid, ctx);
        event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
            pool_id: *object::uid_as_inner(&self.id),
            order_id: 0,
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

    #[allow(unused_function, unused_variable)]
    /// cancels an order by id
    public(package) fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        order_id: u64,
        ctx: &mut TxContext,
    ) {
        // TODO: find order in corresponding BigVec using order_id
        // Sample order that is cancelled
        let order_cancelled = self.cancel_order_int(order_id, ctx);

        // withdraw main assets back into user account
        if (order_cancelled.is_bid) {
            // deposit quote asset back into user account
            let quote_asset_quantity = mul(order_cancelled.quantity, order_cancelled.price);
            self.withdraw(account, quote_asset_quantity, 1, ctx)
        } else {
            // deposit base asset back into user account
            self.withdraw(account, order_cancelled.quantity, 0, ctx)
        };

        // withdraw fees into user account
        // if pool is verified at the time of order placement, fees are in deepbook tokens
        if (order_cancelled.fee_is_deep) {
            // withdraw deepbook fees
            self.withdraw(account, order_cancelled.fee_quantity, 2, ctx)
        } else if (order_cancelled.is_bid) {
            // withdraw quote asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw(account, order_cancelled.fee_quantity, 1, ctx)
        } else {
            // withdraw base asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw(account, order_cancelled.fee_quantity, 0, ctx)
        };

        // Emit order cancelled event
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id: *self.id.uid_as_inner(), // Get inner id from UID
            order_id: order_cancelled.order_id,
            client_order_id: order_cancelled.client_order_id,
            is_bid: order_cancelled.is_bid,
            owner: order_cancelled.owner,
            original_quantity: order_cancelled.original_quantity,
            base_asset_quantity_canceled: order_cancelled.quantity,
            price: order_cancelled.price
        })
    }

    /// Claim the rebates for the user
    public(package) fun claim_rebates<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        let user = self.get_user_mut(ctx.sender(), ctx);

        let amount = user.reset_rebates();
        let balance = self.deepbook_balance.split(amount);

        balance.into_coin(ctx)
    }

    /// Withdraw settled funds back into user account
    public(package) fun withdraw_settled_funds<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        ctx: &mut TxContext,
    ) {
        // Get the valid user information
        let user_data = &mut self.users[account.owner()];
        let (base_amount, quote_amount) = user_data.settle_amounts();

        // Take the valid amounts from the pool balances, deposit into user account
        if (base_amount > 0) {
            let base_coin = coin::from_balance(self.base_balances.split(base_amount), ctx);
            account.deposit(base_coin);
        };
        if (quote_amount > 0) {
            let quote_coin = coin::from_balance(self.quote_balances.split(quote_amount), ctx);
            account.deposit(quote_coin);
        };

        // Reset the user's settled amounts
        user_data.set_settle_amounts(0, 0, ctx);
    }

    #[allow(unused_function, unused_variable)]
    /// Allow canceling of all orders for an account
    public(package) fun cancel_all<BaseAsset, QuoteAsset>(
        _self: &mut Pool<BaseAsset, QuoteAsset>,
        _account: &mut Account,
        _ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    #[allow(unused_function, unused_variable)]
    public(package) fun swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
        _self: &mut Pool<BaseAsset, QuoteAsset>,
        _client_order_id: u64,
        _account: &mut Account,
        _quantity: u64,
        _ctx: &mut TxContext,
    ) {
        // TODO: to implement
    }

    #[allow(unused_function, unused_variable)]
    public(package) fun swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
        _self: &mut Pool<BaseAsset, QuoteAsset>,
        _client_order_id: u64,
        _account: &mut Account,
        _quantity: u64,
        _ctx: &mut TxContext,
    ) {
        // TODO: to implement
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
    ): String {
        assert!(creation_fee.value() == POOL_CREATION_FEE, EInvalidFee);
        assert!(tick_size > 0, EInvalidTickSize);
        assert!(lot_size > 0, EInvalidLotSize);
        assert!(min_size > 0, EInvalidMinSize);

        let base_type_name = type_name::get<BaseAsset>();
        let quote_type_name = type_name::get<QuoteAsset>();
        assert!(base_type_name != quote_type_name, ESameBaseAndQuote);

        let pool_uid = object::new(ctx);
        let pool_id = *pool_uid.uid_as_inner();

        event::emit(PoolCreated {
            pool_id,
            base_asset: base_type_name,
            quote_asset: quote_type_name,
            taker_fee,
            maker_fee,
            tick_size,
            lot_size,
            min_size,
        });

        let pool = (Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            bids: big_vector::empty(10000, 1000, ctx),
            asks: big_vector::empty(10000, 1000, ctx),
            next_bid_order_id: 0,
            next_ask_order_id: 0,
            users: table::new(ctx),
            deep_config: option::none(),
            tick_size,
            lot_size,
            min_size,
            base_balances: balance::zero(),
            quote_balances: balance::zero(),
            deepbook_balance: balance::zero(),
            burnt_balance: balance::zero(),
            pool_state: pool_state::new_pool_state(ctx, 0, taker_fee, maker_fee),
        });

        transfer::public_transfer(creation_fee.into_coin(ctx), TREASURY_ADDRESS);
        let pool_key = pool.pool_key();
        transfer::share_object(pool);

        pool_key
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
    public(package) fun refresh_state<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        self.pool_state.refresh_state(ctx);
    }

    /// Update the pool's next pool state.
    /// During an epoch refresh, the current pool state is moved to historical pool state.
    /// The next pool state is moved to current pool state.
    public(package) fun set_next_epoch_pool_state<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        next_epoch_pool_state: Option<PoolEpochState>,
    ) {
        self.pool_state.set_next_epoch_pool_state(next_epoch_pool_state);
    }

    /// Get the base and quote asset of pool, return as ascii strings
    public(package) fun get_base_quote_types<BaseAsset, QuoteAsset>(_self: &Pool<BaseAsset, QuoteAsset>): (String, String) {
        (type_name::get<BaseAsset>().into_string(), type_name::get<QuoteAsset>().into_string())
    }

    /// Get the pool key string base+quote (if base, quote in lexicographic order) otherwise return quote+base
    public(package) fun pool_key<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): String {
        let (base, quote) = get_base_quote_types(self);
        if (compare(&base, &quote)) {
            append(&base, &quote)
        } else {
            append(&quote, &base)
        }
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
    /// User cannot manually deposit
    /// Deposit BaseAsset, QuoteAsset, Deepbook Tokens
    fun deposit<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        coin_type: u64, // 0 for base, 1 for quote, 2 for deep. TODO: use enum
        ctx: &mut TxContext,
    ) {
        // Withdraw from user account and merge into pool balances
        if (coin_type == 0) {
            let coin: Coin<BaseAsset> = user_account.withdraw(amount, ctx);
            self.base_balances.join(coin.into_balance());
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = user_account.withdraw(amount, ctx);
            self.quote_balances.join(coin.into_balance());
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = user_account.withdraw(amount, ctx);
            self.deepbook_balance.join(coin.into_balance());
        }
    }

    /// This will be automatically called when order is cancelled
    /// User cannot manually withdraw
    /// Withdraw BaseAsset, QuoteAsset, Deepbook Tokens
    fun withdraw<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        amount: u64,
        coin_type: u8, // 0 for base, 1 for quote, 2 for deep. TODO: use enum
        ctx: &mut TxContext,
    ) {
        // Withdraw from pool balances and deposit into user account
        if (coin_type == 0) {
            let coin: Coin<BaseAsset> = coin::from_balance(self.base_balances.split(amount), ctx);
            user_account.deposit(coin);
        } else if (coin_type == 1) {
            let coin: Coin<QuoteAsset> = coin::from_balance(self.quote_balances.split(amount), ctx);
            user_account.deposit(coin);
        } else if (coin_type == 2){
            let coin: Coin<DEEP> = coin::from_balance(self.deepbook_balance.split(amount), ctx);
            user_account.deposit(coin);
        };
    }

    #[allow(unused_function)]
    /// Send fees collected in input tokens to treasury
    fun send_treasury<T>(fee: Coin<T>) {
        transfer::public_transfer(fee, TREASURY_ADDRESS)
    }

    /// Balance accounting happens before this function is called
    fun place_maker_order_int<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        fee_quantity: u64,
        is_bid: bool, // true for bid, false for ask
        ctx: &TxContext,
    ): u64 {
        let order_id = self.next_bid_order_id;
        // Create Order
        let _order = Order {
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
            expire_timestamp: 0, // TODO
            self_matching_prevention: 0, // TODO
        };

        if (is_bid){
            // TODO: Place ask order into BigVec

            // Increment order id
            self.next_bid_order_id =  self.next_bid_order_id + 1;
        } else {
            // TODO: Place ask order into BigVec

            // Increment order id
            self.next_ask_order_id =  self.next_ask_order_id + 1;
        };

        order_id
    }

    /// Cancels an order and returns it
    fun cancel_order_int<BaseAsset, QuoteAsset>(
        _self: &mut Pool<BaseAsset, QuoteAsset>,
        _order_id: u64,
        _ctx: &TxContext,
    ): Order {

        // TODO: cancel order using order_id, return canceled order

        Order {
            order_id: 0,
            client_order_id: 1,
            price: 10000,
            original_quantity: 2000,
            quantity: 1000,
            original_fee_quantity: 20,
            fee_quantity: 10,
            fee_is_deep: true,
            is_bid: false,
            owner: @0x0,
            expire_timestamp: 0,
            self_matching_prevention: 0, // TODO
        }
    }

    /// Returns if the order fee is paid in deep tokens
    fun fee_is_deep<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
        self.deep_config.is_some()
    }

    #[allow(unused_function)]
    fun correct_supply<B, Q>(self: &mut Pool<B, Q>, tcap: &mut TreasuryCap<DEEP>) {
        let amount = self.burnt_balance.value();
        let burnt = self.burnt_balance.split(amount);
        tcap.supply_mut().decrease_supply(burnt);
    }

    // // Other helpful functions
    // TODO: taker order, send fees directly to treasury
    // public(package) fun modify_order()
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
}
