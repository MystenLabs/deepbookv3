// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module deepbook::order {
    // === Imports ===
    use sui::event;
    use deepbook::{
        math,
        utils,
        fill::{Self, Fill},
        constants,
    };

    // === Errors ===
    const EInvalidNewQuantity: u64 = 0;
    const EOrderBelowMinimumSize: u64 = 1;
    const EOrderInvalidLotSize: u64 = 2;
    const EOrderExpired: u64 = 3;

    // === Structs ===
    /// Order struct represents the order in the order book. It is optimized for space.
    public struct Order has store, drop {
        balance_manager_id: ID,
        order_id: u128,
        client_order_id: u64,
        quantity: u64,
        filled_quantity: u64,
        deep_per_base: u64,
        epoch: u64,
        status: u8,
        expire_timestamp: u64,
    }

    /// Emitted when a maker order is canceled.
    public struct OrderCanceled<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        balance_manager_id: ID,
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
        balance_manager_id: ID,
        pool_id: ID,
        order_id: u128,
        client_order_id: u64,
        trader: address,
        price: u64,
        is_bid: bool,
        new_quantity: u64,
        timestamp: u64,
    }

    // === Public-Package Functions ===
    /// initialize the order struct.
    public(package) fun new(
        order_id: u128,
        balance_manager_id: ID,
        client_order_id: u64,
        quantity: u64,
        deep_per_base: u64,
        epoch: u64,
        status: u8,
        expire_timestamp: u64,
    ): Order {
        Order {
            order_id,
            balance_manager_id,
            client_order_id,
            quantity,
            filled_quantity: 0,
            deep_per_base,
            epoch,
            status,
            expire_timestamp,
        }
    }

    /// Generate a fill for the resting order given the timestamp,
    /// quantity and whether the order is a bid.
    public(package) fun generate_fill(
        self: &mut Order,
        timestamp: u64,
        quantity: u64,
        is_bid: bool,
        expire_maker: bool,
    ): Fill {
        let base_quantity = math::min(self.quantity, quantity);
        let quote_quantity = math::mul(base_quantity, self.price());

        let order_id = self.order_id;
        let balance_manager_id = self.balance_manager_id;
        let expired = self.expire_timestamp < timestamp || expire_maker;

        if (expired) {
            self.status = constants::expired();
        } else {
            self.filled_quantity = self.filled_quantity + base_quantity;
            self.status = if (self.quantity == self.filled_quantity) constants::filled() else constants::partially_filled();
        };

        fill::new(
            order_id,
            balance_manager_id,
            expired,
            self.quantity == self.filled_quantity,
            base_quantity,
            quote_quantity,
            is_bid,
        )
    }

    public(package) fun modify(
        self: &mut Order,
        new_quantity: u64,
        min_size: u64,
        lot_size: u64,
        timestamp: u64,
    ) {
        let available_quantity = self.quantity - self.filled_quantity;
        let cancel_quantity = available_quantity - new_quantity;
        assert!(cancel_quantity > 0 && new_quantity < available_quantity, EInvalidNewQuantity);
        assert!(new_quantity >= min_size, EOrderBelowMinimumSize);
        assert!(new_quantity % lot_size == 0, EOrderInvalidLotSize);
        assert!(timestamp <= self.expire_timestamp(), EOrderExpired);

        self.filled_quantity = self.filled_quantity + cancel_quantity;
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
            balance_manager_id: self.balance_manager_id,
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
            balance_manager_id: self.balance_manager_id,
            trader,
            price,
            is_bid,
            new_quantity: self.quantity,
            timestamp,
        });
    }

    /// Update the order status to canceled.
    public(package) fun set_canceled(self: &mut Order) {
        self.status = constants::canceled();
    }

    public(package) fun order_id(self: &Order): u128 {
        self.order_id
    }

    public(package) fun client_order_id(self: &Order): u64 {
        self.client_order_id
    }

    public(package) fun balance_manager_id(self: &Order): ID {
        self.balance_manager_id
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

    public(package) fun filled_quantity(self: &Order): u64 {
        self.filled_quantity
    }

    public(package) fun deep_per_base(self: &Order): u64 {
        self.deep_per_base
    }

    public(package) fun epoch(self: &Order): u64 {
        self.epoch
    }

    public(package) fun status(self: &Order): u8 {
        self.status
    }

    public(package) fun expire_timestamp(self: &Order): u64 {
        self.expire_timestamp
    }
}
