// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    use sui::event;
    use deepbook::math;

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
    // Maximum restriction value
    const MAX_RESTRICTION: u8 = 3;

    const LIVE: u8 = 0;
    const PARTIALLY_FILLED: u8 = 1;
    const FILLED: u8 = 2;
    const CANCELED: u8 = 3;
    const EXPIRED: u8 = 4;

    const EOrderInvalidPrice: u64 = 0;
    const EOrderBelowMinimumSize: u64 = 1;
    const EOrderInvalidLotSize: u64 = 2;
    const EInvalidExpireTimestamp: u64 = 3;
    const EInvalidOrderType: u64 = 4;
    const EPOSTOrderCrossesOrderbook: u64 = 5;
    const EFOKOrderCannotBeFullyFilled: u64 = 6;

    /// For each pool, order id is incremental and unique for each opening order.
    /// Orders that are submitted earlier has lower order ids.
    public struct Order has store, drop {
        // ID of the pool
        pool_id: ID,
        // ID of the order within the pool
        order_id: u128,
        // ID of the order defined by client
        client_order_id: u64,
        // Owner of the order
        owner: address,
        // Order type, NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY
        order_type: u8,
        // Price, only used for limit orders
        price: u64,
        // Whether the order is a buy or a sell
        is_bid: bool,
        // Quantity (in base asset terms) when the order is placed
        original_quantity: u64,
        // Quantity executed so far
        executed_quantity: u64,
        // Cumulative quote quantity executed so far
        cumulative_quote_quantity: u64,
        // Fees paid so far
        paid_fees: u64,
        // Total fees for the order
        total_fees: u64,
        // Whether or not pool is verified at order placement
        fee_is_deep: bool,
        // Status of the order
        status: u8,
        // Expiration timestamp in ms
        expire_timestamp: u64,
        // Reserved field for prevent self_matching
        self_matching_prevention: u8
    }

    public(package) fun initial_order(
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        fee_is_deep: bool,
        is_bid: bool,
        owner: address,
        expire_timestamp: u64,
    ): Order {
        Order {
            pool_id,
            order_id,
            client_order_id,
            order_type,
            price,
            original_quantity: quantity,
            executed_quantity: 0,
            cumulative_quote_quantity: 0,
            paid_fees: 0,
            total_fees: 0,
            fee_is_deep,
            is_bid,
            owner,
            status: LIVE,
            expire_timestamp,
            self_matching_prevention: 0, // TODO
        }
    }

    public(package) fun copy_order(order: &Order): Order {
        Order {
            pool_id: order.pool_id,
            order_id: order.order_id,
            client_order_id: order.client_order_id,
            order_type: order.order_type,
            price: order.price,
            original_quantity: order.original_quantity,
            executed_quantity: order.executed_quantity,
            cumulative_quote_quantity: order.cumulative_quote_quantity,
            paid_fees: order.paid_fees,
            total_fees: order.total_fees,
            fee_is_deep: order.fee_is_deep,
            is_bid: order.is_bid,
            owner: order.owner,
            status: order.status,
            expire_timestamp: order.expire_timestamp,
            self_matching_prevention: order.self_matching_prevention,
        }
    }

    // ACCESSORS

    public(package) fun order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun owner(self: &Order): address {
        self.owner
    }

    public(package) fun order_type(self: &Order): u8 {
        self.order_type
    }

    public(package) fun price(self: &Order): u64 {
        self.price
    }

    public(package) fun is_bid(self: &Order): bool{
        self.is_bid
    }

    public(package) fun original_quantity(self: &Order): u64 {
        self.original_quantity
    }

    public(package) fun executed_quantity(self: &Order): u64 {
        self.executed_quantity
    }

    public(package) fun cumulative_quote_quantity(self: &Order): u64 {
        self.cumulative_quote_quantity
    }

    public(package) fun fee_is_deep(self: &Order): bool {
        self.fee_is_deep
    }

    /// Returns true if the order is expired.
    public(package) fun is_expired(self: &Order, timestamp: u64): bool {
        self.expire_timestamp <= timestamp
    }

    /// Returns true if the order is completely filled.
    public(package) fun is_complete(self: &Order): bool {
        self.original_quantity == self.executed_quantity
    }

    /// Returns true if two orders are overlapping and can be matched.
    public(package) fun can_match(self: &Order, other: &Order): bool {
        ((self.is_bid && self.price >= other.price) || (!self.is_bid && self.price <= other.price))
    }

    /// Returns the remaining quantity for the order.
    public(package) fun remaining_quantity(self: &Order): u64 {
        self.original_quantity - self.executed_quantity
    }

    /// Returns the fees to refund for a canceled or expired order.
    public(package) fun fees_to_refund(self: &Order): u64 {
        self.paid_fees - self.total_fees
    }

    /// Asserts that the order doesn't have any fills.
    public(package) fun assert_post_only(self: &Order) {
        if (self.order_type == POST_ONLY) 
            assert!(self.executed_quantity == 0, EPOSTOrderCrossesOrderbook);
    }

    /// Asserts that the order is fully filled.
    public(package) fun assert_fill_or_kill(self: &Order) {
        if (self.order_type == FILL_OR_KILL)
            assert!(self.executed_quantity == self.original_quantity, EFOKOrderCannotBeFullyFilled);
    }

    /// Checks whether this is an immediate or cancel type of order.
    public(package) fun is_immediate_or_cancel(self: &Order): bool {
        self.order_type == IMMEDIATE_OR_CANCEL
    }

    /// Returns the fill or kill constant.
    public(package) fun fill_or_kill(): u8 {
        FILL_OR_KILL
    }

    /// Sets the total fees for the order.
    public(package) fun set_total_fees(self: &mut Order, total_fees: u64) {
        self.total_fees = total_fees;
    }

    /// Update the order status to canceled.
    public(package) fun set_canceled(self: &mut Order) {
        self.status = CANCELED;
    }

    /// Update the order status to expired.
    public(package) fun set_expired(self: &mut Order) {
        self.status = EXPIRED;
    }

    /// Validates that the initial order created meets the pool requirements.
    public(package) fun validate_inputs(
        order: &Order,
        tick_size: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ) {
        assert!(order.price >= MIN_PRICE && order.price <= MAX_PRICE, EOrderInvalidPrice);
        assert!(order.price % tick_size == 0, EOrderInvalidPrice);
        assert!(order.original_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(order.original_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(order.expire_timestamp >= timestamp, EInvalidExpireTimestamp);
        assert!(order.order_type >= NO_RESTRICTION && order.order_type < MAX_RESTRICTION, EInvalidOrderType);
    }

    /// Matches two orders and returns the filled quantity and quote quantity.
    /// Updates the orders to reflect their state after the match.
    public(package) fun match_orders(
        taker: &mut Order,
        maker: &mut Order,
        timestamp: u64,
    ): (u64, u64) {
        let taker_remaining_quantity = taker.original_quantity - taker.executed_quantity;
        let maker_remaining_quantity = maker.original_quantity - maker.executed_quantity;
        let filled_quantity = math::min(taker_remaining_quantity, maker_remaining_quantity);
        let quote_quantity = math::mul(filled_quantity, maker.price);
        taker.update_fill_status();
        maker.update_fill_status();

        taker.executed_quantity = taker.executed_quantity + filled_quantity;
        maker.executed_quantity = maker.executed_quantity + filled_quantity;
        taker.cumulative_quote_quantity = taker.cumulative_quote_quantity + quote_quantity;
        maker.cumulative_quote_quantity = maker.cumulative_quote_quantity + quote_quantity;

        let maker_fees = math::div(math::mul(filled_quantity, maker.total_fees), maker.original_quantity);
        maker.paid_fees = maker.paid_fees + maker_fees;

        taker.emit_order_filled(timestamp);

        (filled_quantity, quote_quantity,)
    }

    /// Updates the order status based on the filled quantity.
    public(package) fun update_fill_status(self: &mut Order) {
        if (self.executed_quantity == self.original_quantity) {
            self.status = FILLED;
        } else if (self.executed_quantity > 0) {
            self.status = PARTIALLY_FILLED;
        }
    }

    fun emit_order_filled(self: &Order, timestamp: u64) {
        event::emit(OrderFilled {
            pool_id: self.pool_id,
            maker_order_id: self.order_id,
            taker_order_id: self.order_id,
            maker_client_order_id: self.client_order_id,
            taker_client_order_id: self.client_order_id,
            base_quantity: self.original_quantity,
            quote_quantity: self.original_quantity * self.price,
            price: self.price,
            maker_address: self.owner,
            taker_address: self.owner,
            is_bid: self.is_bid,
            timestamp,
        });
    }

    public(package) fun emit_order_placed<BaseAsset, QuoteAsset>(self: &Order) {
        event::emit(OrderPlaced<BaseAsset, QuoteAsset> {
            pool_id: self.pool_id,
            order_id: self.order_id,
            client_order_id: self.client_order_id,
            is_bid: self.is_bid,
            owner: self.owner,
            original_quantity: self.original_quantity,
            executed_quantity: self.executed_quantity,
            price: self.price,
            expire_timestamp: self.expire_timestamp,
        });
    }

    public(package) fun emit_order_canceled<BaseAsset, QuoteAsset>(self: &Order, timestamp: u64) {
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id: self.pool_id,
            order_id: self.order_id,
            client_order_id: self.client_order_id,
            is_bid: self.is_bid,
            owner: self.owner,
            original_quantity: self.original_quantity,
            base_asset_quantity_canceled: self.executed_quantity,
            timestamp,
            price: self.price
        });
    }

    /// Emitted when a maker order is filled.
    public struct OrderFilled has copy, store, drop {
        pool_id: ID,
        maker_order_id: u128,
        taker_order_id: u128,
        maker_client_order_id: u64,
        taker_client_order_id: u64,
        price: u64,
        is_bid: bool,
        base_quantity: u64,
        quote_quantity: u64,
        maker_address: address,
        taker_address: address,
        timestamp: u64,
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        owner: address,
        price: u64,
        is_bid: bool,
        original_quantity: u64,
        base_asset_quantity_canceled: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        owner: address,
        price: u64,
        is_bid: bool,
        original_quantity: u64,
        executed_quantity: u64,
        expire_timestamp: u64,
    }
}