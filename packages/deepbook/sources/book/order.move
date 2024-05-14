// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    use sui::event;
    use deepbook::{math, utils};

    const LIVE: u8 = 0;
    const PARTIALLY_FILLED: u8 = 1;
    const FILLED: u8 = 2;
    const CANCELED: u8 = 3;
    const EXPIRED: u8 = 4;

    const EInvalidNewQuantity: u64 = 0;
    const EOrderBelowMinimumSize: u64 = 1;
    const EOrderInvalidLotSize: u64 = 2;
    const EOrderExpired: u64 = 3;

    /// Order struct represents the order in the order book. It is optimized for space.
    public struct Order has store, drop {
        account_id: ID,
        order_id: u128,
        client_order_id: u64,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        account_id: ID,
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        trader: address,
        price: u64,
        is_bid: bool,
        base_asset_quantity_canceled: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is modified.
    public struct OrderModified<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        account_id: ID,
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        trader: address,
        price: u64,
        is_bid: bool,
        new_quantity: u64,
        timestamp: u64,
    }

    /// initialize the order struct.
    public(package) fun new(
        order_id: u128,
        account_id: ID,
        client_order_id: u64,
        quantity: u64,
        unpaid_fees: u64,
        fee_is_deep: bool,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
    ): Order {
        Order {
            order_id,
            account_id,
            client_order_id,
            quantity,
            unpaid_fees,
            fee_is_deep,
            status,
            expire_timestamp,
            self_matching_prevention,
        }
    }

    public(package) fun order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun client_order_id(self: &Order): u64 {
        self.client_order_id
    }

    public(package) fun account_id(self: &Order): ID {
        self.account_id
    }

    public(package) fun price(self: &Order): u64 {
        let (_, price, _) = utils::decode_order_id(self.order_id);

        price
    }

    public(package) fun is_bid(self: &Order): bool {
        let (is_bid, _, _) = utils::decode_order_id(self.order_id);

        is_bid
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

    public(package) fun set_live(self: &mut Order) {
        self.status = LIVE;
    }

    public(package) fun set_fill_status(self: &mut Order) {
        if (self.quantity == 0) {
            self.status = FILLED;
        } else {
            self.status = PARTIALLY_FILLED;
        }
    }

    /// Update the order status to canceled.
    public(package) fun set_canceled(self: &mut Order) {
        self.status = CANCELED;
    }

    /// Update the order status to expired.
    public(package) fun set_expired(self: &mut Order) {
        self.status = EXPIRED;
    }

    public(package) fun modify(
        self: &mut Order,
        new_quantity: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ): (u64, u64, u64) {
        assert!(new_quantity > 0 && new_quantity < self.quantity, EInvalidNewQuantity);
        assert!(new_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(new_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(timestamp < self.expire_timestamp(), EOrderExpired);
        let cancel_amount = self.quantity - new_quantity;
        let (base, quote, deep) = self.cancel_amounts(cancel_amount, true);
        self.quantity = new_quantity;

        (base, quote, deep)
    }

    /// Amounts to settle for a cancelled or modified order. Modifies the order in place.
    /// Returns the base, quote and deep quantities to settle.
    /// Cancel quantity used to calculate the quantity outputs.
    /// Modify_order is a flag to indicate whether the order should be modified.
    /// Unpaid_fees is always in deep asset terms.
    public(package) fun cancel_amounts(
        self: &mut Order,
        cancel_quantity: u64,
        modify_order: bool,
    ): (u64, u64, u64) {
        let is_bid = self.is_bid();
        let price = self.price();
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

    public(package) fun set_unpaid_fees(self: &mut Order, filled_quantity: u64) {
        let unpaid_fees = self.unpaid_fees;
        let maker_fees = math::div(math::mul(filled_quantity, unpaid_fees), self.quantity);
        self.unpaid_fees = unpaid_fees - maker_fees;
    }

    public(package) fun emit_order_canceled<BaseAsset, QuoteAsset>(
        self: &Order,
        pool_id: ID,
        trader: address,
        timestamp: u64
    ) {
        let is_bid = self.is_bid();
        let price = self.price();
        event::emit(OrderCanceled<BaseAsset, QuoteAsset> {
            pool_id,
            order_id: self.order_id,
            account_id: self.account_id,
            client_order_id: self.client_order_id,
            is_bid,
            trader,
            base_asset_quantity_canceled: self.quantity,
            timestamp,
            price,
        });
    }

    public(package) fun emit_order_modified<BaseAsset, QuoteAsset>(
        self: &Order,
        pool_id: ID,
        trader: address,
        timestamp: u64
    ) {
        let is_bid = self.is_bid();
        let price = self.price();
        event::emit(OrderModified<BaseAsset, QuoteAsset> {
            order_id: self.order_id,
            pool_id,
            client_order_id: self.client_order_id,
            account_id: self.account_id,
            trader,
            price,
            is_bid,
            new_quantity: self.quantity,
            timestamp,
        });
    }
}
