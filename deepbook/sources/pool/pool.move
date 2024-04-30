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
        ascii::String,
        type_name,
    };

    use deepbook::{
        deep_price::{Self, DeepPrice},
        big_vector::{Self, BigVector},
        account::{Account, TradeProof},
        state_manager::{Self, StateManager, TradeParams},
        utils::{Self, encode_order_id},
        math,
    };

    // <<<<<<<<<<<<<<<<<<<<<<<< Error Codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EOrderInvalidPrice: u64 = 6;
    const EOrderBelowMinimumSize: u64 = 7;
    const EOrderInvalidLotSize: u64 = 8;
    const EInvalidExpireTimestamp: u64 = 9;

    // <<<<<<<<<<<<<<<<<<<<<<<< Constants <<<<<<<<<<<<<<<<<<<<<<<<
    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct
    // Assuming 10k orders per second in a pool, would take over 50 million years to overflow
    const START_BID_ORDER_ID: u64 = (1u128 << 64 - 1) as u64;
    const START_ASK_ORDER_ID: u64 = 1;
    const MIN_ASK_ORDER_ID: u128 = 1 << 127;
    const MIN_ORDER_ID: u128 = 0;
    const MAX_ORDER_ID: u128 = 1 << 128 - 1;
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

    /// Emitted when a maker order is filled.
    public struct OrderFilled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        /// object ID of the pool the order was placed on
        pool_id: ID,
        /// ID of the order within the pool
        maker_order_id: u128,
        /// ID of the taker order
        taker_order_id: u128,
        /// ID of the order defined by maker client
        maker_client_order_id: u64,
        /// ID of the order defined by taker client
        taker_client_order_id: u64,
        base_quantity: u64,
        quote_quantity: u64,
        price: u64,
        maker_address: address,
        taker_address: address,
        is_bid: bool,
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
        // Potentially change to - epoch_data: Table<u64, LinkedTable<address, User>>
        // We can only check 1k dynamic fields in Table for a transaction, cannot verify that all addresses are after epoch x for last_refresh_epoch

        // Where funds will be held while order is live
        base_balances: Balance<BaseAsset>,
        quote_balances: Balance<QuoteAsset>,
        deepbook_balance: Balance<DEEP>,

        state_manager: StateManager,
    }

    // <<<<<<<<<<<<<<<<<<<<<<<< Package Functions <<<<<<<<<<<<<<<<<<<<<<<<

    /// Place a limit order to the order book. Any settled amounts from previuos maker fills will be transferred to the account.
    /// Returns (filled_base_quantity, filled_quote_quantity, order_id).
    public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        price: u64,
        quantity: u64, // in base asset
        is_bid: bool, // true for bid, false for ask
        expire_timestamp: u64, // Expiration timestamp in ms
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64, u128) {
        self.state_manager.refresh(ctx.epoch());

        assert!(price >= MIN_PRICE && price <= MAX_PRICE, EOrderInvalidPrice);
        assert!(price % self.tick_size == 0, EOrderInvalidPrice);
        assert!(quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(quantity % self.lot_size == 0, EOrderInvalidLotSize);
        assert!(expire_timestamp > clock.timestamp_ms(), EInvalidExpireTimestamp);

        self.transfer_settled_amounts(account, proof, ctx);

        let order_id = encode_order_id(is_bid, price, self.get_order_id(is_bid));
        let (filled_base_quantity, filled_quote_quantity) =
            if (is_bid) {
                self.match_bid(account.owner(), order_id, client_order_id, quantity)
            } else {
                self.match_ask(account.owner(), order_id, client_order_id, quantity)
            };
        self.transfer_taker(account, proof, filled_base_quantity, filled_quote_quantity, is_bid, ctx);

        let remaining_quantity = quantity - filled_base_quantity;
        if (remaining_quantity > 0) {
            let fee_quantity = self.transfer_maker(account, proof, remaining_quantity, price, is_bid, ctx);

            self.inject_limit_order(
                order_id,
                client_order_id,
                price,
                remaining_quantity,
                fee_quantity,
                is_bid,
                expire_timestamp,
                account.owner(),
            );

            event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
                pool_id: self.id.to_inner(),
                order_id,
                client_order_id,
                is_bid,
                owner: account.owner(),
                original_quantity: remaining_quantity,
                price,
                expire_timestamp,
            });
        };

        (filled_base_quantity, filled_quote_quantity, order_id)
    }

    /// Given output from order matching, deposits assets from account into pool and withdraws from pool to account.
    fun transfer_taker<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        filled_base_quantity: u64,
        filled_quote_quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ) {
        let taker_fee = self.state_manager.taker_fee_for_user(account.owner());

        if (is_bid) {
            // Transfer quote out from account to pool, transfer base from pool to account.
            if (self.fee_is_deep()) {
                let deep_quantity = math::mul(taker_fee, math::mul(filled_quote_quantity, self.deep_config.borrow().deep_per_quote()));
                self.deposit_deep(account, proof, deep_quantity, ctx);
                self.deposit_quote(account, proof, filled_quote_quantity, ctx);
            } else {
                let quote_fee = math::mul(taker_fee, filled_quote_quantity);
                self.deposit_quote(account, proof, filled_quote_quantity + quote_fee, ctx);
            };
            self.withdraw_base(account, proof, filled_base_quantity, ctx);
        } else {
            // Transfer base out from account to pool, transfer quote from pool to account.
            if (self.fee_is_deep()) {
                let deep_quantity = math::mul(taker_fee, math::mul(filled_base_quantity, self.deep_config.borrow().deep_per_base()));
                self.deposit_deep(account, proof, deep_quantity, ctx);
                self.deposit_base(account, proof, filled_base_quantity, ctx);
            } else {
                let base_fee = math::mul(taker_fee, filled_base_quantity);
                self.deposit_quote(account, proof, filled_base_quantity + base_fee, ctx);
            };
            self.withdraw_base(account, proof,filled_quote_quantity, ctx);
        };
    }

    /// Given quantity, deposits assets from account into pool to prepare order placement. Returns fee quantity.
    fun transfer_maker<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        quantity: u64,
        price: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): u64 {
        let maker_fee = self.state_manager.maker_fee(ctx.epoch());
        let quote_quantity = math::mul(quantity, price);

        if (is_bid) {
            // Transfer quote out from account to pool, transfer base from pool to account.
            if (self.fee_is_deep()) {
                let deep_quantity = math::mul(maker_fee, math::mul(quote_quantity, self.deep_config.borrow().deep_per_quote()));
                self.deposit_deep(account, proof, deep_quantity, ctx);
                self.deposit_quote(account, proof, quote_quantity, ctx);
                deep_quantity
            } else {
                let quote_fee = math::mul(maker_fee, quote_quantity);
                self.deposit_quote(account, proof, quote_quantity + quote_fee, ctx);
                quote_fee
            }
        } else {
            // Transfer base out from account to pool, transfer quote from pool to account.
            if (self.fee_is_deep()) {
                let deep_quantity = math::mul(maker_fee, math::mul(quantity, self.deep_config.borrow().deep_per_base()));
                self.deposit_deep(account, proof, deep_quantity, ctx);
                self.deposit_base(account, proof, quantity, ctx);
                deep_quantity
            } else {
                let base_fee = math::mul(maker_fee, quantity);
                self.deposit_quote(account, proof, quantity + base_fee, ctx);
                base_fee
            }
        }
    }

    /// Transfer any settled amounts from the pool to the account.
    fun transfer_settled_amounts<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext,
    ) {
        let (base_amount, quote_amount) = self.state_manager.reset_user_settled_amounts(account.owner());
        self.withdraw_base(account, proof, base_amount, ctx);
        self.withdraw_quote(account, proof, quote_amount, ctx);
    }

    /// Matches bid, returns (base_quantity_matched, quote_quantity_matched)
    fun match_bid<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        taker: address,
        order_id: u128,
        client_order_id: u64,
        quantity: u64, // in base asset
    ): (u64, u64) {
        let (mut ref, mut offset) = self.asks.slice_following(MIN_ORDER_ID);
        // This means there are no asks in the book
        if (ref.is_null()) {
            return (0, 0)
        };

        let mut remaining_quantity = quantity;
        let mut net_base_quantity = 0;
        let mut net_quote_quantity = 0;
        let mut matched_orders = vector[];

        // Fetches initial order
        let mut ask = self.asks.borrow_mut_ref_offset(ref, offset);
        while (remaining_quantity > 0 && order_id > ask.order_id) {
            // Match with existing asks
            // We want to buy 1 BTC, if there's 0.5BTC at $50k, we want to buy 0.5BTC at $50k
            let base_matched_quantity = math::min(ask.quantity, remaining_quantity);
            ask.quantity = ask.quantity - base_matched_quantity;
            remaining_quantity = remaining_quantity - base_matched_quantity;
            // fee_subtracted is rounded down (in case of very small fills, this can be 0)
            let fee_subtracted = math::div(math::mul(base_matched_quantity, ask.original_fee_quantity), ask.original_quantity);
            ask.fee_quantity = ask.fee_quantity - fee_subtracted;

            // Rounded up, because maker gets rounding advantage
            let quote_quantity = math::mul_round_up(base_matched_quantity, ask.price);

            // Update maker quote balances
            self.state_manager.add_user_settled_amount(ask.owner, quote_quantity, false);
            // Update volumes
            self.state_manager.increase_maker_volume(ask.owner, base_matched_quantity);

            event::emit(OrderFilled<BaseAsset, QuoteAsset>{
                pool_id: self.id.to_inner(),
                maker_order_id: ask.order_id,
                taker_order_id: order_id,
                maker_client_order_id: ask.client_order_id,
                taker_client_order_id: client_order_id,
                base_quantity: base_matched_quantity,
                quote_quantity,
                price: ask.price,
                maker_address: ask.owner,
                taker_address: taker,
                is_bid: true, // is a bid
            });

            net_base_quantity = net_base_quantity + base_matched_quantity;
            net_quote_quantity = net_quote_quantity + quote_quantity;
            // If ask quantity is 0, remove the order
            if (ask.quantity == 0) {
                // Remove order from user's open orders
                self.state_manager.remove_user_open_order(ask.owner, ask.order_id);
                // Add order id to be removed
                matched_orders.push_back(ask.order_id);
            };

            // Traverse to valid next order if exists, otherwise break from loop
            if (self.asks.valid_next(ref, offset)){
                (ref, offset, ask) = self.asks.borrow_mut_next(ref, offset);
            } else {
                break
            }
        };

        // Iterate over matched_orders and remove from asks
        let mut i = 0;
        while (i < matched_orders.length()) {
            self.asks.remove(matched_orders[i]);
            i = i + 1;
        };

        (net_base_quantity, net_quote_quantity)
    }

    /// Matches ask, returns (base_quantity_matched, quote_quantity_matched)
    fun match_ask<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        taker: address,
        order_id: u128,
        client_order_id: u64,
        quantity: u64, // in base asset
    ): (u64, u64) {
        let (mut ref, mut offset) = self.bids.slice_before(MAX_ORDER_ID);
        // This means there are no bids in the book
        if (ref.is_null()) {
            return (0, 0)
        };

        let mut remaining_quantity = quantity;
        let mut net_base_quantity = 0;
        let mut net_quote_quantity = 0;
        let mut matched_orders = vector[];

        let mut bid = self.bids.borrow_mut_ref_offset(ref, offset);
        while (remaining_quantity > 0 && order_id < bid.order_id ) {
            // Match with existing bids
            // We want to sell 1 BTC, if there's bid 0.5BTC at $50k, we want to sell 0.5BTC at $50k
            let base_matched_quantity = math::min(bid.quantity, remaining_quantity);
            bid.quantity = bid.quantity - base_matched_quantity;
            remaining_quantity = remaining_quantity - base_matched_quantity;
            // fee_subtracted is rounded down (in case of very small fills, this can be 0)
            let fee_subtracted = math::div(math::mul(base_matched_quantity, bid.original_fee_quantity), bid.original_quantity);
            bid.fee_quantity = bid.fee_quantity - fee_subtracted;

            // Rounded up, because maker gets rounding advantage
            let quote_quantity = math::mul_round_up(base_matched_quantity, bid.price);

            // Update maker base balances
            self.state_manager.add_user_settled_amount(bid.owner, base_matched_quantity, true);
            // Update volumes
            self.state_manager.increase_maker_volume(bid.owner, base_matched_quantity);

            event::emit(OrderFilled<BaseAsset, QuoteAsset>{
                pool_id: self.id.to_inner(),
                maker_order_id: bid.order_id,
                taker_order_id: order_id,
                maker_client_order_id: bid.client_order_id,
                taker_client_order_id: client_order_id,
                base_quantity: base_matched_quantity,
                quote_quantity,
                price: bid.price,
                maker_address: bid.owner,
                taker_address: taker,
                is_bid: false, // is an ask
            });

            net_base_quantity = net_base_quantity + base_matched_quantity;
            net_quote_quantity = net_quote_quantity + math::mul(base_matched_quantity, bid.price);
            // If bid quantity is 0, remove the order
            if (bid.quantity == 0) {
                // Remove order from user's open orders
                self.state_manager.remove_user_open_order(bid.owner, bid.order_id);
                // Add order id to be removed
                matched_orders.push_back(bid.order_id);
            };

            // Traverse to valid next order if exists, otherwise break from loop
            if (self.bids.valid_prev(ref, offset)){
                (ref, offset, bid) = self.bids.borrow_prev_mut(ref, offset);
            } else {
                break
            }
        };

        // Iterate over matched_orders and remove from bids
        let mut i = 0;
        while (i < matched_orders.length()) {
            self.bids.remove(matched_orders[i]);
            i = i + 1;
        };

        (net_base_quantity, net_quote_quantity)
    }

    /// Place a market order to the order book.
    /// Will return (settled_base_quantity, settled_quote_quantity)
    public(package) fun place_market_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        quantity: u64, // in base asset
        is_bid: bool, // true for bid, false for ask
        ctx: &mut TxContext,
    ): (u64, u64) {
        // Refresh state as necessary if first order of epoch
        self.state_manager.refresh(ctx.epoch());

        assert!(quantity >= self.min_size, EOrderBelowMinimumSize);
        assert!(quantity % self.lot_size == 0, EOrderInvalidLotSize);

        let price = if (is_bid) {
            MAX_PRICE
        } else {
            MIN_PRICE
        };

        let order_id = encode_order_id(is_bid, price, self.get_order_id(is_bid));
        let (net_base_quantity, net_quote_quantity) =
            if (is_bid) {
                self.match_bid(account.owner(), order_id, client_order_id, quantity)
            } else {
                self.match_ask(account.owner(), order_id, client_order_id, quantity)
            };

        self.transfer_taker(account, proof, net_base_quantity, net_quote_quantity, is_bid, ctx);

        if (is_bid) {
            (net_base_quantity, 0)
        } else {
            (0, net_quote_quantity)
        }
    }

    /// Given an amount in and direction, calculate amount out
    /// Will return (amount_out, amount_in_used)
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
        proof: &TradeProof,
        order_id: u128,
        ctx: &mut TxContext,
    ): Order {
        // Order cancelled and returned
        let order_cancelled = self.internal_cancel_order(order_id);

        // remove order from user's open orders
        self.state_manager.remove_user_open_order(account.owner(), order_id);

        // withdraw main assets back into user account
        if (order_cancelled.is_bid) {
            // deposit quote asset back into user account
            let quote_asset_quantity = math::mul(order_cancelled.quantity, order_cancelled.price);
            self.withdraw_quote(account, proof, quote_asset_quantity, ctx)
        } else {
            // deposit base asset back into user account
            self.withdraw_base(account, proof, order_cancelled.quantity, ctx)
        };

        // withdraw fees into user account
        // if pool is verified at the time of order placement, fees are in deepbook tokens
        if (order_cancelled.fee_is_deep) {
            // withdraw deepbook fees
            self.withdraw_deep(account, proof, order_cancelled.fee_quantity, ctx)
        } else if (order_cancelled.is_bid) {
            // withdraw quote asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw_quote(account, proof, order_cancelled.fee_quantity, ctx)
        } else {
            // withdraw base asset fees
            // can be combined with withdrawal above, separate now for clarity
            self.withdraw_base(account, proof, order_cancelled.fee_quantity, ctx)
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
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        self.state_manager.refresh(ctx.epoch());
        let amount = self.state_manager.reset_user_rebates(account.owner());
        let coin = self.deepbook_balance.split(amount).into_coin(ctx);
        account.deposit_with_proof<DEEP>(proof, coin);
    }

    /// Cancel all orders for an account. Withdraw settled funds back into user account.
    public(package) fun cancel_all<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext,
    ): vector<Order>{
        let mut cancelled_orders = vector[];
        let user_open_orders = self.state_manager.user_open_orders(account.owner());

        let orders_vector = user_open_orders.into_keys();
        let len = orders_vector.length();
        let mut i = 0;
        while (i < len) {
            let key = orders_vector[i];
            let cancelled_order = cancel_order(self, account, proof, key, ctx);
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
            deep_config: option::none(),
            tick_size,
            lot_size,
            min_size,
            base_balances: balance::zero(),
            quote_balances: balance::zero(),
            deepbook_balance: balance::zero(),
            state_manager: state_manager::new(taker_fee, maker_fee, 0, ctx),
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
    ): (u64, u64) {
        self.state_manager.refresh(ctx.epoch());

        self.state_manager.increase_user_stake(user, amount)
    }

    /// Removes a user's stake. 
    /// Returns the total amount staked before this epoch and the total amount staked during this epoch.
    public(package) fun remove_user_stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        ctx: &TxContext
    ): (u64, u64) {
        self.state_manager.refresh(ctx.epoch());
        
        self.state_manager.remove_user_stake(user)
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
        if (self.deep_config.is_none()) {
            self.deep_config.fill(deep_price::empty());
        };
        self.deep_config
            .borrow_mut()
            .add_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    /// Update the pool's next pool state.
    /// During an epoch refresh, the current pool state is moved to historical pool state.
    /// The next pool state is moved to current pool state.
    public(package) fun set_next_fees<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        fees: Option<TradeParams>,
    ) {
        self.state_manager.set_next_fees(fees);
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
        
    /// This will be automatically called if not enough assets in settled_funds for a trade
    /// User cannot manually deposit. Funds are withdrawn from user account and merged into pool balances.
    fun deposit_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let base = user_account.withdraw_with_proof<BaseAsset>(proof, amount, ctx);
        self.base_balances.join(base.into_balance());
    }

    fun deposit_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let quote = user_account.withdraw_with_proof<QuoteAsset>(proof, amount, ctx);
        self.quote_balances.join(quote.into_balance());
    }

    fun deposit_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = user_account.withdraw_with_proof<DEEP>(proof, amount, ctx);
        self.deepbook_balance.join(coin.into_balance());
    }

    fun withdraw_base<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.base_balances.split(amount).into_coin(ctx);
        user_account.deposit_with_proof<BaseAsset>(proof, coin);
    }

    fun withdraw_quote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.quote_balances.split(amount).into_coin(ctx);
        user_account.deposit_with_proof<QuoteAsset>(proof, coin);
    }

    fun withdraw_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        user_account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let coin = self.deepbook_balance.split(amount).into_coin(ctx);
        user_account.deposit_with_proof<DEEP>(proof, coin);
    }

    #[allow(unused_function)]
    /// Send fees collected in input tokens to treasury
    fun send_treasury<T>(fee: Coin<T>) {
        transfer::public_transfer(fee, TREASURY_ADDRESS)
    }

    /// Balance accounting happens before this function is called
    fun inject_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        order_id: u128,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        fee_quantity: u64,
        is_bid: bool, // true for bid, false for ask
        expire_timestamp: u64, // Expiration timestamp in ms
        owner: address,
    ) {

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
            owner,
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
        self.state_manager.add_user_open_order(owner, order_id);
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
        let amount = self.state_manager.reset_burn_balance();
        let burnt = self.deepbook_balance.split(amount);
        tcap.supply_mut().decrease_supply(burnt);
    }
    // Will be replaced by actual deep token package dependency

    // // Other helpful functions
    // TODO: taker order, send fees directly to treasury
    // public(package) fun get_order()
    // public(package) fun get_all_orders()
    // public(package) fun get_book()
}
