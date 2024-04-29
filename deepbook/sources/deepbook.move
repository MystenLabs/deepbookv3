// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
/// TODO: No authorization checks are implemented;
module deepbook::deepbook {
    use sui::{
        balance::Balance,
        sui::SUI,
        clock::Clock,
        vec_set::VecSet,
    };

    use deepbook::{
        state::{Self, State},
        pool::{Order, Pool},
        account::{Account, TradeProof},
    };

    // INIT

    /// DeepBookAdminCap is used to call admin functions.
    public struct DeepBookAdminCap has key, store {
        id: UID,
    }

    /// The one-time-witness used to claim Publisher object.
    public struct DEEPBOOK has drop {}

    fun init(otw: DEEPBOOK, ctx: &mut TxContext) {
        sui::package::claim_and_keep(otw, ctx);
        state::create_and_share(ctx);
        let cap = DeepBookAdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(cap, ctx.sender());
    }

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
        _cap: &DeepBookAdminCap,
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        state.set_pool_as_stable(pool, stable, ctx);
    }

    /// Public facing function to add a reference pool.
    public fun add_reference_pool<BaseAsset, QuoteAsset>(
        _cap: &DeepBookAdminCap,
        state: &mut State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
    ) {
        state.add_reference_pool<BaseAsset, QuoteAsset>(reference_pool);
    }

    /// Public facing function to add a deep price point into a specific pool.
    public fun add_deep_price_point<BaseAsset, QuoteAsset>(
        state: &mut State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>, // DEEP Price or assertion
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        clock: &Clock,
    ) {
        state.add_deep_price_point(
            reference_pool, pool, clock
        );
        // Determine frequency this is done
    }

    /// Public facing function to remove a deep price point from a specific pool.
    public fun claim_rebates<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        pool.claim_rebates(account, proof, ctx)
    }

    // GOVERNANCE

    /// Public facing function to stake DEEP tokens against a specific pool.
    public fun stake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        state.stake(pool, account, proof, amount, ctx)
    }

    /// Public facing function to unstake DEEP tokens from a specific pool.
    public fun unstake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        state.unstake(pool, account, proof, ctx)
    }

    /// Public facing function to submit a proposal.
    public fun submit_proposal<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &Account,
        proof: &TradeProof,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ) {
        state.submit_proposal(
            pool, account, proof, maker_fee, taker_fee, stake_required, ctx
        );
    }

    /// Public facing function to vote on a proposal.
    public fun vote<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &Account,
        proof: &TradeProof,
        proposal_id: u64,
        ctx: &mut TxContext,
    ) {
        account.validate_proof(proof);
        state.vote(pool, account, proof, proposal_id, ctx);
    }

    // ORDERS

    /// TODO: add other return values
    /// Public facing function to place a limit order.
    public fun place_limit_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64, // Expiration timestamp in ms
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64, u128) {
        pool.place_limit_order(
            account,
            proof,
            client_order_id,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            clock,
            ctx,
        )
    }

    /// Public facing function to place a market order.
    public fun place_market_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        quantity: u64,
        is_bid: bool,
        ctx: &mut TxContext,
    ): (u64, u64) {
        pool.place_market_order(
            account,
            proof,
            client_order_id,
            quantity,
            is_bid,
            ctx,
        )
    }

    /// Public facing function to cancel an order.
    public fun cancel_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u128,
        ctx: &mut TxContext,
    ): Order {
        pool.cancel_order(account, proof, client_order_id, ctx)
    }

    /// Public facing function to cancel all orders.
    public fun cancel_all_orders<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext,
    ): vector<Order> {
        pool.cancel_all(account, proof, ctx)
    }

    /// Public facing function to get open orders for a user.
    public fun user_open_orders<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        user: address,
    ): VecSet<u128> {
        pool.user_open_orders(user)
    }

    /// Public facing function to get amount_out given amount_in.
    public fun get_amount_out<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        amount_in: u64,
        is_bid: bool,
    ): u64 {
        pool.get_amount_out(amount_in, is_bid)
    }

    /// Public facing function to get level2 bids.
    public fun get_level2_bids<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
    ): (vector<u64>, vector<u64>) {
        pool.get_level2_bids(price_low, price_high)
    }

    /// Public facing function to get level2 asks.
    public fun get_level2_asks<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
    ): (vector<u64>, vector<u64>) {
        pool.get_level2_asks(price_low, price_high)
    }

    /// Public facing function to get level2 ticks from mid.
    public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        ticks: u64,
    ): (vector<u64>, vector<u64>) {
        pool.get_level2_ticks_from_mid(ticks)
    }
}
