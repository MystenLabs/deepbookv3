// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
/// TODO: No authorization checks are implemented;
module deepbook::deepbook {
    use sui::{
        coin::{Self, Coin},
        balance::Balance,
        sui::SUI,
        clock::Clock,
        vec_set::VecSet,
    };

    use deepbook::{
        state::{Self, State},
        pool::{DEEP, Pool},
        order::{OrderInfo, Order},
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
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        pool.set_stable(stable, ctx.epoch());
    }

    /// Public facing function to add a reference pool.
    public fun whitelist_deep_reference_pool<BaseAsset, QuoteAsset>(
        _cap: &DeepBookAdminCap,
        reference_pool: &mut Pool<BaseAsset, QuoteAsset>,
        whitelist: bool,
    ) {
        reference_pool.whitelist_pool(whitelist);
    }

    /// Public facing function to add a deep price point into a specific pool.
    public fun add_deep_price_point<BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset>(
        target_pool: &mut Pool<DEEPBaseAsset, DEEPQuoteAsset>,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
        clock: &Clock,
    ) {
        target_pool.add_deep_price_point(reference_pool, clock.timestamp_ms());
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
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        pool.stake(account, proof, amount, ctx)
    }

    /// Public facing function to unstake DEEP tokens from a specific pool.
    public fun unstake<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        pool.unstake(account, proof, ctx)
    }

    /// Public facing function to submit a proposal.
    public fun submit_proposal<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &Account,
        proof: &TradeProof,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ) {
        account.validate_proof(proof);

        pool.submit_proposal(account.owner(), maker_fee, taker_fee, stake_required, ctx);
    }

    /// Public facing function to vote on a proposal.
    public fun vote<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &Account,
        proof: &TradeProof,
        proposal_id: u64,
        ctx: &mut TxContext,
    ) {
        account.validate_proof(proof);

        pool.vote(account.owner(), proposal_id, ctx)
    }

    // ORDERS

    /// Public facing function to place a limit order.
    public fun place_limit_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64, // Expiration timestamp in ms
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        pool.place_limit_order(
            account,
            proof,
            client_order_id,
            order_type,
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
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        pool.place_market_order(
            account,
            proof,
            client_order_id,
            quantity,
            is_bid,
            clock,
            ctx,
        )
    }

    /// Public facing function to modify order quantity.
    public fun modify_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_id: u128,
        new_quantity: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        pool.modify_order(
            account,
            proof,
            order_id,
            new_quantity,
            clock,
            ctx,
        )
    }

    /// Public facing function to place a direct base -> quote swap order on an unverified pool.
    public fun swap_exact_base<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        base_in: Coin<BaseAsset>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>) {
        let (base_out, quote_out, deep_out) = pool.swap_exact_amount(
            base_in,
            coin::zero(ctx),
            coin::zero(ctx),
            clock,
            ctx,
        );
        deep_out.destroy_zero();

        (base_out, quote_out)
    }

    /// Public facing function to place a direct quote -> base swap order on an unverified pool.
    public fun swap_exact_quote<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        quote_in: Coin<QuoteAsset>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>) {
        let (base_out, quote_out, deep_out) = pool.swap_exact_amount(
            coin::zero(ctx),
            quote_in,
            coin::zero(ctx),
            clock,
            ctx,
        );
        deep_out.destroy_zero();

        (base_out, quote_out)
    }

    /// Public facing function to place a direct base -> quote swap order on a verified pool.
    public fun swap_exact_base_verified<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        base_in: Coin<BaseAsset>,
        deep_in: Coin<DEEP>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
        let (base_out, quote_out, deep_out) = pool.swap_exact_amount(
            base_in,
            coin::zero(ctx),
            deep_in,
            clock,
            ctx,
        );

        (base_out, quote_out, deep_out)
    }

    /// Public facing function to place a direct quote -> base swap order on a verified pool.
    public fun swap_exact_quote_verified<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        quote_in: Coin<QuoteAsset>,
        deep_in: Coin<DEEP>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
        let (base_out, quote_out, deep_out) = pool.swap_exact_amount(
            coin::zero(ctx),
            quote_in,
            deep_in,
            clock,
            ctx,
        );

        (base_out, quote_out, deep_out)
    }

    /// Public facing function to cancel an order.
    public fun cancel_order<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Order {
        pool.cancel_order(account, proof, client_order_id, clock, ctx)
    }

    /// Public facing function to cancel all orders.
    public fun cancel_all_orders<BaseAsset, QuoteAsset>(
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        clock: &Clock,
        ctx: &mut TxContext,
    ): vector<Order> {
        pool.cancel_all(account, proof, clock, ctx)
    }

    /// Public facing function to get open orders for a user.
    public fun user_open_orders<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        user: address,
    ): VecSet<u128> {
        pool.user_open_orders(user)
    }

    /// Public facing function swap base for quote.
    /// Returns (base_amount_out, quote_amount_out).
    /// Only one of base_amount_in or quote_amount_in should be non-zero.
    public fun get_amount_out<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        base_amount_in: u64,
        quote_amount_in: u64,
    ): (u64, u64) {
        pool.get_amount_out(base_amount_in, quote_amount_in)
    }

    /// Public facing function to get level2 bids or asks.
    public fun get_level2_range<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
        is_bid: bool,
    ): (vector<u64>, vector<u64>) {
        pool.get_level2_range(price_low, price_high, is_bid)
    }

    /// Public facing function to get level2 ticks from mid.
    public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        ticks: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        pool.get_level2_ticks_from_mid(ticks)
    }
}
