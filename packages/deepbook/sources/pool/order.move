// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    use sui::event;
    use deepbook::{
        math,
        utils,
        big_vector::SliceRef,
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
    const EXPIRED: u8 = 4;

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
    /// It is returned to the user at the end of the order lifecycle.
    public struct OrderInfo has store, drop {
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

    /// Order struct represents the order in the order book. It is optimized for space.
    public struct Order has store, drop {
        order_id: u128,
        client_order_id: u64,
        owner: address,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: u8,
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

    /// Fill struct represents the results of a match between two orders.
    /// It is used to update the state.
    public struct Fill has drop {
        // ID of the maker order
        order_id: u128,
        // Owner of the maker order
        owner: address,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        complete: bool,
        // Quantity base asset terms for maker
        base_quantity: u64,
        // Quantity quote asset terms for maker
        quote_quantity: u64,
        // Quantity DEEP for maker
        deep_quantity: u64,
        slice: SliceRef,
        offset: u64,
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
    ): OrderInfo {
        OrderInfo {
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

    public fun pool_id(self: &OrderInfo): ID {
        self.pool_id
    }

    public fun order_id(self: &OrderInfo): u128 {
        self.order_id
    }

    public fun client_order_id(self: &OrderInfo): u64 {
        self.client_order_id
    }

    public fun owner(self: &OrderInfo): address {
        self.owner
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

    public fun cumulative_quote_quantity(self: &OrderInfo): u64 {
        self.cumulative_quote_quantity
    }

    public fun paid_fees(self: &OrderInfo): u64 {
        self.paid_fees
    }

    public fun total_fees(self: &OrderInfo): u64 {
        self.total_fees
    }

    public fun fee_is_deep(self: &OrderInfo): bool {
        self.fee_is_deep
    }

    public fun expire_timestamp(self: &OrderInfo): u64 {
        self.expire_timestamp
    }

    /// TODO: Better naming to avoid conflict?
    public(package) fun book_order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun book_quantity(self: &Order): u64 {
        self.quantity
    }

    /// OrderInfo is converted to an Order before being injected into the order book.
    /// This is done to save space in the order book. Order contains the minimum
    /// information required to match orders.
    public(package) fun to_order(self: &OrderInfo): Order {
        Order {
            order_id: self.order_id,
            client_order_id: self.client_order_id,
            owner: self.owner,
            quantity: self.original_quantity,
            unpaid_fees: self.total_fees - self.paid_fees,
            fee_is_deep: self.fee_is_deep,
            status: self.status,
            expire_timestamp: self.expire_timestamp,
            self_matching_prevention: self.self_matching_prevention,
        }
    }

    /// Validates that the initial order created meets the pool requirements.
    public(package) fun validate_inputs(
        order: &OrderInfo,
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
        assert!(order.order_type > NO_RESTRICTION && order.order_type < MAX_RESTRICTION, EInvalidOrderType);
    }

    /// Returns true if two opposite orders are overlapping in price.
    public(package) fun crosses_price(self: &OrderInfo, order: &Order): bool {
        let (is_bid, price, _) = utils::decode_order_id(order.order_id);

        (
            self.original_quantity - self.executed_quantity > 0 &&
            ((self.is_bid && !is_bid && self.price >= price) ||
            (!self.is_bid && is_bid && self.price <= price))
        )
    }

    /// Returns the remaining quantity for the order.
    public(package) fun remaining_quantity(self: &OrderInfo): u64 {
        self.original_quantity - self.executed_quantity
    }

    /// Asserts that the order doesn't have any fills.
    public(package) fun assert_post_only(self: &OrderInfo) {
        if (self.order_type == POST_ONLY)
            assert!(self.executed_quantity == 0, EPOSTOrderCrossesOrderbook);
    }

    /// Asserts that the order is fully filled.
    public(package) fun assert_fill_or_kill(self: &OrderInfo) {
        if (self.order_type == FILL_OR_KILL)
            assert!(self.executed_quantity == self.original_quantity, EFOKOrderCannotBeFullyFilled);
    }

    /// Checks whether this is an immediate or cancel type of order.
    public(package) fun is_immediate_or_cancel(self: &OrderInfo): bool {
        self.order_type == IMMEDIATE_OR_CANCEL
    }

    /// Returns the fill or kill constant.
    public(package) fun fill_or_kill(): u8 {
        FILL_OR_KILL
    }

    /// Sets the total fees for the order.
    public(package) fun set_total_fees(self: &mut OrderInfo, total_fees: u64) {
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

    /// Returns the result of the fill and the maker id & owner.
    public(package) fun fill_status(fill: &Fill): (u128, address, bool, bool) {
        (fill.order_id, fill.owner, fill.expired, fill.complete)
    }

    /// Returns the settled quantities for the fill.
    public(package) fun settled_quantities(fill: &Fill): (u64, u64, u64) {
        if (fill.expired) {
            return (fill.base_quantity, fill.quote_quantity, fill.deep_quantity)
        };
        let (is_bid, _, _) = utils::decode_order_id(fill.order_id);
        if (is_bid) {
            (fill.base_quantity, 0, fill.deep_quantity)
        } else {
            (0, fill.quote_quantity, fill.deep_quantity)
        }
    }
    
    public(package) fun apply_fill(
        maker: &mut Order,
        fill: &Fill,
    ) {
        if (fill.expired) {
            maker.status = EXPIRED;
            return
        };

        maker.quantity = maker.quantity - fill.base_quantity;
        let maker_fees = math::div(math::mul(fill.base_quantity, maker.unpaid_fees), maker.quantity);
        maker.unpaid_fees = maker.unpaid_fees - maker_fees;
    }

    public(package) fun order_location(
        fill: &Fill,
    ): (SliceRef, u64) {
        (fill.slice, fill.offset)
    }

    /// Matches an OrderInfo with an Order from the book. Returns a Fill.
    /// If the book order is expired, it returns a Fill with the expired flag set to true.
    /// Funds for an expired order are returned to the maker as settled.
    public(package) fun match_maker(
        self: &mut OrderInfo,
        maker: &Order,
        slice: SliceRef,
        offset: u64,
        timestamp: u64,
    ): Fill {
        if (maker.expire_timestamp < timestamp) {
            let (base_quantity, quote_quantity, deep_quantity) = maker.cancel_amounts();
            return Fill {
                order_id: maker.order_id,
                owner: maker.owner,
                expired: true,
                complete: false,
                base_quantity,
                quote_quantity,
                deep_quantity,
                slice,
                offset,
            }
        };

        let (_, price, _) = utils::decode_order_id(maker.order_id);
        let filled_quantity = math::min(self.remaining_quantity(), maker.quantity);
        let quote_quantity = math::mul(filled_quantity, price);
        self.executed_quantity = self.executed_quantity + filled_quantity;
        self.cumulative_quote_quantity = self.cumulative_quote_quantity + quote_quantity;
        self.status = PARTIALLY_FILLED;
        if (self.remaining_quantity() == 0) self.status = FILLED;

        self.emit_order_filled(timestamp);

        Fill {
            order_id: maker.order_id,
            owner: maker.owner,
            expired: false,
            complete: maker.quantity == 0,
            base_quantity: filled_quantity,
            quote_quantity,
            deep_quantity: 0,
            slice,
            offset,
        }
    }

    /// Amounts to settle for a canceled order.
    public(package) fun cancel_amounts(self: &Order): (u64, u64, u64) {
        let (is_bid, price, _) = utils::decode_order_id(self.order_id);
        let mut base_quantity = if (is_bid) 0 else self.quantity * price;
        let mut quote_quantity = if (is_bid) self.quantity else 0;
        let deep_quantity = if (self.fee_is_deep) {
            self.unpaid_fees
        } else {
            if (is_bid) quote_quantity = quote_quantity + self.unpaid_fees
            else base_quantity = base_quantity + self.unpaid_fees;
            0
        };

        (base_quantity, quote_quantity, deep_quantity)
    }

    fun emit_order_filled(self: &OrderInfo, timestamp: u64) {
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

    public(package) fun emit_order_placed<BaseAsset, QuoteAsset>(self: &OrderInfo) {
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

    public(package) fun emit_order_canceled<BaseAsset, QuoteAsset>(self: &Order, pool_id: ID, timestamp: u64) {
        let (is_bid, price, _) = utils::decode_order_id(self.order_id);
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id,
            order_id: self.order_id,
            client_order_id: self.client_order_id,
            is_bid,
            owner: self.owner,
            base_asset_quantity_canceled: self.quantity,
            timestamp,
            price,
        });
    }
}
