// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order_info {
    use sui::event;
    use deepbook::{
        math,
        utils,
        order::{Self, Order},
        fill::{Self, Fill},
    };

    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;

    // Restrictions on limit orders.
    const NO_RESTRICTION: u8 = 0;
    // Mandates that whatever amount of an order that can be executed in the current transaction, be filled and then the rest of the order canceled.
    const IMMEDIATE_OR_CANCEL: u8 = 1;
    // Mandates that the entire order size be filled in the current transaction. Otherwise, the order is canceled.
    const FILL_OR_KILL: u8 = 2;
    // Mandates that the entire order be passive. Otherwise, cancel the order.
    const POST_ONLY: u8 = 3;
    // Maximum restriction value.
    const MAX_RESTRICTION: u8 = 3;

    const LIVE: u8 = 0;
    const PARTIALLY_FILLED: u8 = 1;
    const FILLED: u8 = 2;
    const CANCELED: u8 = 3;

    const EOrderInvalidPrice: u64 = 0;
    const EOrderBelowMinimumSize: u64 = 1;
    const EOrderInvalidLotSize: u64 = 2;
    const EInvalidExpireTimestamp: u64 = 3;
    const EInvalidOrderType: u64 = 4;
    const EPOSTOrderCrossesOrderbook: u64 = 5;
    const EFOKOrderCannotBeFullyFilled: u64 = 6;

    /// OrderInfo struct represents all order information.
    /// This objects gets created at the beginning of the order lifecycle and
    /// gets updated until it is completed or placed in the book.
    /// It is returned at the end of the order lifecycle.
    public struct OrderInfo has store, drop {
        // ID of the pool
        pool_id: ID,
        // ID of the order within the pool
        order_id: u128,
        // Epoch for this order
        epoch: u64,
        // ID of the account the order uses
        account_id: ID,
        // ID of the order defined by client
        client_order_id: u64,
        // Trader of the order
        trader: address,
        // Order type, NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY
        order_type: u8,
        // Price, only used for limit orders
        price: u64,
        // Whether the order is a buy or a sell
        is_bid: bool,
        // Quantity (in base asset terms) when the order is placed
        original_quantity: u64,
        // DEEP conversion per base asset
        deep_per_base: u64,
        // Expiration timestamp in ms
        expire_timestamp: u64,
        // Quantity executed so far
        executed_quantity: u64,
        // Any partial fills
        fills: vector<Fill>,
        // Status of the order
        status: u8,
        // Reserved field for prevent self_matching
        self_matching_prevention: bool,
    }

    /// Emitted when a maker order is filled.
    public struct OrderFilled has copy, store, drop {
        pool_id: ID,
        maker_order_id: u128,
        taker_order_id: u128,
        maker_client_order_id: u64,
        taker_client_order_id: u64,
        price: u64,
        taker_is_bid: bool,
        base_quantity: u64,
        quote_quantity: u64,
        maker_account_id: ID,
        taker_account_id: ID,
        timestamp: u64,
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        price: u64,
        is_bid: bool,
        base_asset_quantity_canceled: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is modified.
    public struct OrderModified<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        price: u64,
        is_bid: bool,
        new_quantity: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced has copy, store, drop {
        account_id: ID,
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        trader: address,
        price: u64,
        is_bid: bool,
        placed_quantity: u64,
        expire_timestamp: u64,
    }

    public(package) fun new(
        pool_id: ID,
        account_id: ID,
        epoch: u64,
        client_order_id: u64,
        trader: address,
        order_type: u8,
        price: u64,
        quantity: u64,
        deep_per_base: u64,
        is_bid: bool,
        expire_timestamp: u64,
    ): OrderInfo {
        OrderInfo {
            pool_id,
            order_id: 0,
            epoch,
            account_id,
            client_order_id,
            trader,
            order_type,
            price,
            is_bid,
            original_quantity: quantity,
            deep_per_base,
            expire_timestamp,
            executed_quantity: 0,
            fills: vector[],
            status: LIVE,
            self_matching_prevention: false,
        }
    }

    public fun account_id(self: &OrderInfo): ID {
        self.account_id
    }

    public fun pool_id(self: &OrderInfo): ID {
        self.pool_id
    }

    public fun order_id(self: &OrderInfo): u128 {
        self.order_id
    }

    public fun client_order_id(self: &OrderInfo): u64 {
        self.client_order_id
    }

    public fun order_type(self: &OrderInfo): u8 {
        self.order_type
    }

    public fun price(self: &OrderInfo): u64 {
        self.price
    }

    public fun is_bid(self: &OrderInfo): bool{
        self.is_bid
    }

    public fun original_quantity(self: &OrderInfo): u64 {
        self.original_quantity
    }

    public fun executed_quantity(self: &OrderInfo): u64 {
        self.executed_quantity
    }

    public fun deep_per_base(self: &OrderInfo): u64 {
        self.deep_per_base
    }

    public fun status(self: &OrderInfo): u8 {
        self.status
    }

    public fun expire_timestamp(self: &OrderInfo): u64 {
        self.expire_timestamp
    }

    public fun self_matching_prevention(self: &OrderInfo): bool {
        self.self_matching_prevention
    }

    public fun fills(self: &OrderInfo): vector<Fill> {
        self.fills
    }

    public(package) fun last_fill(self: &OrderInfo): &Fill {
        &self.fills[self.fills.length() - 1]
    }

    public(package) fun set_order_id(self: &mut OrderInfo, order_id: u64) {
        let order_id = utils::encode_order_id(self.is_bid, self.price, order_id);
        self.order_id = order_id;
    }

    /// OrderInfo is converted to an Order before being injected into the order book.
    /// This is done to save space in the order book. Order contains the minimum
    /// information required to match orders.
    public(package) fun to_order(
        self: &OrderInfo,
    ): Order {
        order::new(
            self.order_id,
            self.epoch,
            self.account_id,
            self.client_order_id,
            self.remaining_quantity(),
            self.deep_per_base,
            self.status,
            self.expire_timestamp,
            self.self_matching_prevention,
        )
    }

    /// Validates that the initial order created meets the pool requirements.
    public(package) fun validate_inputs(
        order_info: &OrderInfo,
        tick_size: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ) {
        assert!(order_info.price >= MIN_PRICE && order_info.price <= MAX_PRICE, EOrderInvalidPrice);
        assert!(order_info.price % tick_size == 0, EOrderInvalidPrice);
        assert!(order_info.original_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(order_info.original_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(order_info.expire_timestamp >= timestamp, EInvalidExpireTimestamp);
        assert!(order_info.order_type >= NO_RESTRICTION && order_info.order_type <= MAX_RESTRICTION, EInvalidOrderType);
    }

    /// Returns the remaining quantity for the order.
    public(package) fun remaining_quantity(self: &OrderInfo): u64 {
        self.original_quantity - self.executed_quantity
    }

    public(package) fun assert_order_type(self: &mut OrderInfo): bool {
        if (self.order_type == POST_ONLY)
            assert!(self.executed_quantity == 0, EPOSTOrderCrossesOrderbook);
        if (self.order_type == FILL_OR_KILL)
            assert!(self.executed_quantity == self.original_quantity, EFOKOrderCannotBeFullyFilled);
        if (self.order_type == IMMEDIATE_OR_CANCEL) {
            self.status = CANCELED;

            return true;
        };
        if (self.remaining_quantity() == 0) return true;

        false
    }

    /// Returns the immediate or cancel constant.
    public(package) fun immediate_or_cancel(): u8 {
        IMMEDIATE_OR_CANCEL
    }

    /// Returns true if two opposite orders are overlapping in price.
    public(package) fun crosses_price(self: &OrderInfo, order: &Order): bool {
        let maker_price = order.price();

        (self.original_quantity - self.executed_quantity > 0 &&
        self.is_bid && self.price >= maker_price ||
        !self.is_bid && self.price <= maker_price)
    }

    /// Matches an OrderInfo with an Order from the book. Returns a Fill.
    /// If the book order is expired, it returns a Fill with the expired flag set to true.
    /// Funds for an expired order are returned to the maker as settled.
    public(package) fun match_maker(
        self: &mut OrderInfo,
        maker: &mut Order,
        timestamp: u64,
    ): bool {
        if (!self.crosses_price(maker)) return false;

        if (!maker.expired(timestamp)) {
            let filled_quantity = math::min(self.remaining_quantity(), maker.available_quantity());
            let quote_quantity = math::mul(filled_quantity, maker.price());
            self.executed_quantity = self.executed_quantity + filled_quantity;
            self.status = PARTIALLY_FILLED;
            if (self.remaining_quantity() == 0) self.status = FILLED;
            self.emit_order_filled(maker, maker.price(), filled_quantity, quote_quantity, timestamp);
        };

        let maker_order_id = maker.order_id();
        let maker_account_id = maker.account_id();
        let available_quantity = maker.available_quantity();
        let maker_deep_per_base = maker.deep_per_base();
        let price = maker.price();
        let maker_epoch = maker.epoch();

        if (maker.expired(timestamp)) {
            self.fills.push_back(fill::new_fill(
                maker_order_id,
                maker_account_id,
                true,
                false,
                available_quantity,
                maker_epoch,
                maker_deep_per_base,
                self.is_bid,
                price,
            ));

            return true
        };

        let filled_quantity = math::min(self.remaining_quantity(), available_quantity);
        maker.fill_quantity(filled_quantity);

        let quote_quantity = math::mul(filled_quantity, price);
        self.executed_quantity = self.executed_quantity + filled_quantity;
        self.status = PARTIALLY_FILLED;
        if (self.remaining_quantity() == 0) self.status = FILLED;

        self.emit_order_filled(
            maker,
            price,
            filled_quantity,
            quote_quantity,
            timestamp
        );

        self.fills.push_back(fill::new_fill(
            maker_order_id,
            maker_account_id,
            false,
            maker.available_quantity() == 0,
            filled_quantity,
            maker_epoch,
            maker_deep_per_base,
            self.is_bid,
            price,
        ));

        true
    }

    public(package) fun emit_order_placed(self: &OrderInfo) {
        event::emit(OrderPlaced {
            account_id: self.account_id,
            pool_id: self.pool_id,
            order_id: self.order_id,
            client_order_id: self.client_order_id,
            is_bid: self.is_bid,
            trader: self.trader,
            placed_quantity: self.remaining_quantity(),
            price: self.price,
            expire_timestamp: self.expire_timestamp,
        });
    }

    fun emit_order_filled(
        self: &OrderInfo,
        maker: &Order,
        price: u64,
        filled_quantity: u64,
        quote_quantity: u64,
        timestamp: u64
    ) {
        event::emit(OrderFilled {
            pool_id: self.pool_id,
            maker_order_id: maker.order_id(),
            taker_order_id: self.order_id,
            maker_client_order_id: maker.client_order_id(),
            taker_client_order_id: self.client_order_id,
            base_quantity: filled_quantity,
            quote_quantity: quote_quantity,
            price,
            maker_account_id: maker.account_id(),
            taker_account_id: self.account_id,
            taker_is_bid: self.is_bid,
            timestamp,
        });
    }
}
