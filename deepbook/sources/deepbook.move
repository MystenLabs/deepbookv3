// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::deepbook {
    use sui::{
        balance::Balance,
        coin::Coin,
        sui::SUI,
        clock::Clock,
    };

    use deepbook::{
        state::State,
        pool::{Pool, DEEP},
        account::Account,
    };

    // POOL MANAGEMENT

    /// Public facing function to create a pool.
    public fun create_pool<BaseAsset, QuoteAsset>(
        state: &mut State,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext
    ) {
        state.create_pool<BaseAsset, QuoteAsset>(
            tick_size, lot_size, min_size, creation_fee, ctx
        );
    }

    /// Public facing function to set a pool as stable.
    public fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        state.set_pool_as_stable<BaseAsset, QuoteAsset>(pool, stable, ctx);
    }

    /// Public facing function to add a deep price point into a specific pool.
    public fun add_deep_price_point<BaseAsset, QuoteAsset>(
        state: &mut State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>, // DEEP Price or assertion
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        clock: &Clock,
    ) {
        state.add_deep_price_point<BaseAsset, QuoteAsset>(
            reference_pool, pool, clock
        );
        // Determine frequency this is done
    }

    /// Public facing function to remove a deep price point from a specific pool.
    public fun claim_rebates<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        pool.claim_rebates<BaseAsset, QuoteAsset>(ctx)
    }

    // GOVERNANCE

    /// Public facing function to stake DEEP tokens against a specific pool.
    public fun stake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        amount: Coin<DEEP>,
        ctx: &mut TxContext,
    ) {
        state.stake<BaseAsset, QuoteAsset>(pool, amount, ctx);
    }

    /// Public facing function to unstake DEEP tokens from a specific pool.
    public fun unstake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        state.unstake<BaseAsset, QuoteAsset>(pool, ctx)
    }

    public fun withdraw_settled_funds<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        ctx: &mut TxContext
    ) {
        pool.withdraw_settled_funds(account, ctx);
    }

    /// Public facing function to submit a proposal.
    public fun submit_proposal<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ) {
        state.submit_proposal<BaseAsset, QuoteAsset>(
            pool, maker_fee, taker_fee, stake_required, ctx
        );
    }

    /// Public facing function to vote on a proposal.
    public fun vote<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        proposal_id: u64,
        ctx: &mut TxContext,
    ) {
        state.vote<BaseAsset, QuoteAsset>(pool, proposal_id, ctx);
    }

    // ORDERS

    /// Public facing function to place a limit order.
    public fun place_limit_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64, // Expiration timestamp in ms
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        pool.place_limit_order(
            account,
            client_order_id,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            clock,
            ctx,
        );
    }

    // public fun add_reference_pool()
    // public fun place_market_order()
    // public fun cancel_order()
    // public fun cancel_all()
    // public fun get_open_orders()
    // public fun get_amount_out()
    // public fun get_order_book()
}
