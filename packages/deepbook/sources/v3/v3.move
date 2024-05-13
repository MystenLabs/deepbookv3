// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
/// TODO: No authorization checks are implemented;
module deepbook::v3 {
    use std::{
        type_name,
    };

    use sui::{
        coin::Coin,
        balance::Balance,
        sui::SUI,
        clock::Clock,
        event,
    };

    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    // const EInvalidPriceRange: u64 = 6;
    // const EInvalidTicks: u64 = 7;
    const EInvalidAmountIn: u64 = 8;
    // const EEmptyOrderbook: u64 = 9;
    // const EIneligibleWhitelist: u64 = 10;
    // const EIneligibleTargetPool: u64 = 11;
    // const EIneligibleReferencePool: u64 = 12;

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct

    use deepbook::{
        v3account::{Self, Account, TradeProof},
        v3order,
        v3book::{Self, Book},
        v3state::{Self, State},
        v3vault::{Self, Vault, DEEP},
        v3registry::Registry,
    };

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
        id: UID,
        book: Book,
        state: State,
        vault: Vault<BaseAsset, QuoteAsset>,
    }

    public struct PoolCreated<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
    }

    public fun create_pool<BaseAsset, QuoteAsset>(
        registry: &mut Registry,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        assert!(creation_fee.value() == POOL_CREATION_FEE, EInvalidFee);
        assert!(tick_size > 0, EInvalidTickSize);
        assert!(lot_size > 0, EInvalidLotSize);
        assert!(min_size > 0, EInvalidMinSize);

        assert!(type_name::get<BaseAsset>() != type_name::get<QuoteAsset>(), ESameBaseAndQuote);
        registry.register_pool<BaseAsset, QuoteAsset>();
        registry.register_pool<QuoteAsset, BaseAsset>();

        let pool_uid = object::new(ctx);
        let pool_id = pool_uid.to_inner();

        let pool = Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            book: v3book::empty(tick_size, lot_size, min_size, ctx),
            state: v3state::empty(ctx),
            vault: v3vault::empty(),
        };

        let (taker_fee, maker_fee, _) = pool.state.governance().trade_params();
        event::emit(PoolCreated<BaseAsset, QuoteAsset> {
            pool_id,
            taker_fee,
            maker_fee,
            tick_size,
            lot_size,
            min_size,
        });

        // TODO: reconsider sending the Coin here. User pays gas;
        // TODO: depending on the frequency of the event;
        transfer::public_transfer(creation_fee.into_coin(ctx), TREASURY_ADDRESS);

        transfer::share_object(pool);
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
        ctx: &TxContext,
    ) {
        let (taker_fee, maker_fee, stake_required) = self.state.governance().trade_params();
        let mut order_info =
            v3order::initial_order(self.id.to_inner(), client_order_id, account.owner(), order_type, price, quantity, is_bid, expire_timestamp, maker_fee);
        self.book.create_order(&mut order_info, clock.timestamp_ms());
        self.state.process_create(&order_info, ctx);
        self.vault.settle_order(&order_info, self.state.user_mut(account.owner(), ctx.epoch()), taker_fee, maker_fee, stake_required);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        if (order_info.remaining_quantity() > 0) order_info.emit_order_placed();
    }

    /// Place a market order. Quantity is in base asset terms. Calls place_limit_order with
    /// a price of MAX_PRICE for bids and MIN_PRICE for asks. Fills or kills the order.
    public fun place_market_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        self.place_limit_order(
            account,
            proof,
            client_order_id,
            v3order::fill_or_kill(),
            if (is_bid) MAX_PRICE else MIN_PRICE,
            quantity,
            is_bid,
            clock.timestamp_ms(),
            clock,
            ctx,
        )
    }

    public fun get_amount_out<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        base_amount: u64,
        quote_amount: u64,
    ): (u64, u64) {
        self.book.get_amount_out(base_amount, quote_amount)
    }

    /// Swap exact amount without needing an account.
    public fun swap_exact_amount<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        base_in: Coin<BaseAsset>,
        quote_in: Coin<QuoteAsset>,
        deep_in: Coin<DEEP>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
        let mut base_quantity = base_in.value();
        let mut quote_quantity = quote_in.value();
        assert!(base_quantity > 0 || quote_quantity > 0, EInvalidAmountIn);
        assert!(!(base_quantity > 0 && quote_quantity > 0), EInvalidAmountIn);

        let mut temp_account = v3account::new(ctx);
        temp_account.deposit(base_in, ctx);
        temp_account.deposit(quote_in, ctx);
        temp_account.deposit(deep_in, ctx);
        let proof = temp_account.generate_proof_as_owner(ctx);

        let is_bid = quote_quantity > 0;
        let (taker_fee, _, _) = self.state.governance().trade_params();
        let (base_fee, quote_fee, _) = self.state.deep_price().calculate_fees(taker_fee, base_quantity, quote_quantity);
        base_quantity = base_quantity - base_fee;
        quote_quantity = quote_quantity - quote_fee;
        if (is_bid) {
            (base_quantity, _) = self.get_amount_out(0, quote_quantity);
        };
        base_quantity = base_quantity - base_quantity % self.book.lot_size();

        self.place_market_order(&mut temp_account, &proof, 0, base_quantity, is_bid, clock, ctx);
        let base_out = temp_account.withdraw_with_proof(&proof, 0, true).into_coin(ctx);
        let quote_out = temp_account.withdraw_with_proof(&proof, 0, true).into_coin(ctx);
        let deep_out = temp_account.withdraw_with_proof(&proof, 0, true).into_coin(ctx);

        temp_account.delete();

        (base_out, quote_out, deep_out)
    }

    public fun modify_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_id: u128,
        new_quantity: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let (base, quote, deep, order) = self.book.modify_order(order_id, new_quantity, clock.timestamp_ms());
        self.state.process_modify(account.owner(), base, quote, deep, ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        order.emit_order_modified<BaseAsset, QuoteAsset>(self.id.to_inner(), clock.timestamp_ms());
    }

    public fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_id: u128,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let mut order = self.book.cancel_order(order_id);
        self.state.process_cancel(&mut order, order_id, account.owner(), ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        order.emit_order_canceled<BaseAsset, QuoteAsset>(self.id.to_inner(), clock.timestamp_ms());
    }

    public fun stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &TxContext,
    ) {
        self.state.process_stake(account.owner(), amount, ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);
    }

    public fun unstake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &TxContext,
    ) {
        account.validate_proof(proof);

        self.state.process_unstake(account.owner(), ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);
    }

    public fun submit_proposal<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        account.validate_proof(proof);

        self.state.process_proposal(account.owner(), taker_fee, maker_fee, stake_required, ctx);
    }

    public fun vote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        proposal_id: address,
        ctx: &TxContext,
    ) {
        account.validate_proof(proof);

        self.state.process_vote(account.owner(), proposal_id, ctx);
    }

}
