// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool {
    use sui::{
        balance::{Self,Balance},
        table::{Self, Table},
        coin::{Self, Coin, TreasuryCap},
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
        utils,
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

    /// Temporary to represent DEEP token, remove after we have the open-sourced the DEEP token contract
    public struct DEEP has store {}

    /// For each pool, order id is incremental and unique for each opening order.
    /// Orders that are submitted earlier has lower order ids.
    public struct Order has store, drop {
        // ID of the order within the pool
        order_id: u64,
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

    // TODO: why Pool has `store` ?
    // TODO: consider adding back if necessary
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
    ): u64 {
        // Refresh state as necessary if first order of epoch
        self.refresh(ctx);

        assert!(price > 0, EOrderInvalidPrice);
        assert!(price % self.tick_size == 0, EOrderInvalidPrice);
        // Check quantity is above minimum quantity (in base asset)
        assert!(quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(quantity % self.lot_size == 0, EOrderInvalidLotSize);
        assert!(expire_timestamp > clock.timestamp_ms(), EInvalidExpireTimestamp);

        let maker_fee = self.pool_state.maker_fee();
        let mut fee_quantity;
        let mut place_quantity = quantity;
        // If order fee is paid in DEEP tokens
        if (self.fee_is_deep()) {
            let config = self.deep_config.borrow();
            // quantity is always in terms of base asset
            // TODO: option to use deep_per_quote if base not available
            // TODO: make sure there is mul_down and mul_up for rounding
            let deep_quantity = math::mul(config.deep_per_base(), quantity);
            fee_quantity = math::mul(deep_quantity, maker_fee);
            self.deposit_deep(account, fee_quantity, ctx);
        }
        // If unverified pool, fees paid in base/quote assets
        else {
            fee_quantity = math::mul(quantity, maker_fee); // if q = 100, fee = 0.1, fee_q = 10 (in base assets)
            place_quantity = place_quantity - fee_quantity; // if q = 100, fee_q = 10, place_q = 90 (in base assets)
            if (is_bid) {
                fee_quantity = math::mul(fee_quantity, price); // if price = 5, fee_q = 50 (in quote assets)
                self.deposit_quote(account, fee_quantity, ctx);
            } else {
                self.deposit_base(account, fee_quantity, ctx);
            };
        };

        let user_data = &mut self.users[account.owner()];
        let (available_base_amount, available_quote_amount) = user_data.settle_amounts();

        if (is_bid) {
            // Deposit quote asset if there's not enough in custodian
            // Convert input quantity into quote quantity
            let quote_quantity = math::mul(quantity, price);
            if (available_quote_amount < quantity){
                let difference = quote_quantity - available_quote_amount;
                let quote: Coin<QuoteAsset> = account.withdraw(difference, ctx);
                self.quote_balances.join(quote.into_balance());
                user_data.set_settle_amounts(
                    available_base_amount,
                    0,
                    ctx
                );
            } else {
                user_data.set_settle_amounts(
                    available_base_amount,
                    available_quote_amount - quote_quantity,
                    ctx
                );
            };
        } else {
            // Deposit base asset if there's not enough in custodian
            if (available_base_amount < quantity){
                let difference = quantity - available_base_amount;
                let base = account.withdraw(difference, ctx);
                self.base_balances.join(base.into_balance());
                user_data.set_settle_amounts(
                    0,
                    available_quote_amount,
                    ctx
                );
            } else {
                user_data.set_settle_amounts(
                    available_base_amount - quantity,
                    available_quote_amount,
                    ctx
                );
            };
        };

        let order_id = self.internal_place_limit_order(client_order_id, price, place_quantity, fee_quantity, is_bid, expire_timestamp, ctx);
        event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
            pool_id: self.id.to_inner(),
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
        let order_cancelled = self.internal_cancel_order(order_id, ctx);

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
        })
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
            expire_timestamp,
            self_matching_prevention: 0, // TODO
        };

        if (is_bid){
            // TODO: Place ask order into BigVec

            // Increment order id
            self.next_bid_order_id = self.next_bid_order_id + 1;
        } else {
            // TODO: Place ask order into BigVec

            // Increment order id
            self.next_ask_order_id = self.next_ask_order_id + 1;
        };

        order_id
    }

    /// Cancels an order and returns it
    fun internal_cancel_order<BaseAsset, QuoteAsset>(
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
    // Will be replaced by actual deep token package dependency

    // // Other helpful functions
    // TODO: taker order, send fees directly to treasury
    // public(package) fun modify_order()
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
}
