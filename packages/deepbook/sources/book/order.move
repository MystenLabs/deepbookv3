// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    use sui::event;
    use deepbook::{math, utils};
    use deepbook::order_info::OrderInfo;

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
    const EInvalidNewQuantity: u64 = 7;
    const EOrderExpired: u64 = 8;

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

    /// Emitted when a maker order is modified.
    public struct OrderModified<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        owner: address,
        price: u64,
        is_bid: bool,
        new_quantity: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced has copy, store, drop {
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
    public struct Fill has store, drop, copy {
        // ID of the maker order
        order_id: u128,
        // Owner of the maker order
        owner: address,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        complete: bool,
        // Quantity settled in base asset terms for maker
        settled_base: u64,
        // Quantity settled in quote asset terms for maker
        settled_quote: u64,
        // Quantity settled in DEEP for maker
        settled_deep: u64,
    }

    /// OrderInfo is converted to an Order before being injected into the order book.
    /// This is done to save space in the order book. Order contains the minimum
    /// information required to match orders.
    public(package) fun to_order(order_info: &OrderInfo): Order {
        let unpaid_fees = order_info.remaining_quantity() * order_info.maker_fee();
        Order {
            order_id: order_info.order_id(),
            client_order_id: order_info.client_order_id(),
            owner: order_info.owner(),
            quantity: order_info.original_quantity(),
            unpaid_fees,
            fee_is_deep: order_info.fee_is_deep(),
            status: order_info.status(),
            expire_timestamp: order_info.expire_timestamp(),
            self_matching_prevention: order_info.self_matching_prevention(),
        }
    }

    public(package) fun order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun client_order_id(self: &Order): u64 {
        self.client_order_id
    }

    public(package) fun quantity(self: &Order): u64 {
        self.quantity
    }

    public(package) fun unpaid_fees(self: &Order): u64 {
        self.unpaid_fees
    }

    public(package) fun fee_is_deep(self: &Order): bool {
        self.fee_is_deep
    }

    public(package) fun status(self: &Order): u8 {
        self.status
    }

    public(package) fun expire_timestamp(self: &Order): u64 {
        self.expire_timestamp
    }

    public(package) fun self_matching_prevention(self: &Order): bool {
        self.self_matching_prevention
    }

    public(package) fun set_quantity(self: &mut Order, quantity: u64) {
        self.quantity = quantity;
    }

    public(package) fun validate_modification(
        order: &Order,
        quantity: u64,
        new_quantity: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ) {
        assert!(new_quantity > 0 && new_quantity < quantity, EInvalidNewQuantity);
        assert!(new_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(new_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(timestamp < order.expire_timestamp(), EOrderExpired);
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
        (fill.settled_base, fill.settled_quote, fill.settled_deep)
    }

    /// Amounts to settle for a cancelled or modified order. Modifies the order in place.
    /// Returns the base, quote and deep quantities to settle.
    /// Cancel quantity used to calculate the quantity outputs.
    /// Modify_order is a flag to indicate whether the order should be modified.
    public(package) fun cancel_amounts(
        self: &mut Order,
        cancel_quantity: u64,
        modify_order: bool,
    ): (u64, u64, u64) {
        let (is_bid, price, _) = utils::decode_order_id(self.order_id);
        let mut base_quantity = if (is_bid) 0 else cancel_quantity;
        let mut quote_quantity = if (is_bid) math::mul(cancel_quantity, price) else 0;
        let fee_refund = math::div(math::mul(self.unpaid_fees, cancel_quantity), self.quantity);
        let deep_quantity = if (self.fee_is_deep) {
            fee_refund
        } else {
            if (is_bid) quote_quantity = quote_quantity + fee_refund
            else base_quantity = base_quantity + fee_refund;
            0
        };

        if (modify_order) {
            self.quantity = self.quantity - cancel_quantity;
            self.unpaid_fees = self.unpaid_fees - fee_refund;
        };

        (base_quantity, quote_quantity, deep_quantity)
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

    public(package) fun emit_order_modified<BaseAsset, QuoteAsset>(self: &Order, pool_id: ID, timestamp: u64) {
        let (is_bid, price, _) = utils::decode_order_id(self.order_id);
        event::emit(OrderModified<BaseAsset, QuoteAsset> {
            order_id: self.order_id,
            pool_id,
            client_order_id: self.client_order_id,
            owner: self.owner,
            price,
            is_bid,
            new_quantity: self.quantity,
            timestamp,
        });
    }
}
