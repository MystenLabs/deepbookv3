// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    use sui::event;
    use deepbook::{math, utils};

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
        order_id: u128,
        epoch: u64,
        account_id: ID,
        client_order_id: u64,
        original_quantity: u64,
        available_quantity: u64,
        deep_per_base: u64,
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
        epoch: u64,
        account_id: ID,
        client_order_id: u64,
        quantity: u64,
        deep_per_base: u64,
        status: u8,
        expire_timestamp: u64,
        self_matching_prevention: bool,
    ): Order {
        Order {
            order_id,
            epoch,
            account_id,
            client_order_id,
            original_quantity: quantity,
            available_quantity: quantity,
            deep_per_base,
            status,
            expire_timestamp,
            self_matching_prevention,
        }
    }

    public(package) fun modify(
        self: &mut Order,
        new_quantity: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ) {
        assert!(new_quantity > 0 && new_quantity < self.available_quantity, EInvalidNewQuantity);
        assert!(new_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(new_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(timestamp < self.expire_timestamp, EOrderExpired);

        self.available_quantity = new_quantity;
    }

    /// Amounts to settle for a cancelled or modified order. Modifies the order in place.
    /// Returns the base, quote and deep quantities to settle.
    /// Cancel quantity used to calculate the quantity outputs.
    /// Modify_order is a flag to indicate whether the order should be modified.
    /// Unpaid_fees is always in deep asset terms.
    public(package) fun cancel_amounts(
        self: &Order,
        cancel_quantity: u64,
        maker_fee: u64,
    ): (u64, u64, u64) {
        let deep_quantity = math::mul(cancel_quantity, self.deep_per_base);
        let deep_quantity = math::mul(deep_quantity, maker_fee);

        (0, 0, deep_quantity)
    }

    public(package) fun expired(self: &mut Order, timestamp: u64): bool {
        if (timestamp >= self.expire_timestamp) {
            self.status = EXPIRED;
            true
        } else {
            false
        }
    }

    public(package) fun fill_quantity(self: &mut Order, quantity: u64) {
        self.available_quantity = self.available_quantity - quantity;
        self.status = PARTIALLY_FILLED;
        if (self.available_quantity == 0) {
            self.status = FILLED;
        }
    }

    /// Update the order status to canceled.
    public(package) fun set_canceled(self: &mut Order) {
        self.status = CANCELED;
    }

    public(package) fun order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun epoch(self: &Order): u64 {
        self.epoch
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

    public(package) fun available_quantity(self: &Order): u64 {
        self.available_quantity
    }

    public(package) fun deep_per_base(self: &Order): u64 {
        self.deep_per_base
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
            base_asset_quantity_canceled: self.available_quantity,
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
            new_quantity: self.available_quantity,
            timestamp,
        });
    }
}
