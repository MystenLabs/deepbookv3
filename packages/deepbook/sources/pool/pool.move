// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::pool {
    use sui::{
        balance::{Self,Balance},
        vec_set::VecSet,
        coin::{Coin, TreasuryCap},
        clock::Clock,
        sui::SUI,
        event,
    };

    use std::{
        type_name::{Self, TypeName},
    };

    use deepbook::{
        order::{Self, OrderInfo, Order},
        deep_price::{Self, DeepPrice},
        big_vector::{Self, BigVector},
        account::{Self, Account, TradeProof},
        state_manager::{Self, StateManager, TradeParams},
        utils,
        math,
    };

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EInvalidPriceRange: u64 = 6;
    const EInvalidTicks: u64 = 7;
    const EInvalidAmountIn: u64 = 8;
    const EEmptyOrderbook: u64 = 9;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct
    // Assuming 10k orders per second in a pool, would take over 50 million years to overflow
    const START_BID_ORDER_ID: u64 = (1u128 << 64 - 1) as u64;
    const START_ASK_ORDER_ID: u64 = 1;
    const MIN_ASK_ORDER_ID: u128 = 1 << 127;
    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;
    const MAX_U64: u64 = (1u128 << 64 - 1) as u64;

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

    // <<<<<<<<<<<<<<<<<<<<<<<< Structs <<<<<<<<<<<<<<<<<<<<<<<<

    /// Temporary to represent DEEP token, remove after we have the open-sourced the DEEP token contract
    public struct DEEP has store {}

    /// Pool holds everything related to the pool. next_bid_order_id increments for each bid order,
    /// next_ask_order_id decrements for each ask order. All funds for live orders and settled funds
    /// are held in base_balance, quote_balance, and deep_balance.
    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
        id: UID,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        bids: BigVector<Order>,
        asks: BigVector<Order>,
        next_bid_order_id: u64,
        next_ask_order_id: u64,
        deep_config: DeepPrice,

        base_balance: Balance<BaseAsset>,
        quote_balance: Balance<QuoteAsset>,
        deep_balance: Balance<DEEP>,

        state_manager: StateManager,
    }

    public struct PoolKey has copy, drop, store {
        base: TypeName,
        quote: TypeName,
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Package Functions <<<<<<<<<<<<<<<<<<<<<<<<

    /// Place a limit order to the order book.
    /// 1. Transfer any settled funds from the pool to the account.
    /// 2. Match the order against the order book if possible.
    /// 3. Transfer balances for the executed quantity as well as the remaining quantity.
    /// 4. Assert for any order restrictions.
    /// 5. If there is remaining quantity, inject the order into the order book.
    public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        self.state_manager.update(ctx.epoch());

        self.transfer_settled_amounts(account, proof, ctx);

        let order_id = utils::encode_order_id(is_bid, price, self.get_order_id(is_bid));
        let fee_is_deep = self.deep_config.verified();
        let owner = account.owner();
        let pool_id = self.id.to_inner();
        let mut order_info =
            order::initial_order(pool_id, order_id, client_order_id, order_type, price, quantity, fee_is_deep, is_bid, owner, expire_timestamp);
        order_info.validate_inputs(self.tick_size, self.min_size, self.lot_size, clock.timestamp_ms());
        self.match_against_book(&mut order_info, clock);

        self.transfer_trade_balances(account, proof, &mut order_info, ctx);

        order_info.assert_post_only();
        order_info.assert_fill_or_kill();
        if (order_info.is_immediate_or_cancel() || order_info.original_quantity() == order_info.executed_quantity()) {
            return order_info
        };

        if (order_info.remaining_quantity() > 0) {
            self.inject_limit_order(&order_info);
        };

        order_info
    }

    /// Given an order, transfer the appropriate balances. Up until this point, any partial fills have been executed
    /// and the remaining quantity is the only quantity left to be injected into the order book.
    /// 1. Transfer the taker balances while applying taker fees.
    /// 2. Transfer the maker balances while applying maker fees.
    /// 3. Update the total fees for the order.
    fun transfer_trade_balances<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_info: &mut OrderInfo,
        ctx: &mut TxContext,
    ) {
        let (mut base_in, mut base_out) = (0, 0);
        let (mut quote_in, mut quote_out) = (0, 0);
        let mut deep_in = 0;
        let (taker_fee, maker_fee) = self.state_manager.fees_for_user(account.owner());
        let executed_quantity = order_info.executed_quantity();
        let remaining_quantity = order_info.remaining_quantity();
        let cumulative_quote_quantity = order_info.cumulative_quote_quantity();

        // Calculate the taker balances. These are derived from executed quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_config.calculate_fees(taker_fee, 0, cumulative_quote_quantity)
        } else {
            self.deep_config.calculate_fees(taker_fee, executed_quantity, 0)
        };
        let mut total_fees = base_fee + quote_fee + deep_fee;
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + cumulative_quote_quantity + quote_fee;
            base_out = base_out + executed_quantity;
        } else {
            base_in = base_in + executed_quantity + base_fee;
            quote_out = quote_out + cumulative_quote_quantity;
        };

        // Calculate the maker balances. These are derived from the remaining quantity.
        let (base_fee, quote_fee, deep_fee) = if (order_info.is_bid()) {
            self.deep_config.calculate_fees(maker_fee, 0, math::mul(remaining_quantity, order_info.price()))
        } else {
            self.deep_config.calculate_fees(maker_fee, remaining_quantity, 0)
        };
        total_fees = total_fees + base_fee + quote_fee + deep_fee;
        deep_in = deep_in + deep_fee;
        if (order_info.is_bid()) {
            quote_in = quote_in + math::mul(remaining_quantity, order_info.price()) + quote_fee;
        } else {
            base_in = base_in + remaining_quantity + base_fee;
        };

        order_info.set_total_fees(total_fees);

        if (base_in > 0) self.deposit_base(account, proof, base_in, ctx);
        if (base_out > 0) self.withdraw_base(account, proof, base_out, ctx);
        if (quote_in > 0) self.deposit_quote(account, proof, quote_in, ctx);
        if (quote_out > 0) self.withdraw_quote(account, proof, quote_out, ctx);
        if (deep_in > 0) self.deposit_deep(account, proof, deep_in, ctx);
    }

    /// Transfer any settled amounts from the pool to the account.
    fun transfer_settled_amounts<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext,
    ) {
        let (base, quote, deep) = self.state_manager.reset_user_settled_amounts(account.owner());
        self.withdraw_base(account, proof, base, ctx);
        self.withdraw_quote(account, proof, quote, ctx);
        self.withdraw_deep(account, proof, deep, ctx);
    }

    /// Matches the given order and quantity against the order book.
    /// If is_bid, it will match against asks, otherwise against bids.
    /// Mutates the order and the maker order as necessary.
    fun match_against_book<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        order_info: &mut OrderInfo,
        clock: &Clock,
    ) {
        let is_bid = order_info.is_bid();
        let book_side = if (is_bid) &mut self.asks else &mut self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();

        let mut fills = vector[];

        while (!ref.is_null()) {
            let maker_order = &mut book_side.borrow_slice_mut(ref)[offset];
            if (!order_info.crosses_price(maker_order)) break;
            fills.push_back(order_info.match_maker(maker_order, clock.timestamp_ms()));

            // Traverse to valid next order if exists, otherwise break from loop.
            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset) else book_side.prev_slice(ref, offset);
        };

        // Iterate over fills and process them.
        let mut i = 0;
        while (i < fills.length()) {
            let (order_id, _, expired, complete) = fills[i].fill_status();
            if (expired || complete) {
                book_side.remove(order_id);
            };
            self.state_manager.process_fill(&fills[i]);
            i = i + 1;
        };
    }

    /// Place a market order. Quantity is in base asset terms. Calls place_limit_order with
    /// a price of MAX_PRICE for bids and MIN_PRICE for asks. Fills or kills the order.
    public(package) fun place_market_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        self.place_limit_order(
            account,
            proof,
            client_order_id,
            order::fill_or_kill(),
            if (is_bid) MAX_PRICE else MIN_PRICE,
            quantity,
            is_bid,
            clock.timestamp_ms(),
            clock,
            ctx,
        )
    }

    /// Swap exact amount without needing an account.
    public(package) fun swap_exact_amount<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        base_in: Coin<BaseAsset>,
        quote_in: Coin<QuoteAsset>,
        deep_in: Coin<DEEP>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
        let mut base_quantity = base_in.value();
        let mut quote_quantity = quote_in.value();
        assert!(base_quantity > 0 || quote_quantity > 0, EInvalidAmountIn);
        assert!(base_quantity > 0 && quote_quantity > 0, EInvalidAmountIn);

        let mut temp_account = account::new(ctx);
        temp_account.deposit(base_in, ctx);
        temp_account.deposit(quote_in, ctx);
        temp_account.deposit(deep_in, ctx);
        let proof = temp_account.generate_proof_as_owner(ctx);

        let is_bid = quote_quantity > 0;
        let (taker_fee, _) = self.state_manager.fees_for_user(temp_account.owner());
        let (base_fee, quote_fee, _) = self.deep_config.calculate_fees(taker_fee, base_quantity, quote_quantity);
        base_quantity = base_quantity - base_fee;
        quote_quantity = quote_quantity - quote_fee;
        if (is_bid) {
            (base_quantity, _) = self.get_amount_out(0, quote_quantity);
        };
        base_quantity = base_quantity - base_quantity % self.lot_size;

        self.place_market_order(&mut temp_account, &proof, 0, base_quantity, is_bid, clock, ctx);
        let base_out = temp_account.withdraw_with_proof(&proof, 0, true, ctx);
        let quote_out = temp_account.withdraw_with_proof(&proof, 0, true, ctx);
        let deep_out = temp_account.withdraw_with_proof(&proof, 0, true, ctx);

        temp_account.delete();

        (base_out, quote_out, deep_out)
    }

    // TODO
    public(package) fun mid_price<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>
    ): u64 {
        let (ask_ref, ask_offset) = self.asks.min_slice();
        let (bid_ref, bid_offset) = self.bids.max_slice();
        assert!(!ask_ref.is_null() && !bid_ref.is_null(), EEmptyOrderbook);
        let ask_order = &self.asks.borrow_slice(ask_ref)[ask_offset];
        let (_, ask_price, _) = utils::decode_order_id(ask_order.book_order_id());
        let bid_order = &self.bids.borrow_slice(bid_ref)[bid_offset];
        let (_, bid_price, _) = utils::decode_order_id(bid_order.book_order_id());

        math::div(ask_price + bid_price, 2)
    }

    /// Given base_amount and quote_amount, calculate the base_amount_out and quote_amount_out.
    /// Will return (base_amount_out, quote_amount_out) if base_amount > 0 or quote_amount > 0.
    public(package) fun get_amount_out<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        base_amount: u64,
        quote_amount: u64,
    ): (u64, u64) {
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

    /// Get the level2 bids or asks between price_low and price_high.
    /// Returns two vectors of u64
    /// The previous is a list of all valid prices
    /// The latter is the corresponding quantity at each level
    public(package) fun get_level2_range<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
        is_bid: bool,
    ): (vector<u64>, vector<u64>) {
        get_level2_range_and_ticks(self, price_low, price_high, MAX_U64, is_bid)
    }

    /// Get the n ticks from the mid price
    /// Returns four vectors of u64.
    /// The first two are the bid prices and quantities.
    /// The latter two are the ask prices and quantities.
    public(package) fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        ticks: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        let (bid_price, bid_quantity) = self.get_level2_range_and_ticks(MIN_PRICE, MAX_PRICE, ticks, true);
        let (ask_price, ask_quantity) = self.get_level2_range_and_ticks(MIN_PRICE, MAX_PRICE, ticks, false);

        (bid_price, bid_quantity, ask_price, ask_quantity)
    }

    /// 1. Remove the order from the order book and from the user's open orders.
    /// 2. Refund the user for the remaining quantity and fees.
    /// 2a. If the order is a bid, refund the quote asset + non deep fee.
    /// 2b. If the order is an ask, refund the base asset + non deep fee.
    /// 3. If the order was placed with deep fees, refund the deep fees.
    public(package) fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_id: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Order {
        let mut order = if (order_is_bid(order_id)) {
            self.bids.remove(order_id)
        } else {
            self.asks.remove(order_id)
        };

        order.set_canceled();
        self.state_manager.remove_user_open_order(account.owner(), order_id);

        let (base_quantity, quote_quantity, deep_quantity) = order.cancel_amounts();
        if (base_quantity > 0) self.withdraw_base(account, proof, base_quantity, ctx);
        if (quote_quantity > 0) self.withdraw_quote(account, proof, quote_quantity, ctx);
        if (deep_quantity > 0) self.withdraw_deep(account, proof, deep_quantity, ctx);

        order.emit_order_canceled<BaseAsset, QuoteAsset>(self.id.to_inner(), clock.timestamp_ms());

        order
    }

    /// Claim the rebates for the user
    public(package) fun claim_rebates<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        self.state_manager.update(ctx.epoch());
        let amount = self.state_manager.reset_user_rebates(account.owner());
        self.withdraw_deep(account, proof, amount, ctx);
    }

    /// Cancel all orders for an account. Withdraw settled funds back into user account.
    public(package) fun cancel_all<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        clock: &Clock,
        ctx: &mut TxContext,
    ): vector<Order>{
        let mut cancelled_orders = vector[];
        let user_open_orders = self.state_manager.user_open_orders(account.owner());

        let orders_vector = user_open_orders.into_keys();
        let len = orders_vector.length();
        let mut i = 0;
        while (i < len) {
            let key = orders_vector[i];
            let cancelled_order = cancel_order(self, account, proof, key, clock, ctx);
            cancelled_orders.push_back(cancelled_order);
            i = i + 1;
        };

        cancelled_orders
    }

    /// Get all open orders for a user.
    public(package) fun user_open_orders<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        user: address,
    ): VecSet<u128> {
        self.state_manager.user_open_orders(user)
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
    ): (PoolKey, PoolKey) {
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
            bids: big_vector::empty(10000, 1000, ctx), // TODO: update base on benchmark
            asks: big_vector::empty(10000, 1000, ctx), // TODO: update base on benchmark
            next_bid_order_id: START_BID_ORDER_ID,
            next_ask_order_id: START_ASK_ORDER_ID,
            deep_config: deep_price::new(),
            tick_size,
            lot_size,
            min_size,
            base_balance: balance::zero(),
            quote_balance: balance::zero(),
            deep_balance: balance::zero(),
            state_manager: state_manager::new(taker_fee, maker_fee, 0, ctx),
        });

        // TODO: reconsider sending the Coin here. User pays gas;
        // TODO: depending on the frequency of the event;
        transfer::public_transfer(creation_fee.into_coin(ctx), TREASURY_ADDRESS);

        let (pool_key, rev_key) = (pool.key(), PoolKey {
            base: type_name::get<QuoteAsset>(),
            quote: type_name::get<BaseAsset>(),
        });

        pool.share();

        (pool_key, rev_key)
    }

    /// Increase a user's stake
    public(package) fun increase_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        amount: u64,
        ctx: &TxContext,
    ): u64 {
        self.state_manager.update(ctx.epoch());

        self.state_manager.increase_user_stake(user, amount)
    }

    /// Removes a user's stake.
    /// Returns the total amount staked before this epoch and the total amount staked during this epoch.
    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): u64 {
        self.state_manager.update(ctx.epoch());

        self.state_manager.remove_user_stake(user)
    }

    public(package) fun set_user_voted_proposal<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        proposal_id: Option<u64>,
        ctx: &TxContext,
    ): Option<u64> {
        self.state_manager.update(ctx.epoch());

        self.state_manager.set_user_voted_proposal(user, proposal_id)
    }

    /// Get the user's (current, next) stake amounts
    public(package) fun get_user_stake<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext,
    ): (u64, u64) {
        self.state_manager.user_stake(user, ctx.epoch())
    }

    /// Add a new price point to the pool.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        base_conversion_rate: u64,
        quote_conversion_rate: u64,
        timestamp: u64,
    ) {
        self.deep_config.add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    /// Update the pool's next pool state.
    /// During an epoch refresh, the current pool state is moved to historical pool state.
    /// The next pool state is moved to current pool state.
    public(package) fun set_next_trade_params<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        fees: Option<TradeParams>,
    ) {
        self.state_manager.set_next_trade_params(fees);
    }

    /// Get the base and quote asset TypeName of pool
    public(package) fun get_base_quote_types<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>
    ): (TypeName, TypeName) {
        (
            type_name::get<BaseAsset>(),
            type_name::get<QuoteAsset>()
        )
    }

    /// Get the pool key
    public(package) fun key<BaseAsset, QuoteAsset>(
        _self: &Pool<BaseAsset, QuoteAsset>
    ): PoolKey {
        PoolKey {
            base: type_name::get<BaseAsset>(),
            quote: type_name::get<QuoteAsset>(),
        }
    }

    #[allow(lint(share_owned))]
    /// Share the Pool.
    public(package) fun share<BaseAsset, QuoteAsset>(self: Pool<BaseAsset, QuoteAsset>) {
        transfer::share_object(self)
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Internal Functions <<<<<<<<<<<<<<<<<<<<<<<<

    /// This will be automatically called if not enough assets in settled_funds for a trade
    /// User cannot manually deposit. Funds are withdrawn from user account and merged into pool balances.
    fun deposit_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let base = user_account.withdraw_with_proof(proof, amount, false, ctx);
        self.base_balance.join(base.into_balance());
    }

    fun deposit_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let quote = user_account.withdraw_with_proof(proof, amount, false, ctx);
        self.quote_balance.join(quote.into_balance());
    }

    fun deposit_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = user_account.withdraw_with_proof(proof, amount, false, ctx);
        self.deep_balance.join(coin.into_balance());
    }

    fun withdraw_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.base_balance.split(amount).into_coin(ctx);
        user_account.deposit_with_proof(proof, coin);
    }

    fun withdraw_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.quote_balance.split(amount).into_coin(ctx);
        user_account.deposit_with_proof(proof, coin);
    }

    fun withdraw_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.deep_balance.split(amount).into_coin(ctx);
        user_account.deposit_with_proof(proof, coin);
    }

    #[allow(unused_function)]
    /// Send fees collected in input tokens to treasury
    fun send_treasury<T>(fee: Coin<T>) {
        transfer::public_transfer(fee, TREASURY_ADDRESS)
    }

    /// Balance accounting happens before this function is called
    fun inject_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        order_info: &OrderInfo,
    ) {
        let order = order_info.to_order();
        if (order_info.is_bid()) {
            self.bids.insert(order_info.order_id(), order);
        } else {
            self.asks.insert(order_info.order_id(), order);
        };

        self.state_manager.add_user_open_order(order_info.owner(), order_info.order_id());
        order_info.emit_order_placed<BaseAsset, QuoteAsset>();
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

    /// Get the n ticks from the best bid or ask, must be within price range
    /// Returns two vectors of u64.
    /// The first is a list of all valid prices.
    /// The latter is the corresponding quantity list.
    /// Price_vec is in descending order for bids and ascending order for asks.
    fun get_level2_range_and_ticks<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
        ticks: u64,
        is_bid: bool,
    ): (vector<u64>, vector<u64>) {
        assert!(price_low <= price_high, EInvalidPriceRange);
        assert!(ticks > 0, EInvalidTicks);

        let mut price_vec = vector[];
        let mut quantity_vec = vector[];

        // convert price_low and price_high to keys for searching
        let key_low = (price_low as u128) << 64;
        let key_high = ((price_high as u128) << 64) + ((1u128 << 64 - 1) as u128);
        let book_side = if (is_bid) &self.bids else &self.asks;
        let (mut ref, mut offset) = if (is_bid) book_side.slice_before(key_high) else book_side.slice_following(key_low);
        let mut ticks_left = ticks;
        let mut cur_price = 0;
        let mut cur_quantity = 0;

        while (!ref.is_null() && ticks_left > 0) {
            let order = &book_side.borrow_slice(ref)[offset];
            let (_, order_price, _) = utils::decode_order_id(order.book_order_id());
            if ((is_bid && order_price >= price_low) || (!is_bid && order_price <= price_high)) break;
            if (cur_price == 0) cur_price = order_price;

            let order_quantity = order.book_quantity();
            if (order_price != cur_price) {
                price_vec.push_back(cur_price);
                quantity_vec.push_back(cur_quantity);
                cur_price = order_price;
                cur_quantity = 0;
            };

            cur_quantity = cur_quantity + order_quantity;
            ticks_left = ticks_left - 1;
            (ref, offset) = if (is_bid) book_side.prev_slice(ref, offset) else book_side.next_slice(ref, offset);
        };

        price_vec.push_back(cur_price);
        quantity_vec.push_back(cur_quantity);

        (price_vec, quantity_vec)
    }

    // Will be replaced by actual deep token package dependency
    #[allow(unused_function)]
    fun correct_supply<B, Q>(self: &mut Pool<B, Q>, tcap: &mut TreasuryCap<DEEP>) {
        let amount = self.state_manager.reset_burn_balance();
        let burnt = self.deep_balance.split(amount);
        tcap.supply_mut().decrease_supply(burnt);
    }

    #[test_only]
    public fun bids<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>
    ): &BigVector<Order> {
        &self.bids
    }

    #[test_only]
    public fun asks<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>
    ): &BigVector<Order> {
        &self.asks
    }
}
