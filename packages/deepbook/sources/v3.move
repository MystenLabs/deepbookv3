// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
/// TODO: No authorization checks are implemented;
module deepbook::v3 {
    use sui::{
        coin::{Self, Coin},
        balance::Balance,
        sui::SUI,
        clock::Clock,
        vec_set::VecSet,
    };

    use deepbook::{
        account::{Account, TradeProof},
        v3order,
        v3book::{Self, Book},
    };

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> {
        id: UID,
        book: Book,
        // order: OrderManager<BaseAsset, QuoteAsset>,
        // fee: Fee,
    }

    public fun place_limit_order<BaseAsset, QuoteAsset>(
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
    ) {
        let mut order_info =
            v3order::initial_order(self.id.to_inner(), client_order_id, account.owner(), order_type, price, quantity, is_bid, expire_timestamp);
        self.book.place_order(&mut order_info, clock.timestamp_ms());
    }

}
