// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
/// TODO: No authorization checks are implemented;
module deepbook::pool {
    use std::type_name;

    use sui::{
        coin::Coin,
        balance::Balance,
        sui::SUI,
        clock::Clock,
        event,
        vec_set::VecSet,
    };

    use deepbook::{
        math,
        account::{Self, Account, TradeProof},
        order_info::{Self, OrderInfo},
        book::{Self, Book},
        state::{Self, State},
        vault::{Self, Vault, DEEP},
        registry::Registry,
        big_vector::BigVector,
        order::Order,
    };

    const EInvalidFee: u64 = 1;
    const ESameBaseAndQuote: u64 = 2;
    const EInvalidTickSize: u64 = 3;
    const EInvalidLotSize: u64 = 4;
    const EInvalidMinSize: u64 = 5;
    const EInvalidAmountIn: u64 = 6;
    const EIneligibleWhitelist: u64 = 7;
    const EIneligibleReferencePool: u64 = 8;
    const EFeeTypeNotSupported: u64 = 9;
    const ENotEnoughDeep: u64 = 10;
    const EInvalidOrderOwner: u64 = 11;

    const POOL_CREATION_FEE: u64 = 100 * 1_000_000_000; // 100 SUI, can be updated
    const MIN_PRICE: u64 = 1;
    const MAX_PRICE: u64 = (1u128 << 63 - 1) as u64;
    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct
    const MAX_U64: u64 = (1u128 << 64 - 1) as u64;

    /// DeepBookAdminCap is used to call admin functions.
    public struct DeepBookAdminCap has key, store {
        id: UID,
    }

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
            book: book::empty(tick_size, lot_size, min_size, ctx),
            state: state::empty(ctx),
            vault: vault::empty(),
        };

        let params = pool.state.governance().trade_params();
        let (taker_fee, maker_fee) = (params.taker_fee(), params.maker_fee());
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

    public fun whitelisted<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): bool {
        self.state.governance().whitelisted()
    }

    /// Place a limit order. Quantity is in base asset terms.
    /// For current version pay_with_deep must be true, so the fee will be paid with DEEP tokens.
    public fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): OrderInfo {
        assert!(pay_with_deep || self.whitelisted(), EFeeTypeNotSupported);
        let trade_params = self.state.governance().trade_params();
        let mut order_info = order_info::new(
            self.id.to_inner(),
            client_order_id,
            account.owner(),
            proof.trader(),
            order_type,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            trade_params,
        );
        let deep_per_base = self.state.deep_price().conversion_rate();
        self.book.create_order(&mut order_info, deep_per_base, clock.timestamp_ms());
        self.state.process_create(&order_info, ctx);
        self.vault.settle_order(&order_info, self.state.user_mut(account.owner(), ctx.epoch()), deep_per_base);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        if (order_info.remaining_quantity() > 0) order_info.emit_order_placed();

        order_info
    }

    /// Place a market order. Quantity is in base asset terms. Calls place_limit_order with
    /// a price of MAX_PRICE for bids and MIN_PRICE for asks. Any quantity not filled is cancelled.
    public fun place_market_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        client_order_id: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &TxContext,
    ): OrderInfo {
        self.place_limit_order(
            account,
            proof,
            client_order_id,
            order_info::immediate_or_cancel(),
            if (is_bid) MAX_PRICE else MIN_PRICE,
            quantity,
            is_bid,
            pay_with_deep,
            clock.timestamp_ms(),
            clock,
            ctx,
        )
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
        let quote_quantity = quote_in.value();
        assert!(base_quantity > 0 || quote_quantity > 0, EInvalidAmountIn);
        assert!(!(base_quantity > 0 && quote_quantity > 0), EInvalidAmountIn);

        let pay_with_deep = deep_in.value() > 0;
        let is_bid = quote_quantity > 0;
        if (is_bid) {
            (base_quantity, _) = self.get_amount_out(0, quote_quantity);
        };
        base_quantity = base_quantity - base_quantity % self.book.lot_size();
        let base_to_deep = self.state.deep_price().conversion_rate();
        let taker_fee = self.state.governance().trade_params().taker_fee();
        let deep_required = math::mul(base_quantity, base_to_deep);
        let deep_required = math::mul(deep_required, taker_fee);
        assert!(deep_in.value() >= deep_required, ENotEnoughDeep);

        let mut temp_account = account::new(ctx);
        temp_account.deposit(base_in, ctx);
        temp_account.deposit(quote_in, ctx);
        temp_account.deposit(deep_in, ctx);
        let proof = temp_account.generate_proof_as_owner(ctx);

        self.place_market_order(&mut temp_account, &proof, 0, base_quantity, is_bid, pay_with_deep, clock, ctx);

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
        assert!(order.owner() == account.owner(), EInvalidOrderOwner);
        self.state.process_modify(account.owner(), base, quote, deep, ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        order.emit_order_modified<BaseAsset, QuoteAsset>(self.id.to_inner(), proof.trader(), clock.timestamp_ms());
    }

    /// Cancel an order. The order must be owned by the account.
    /// The order is removed from the book and the user's open orders.
    /// The user's balance is updated with the order's remaining quantity.
    /// Order canceled event is emitted.
    public fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        order_id: u128,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let mut order = self.book.cancel_order(order_id);
        assert!(order.owner() == account.owner(), EInvalidOrderOwner);
        self.state.process_cancel(&mut order, order_id, account.owner(), ctx);
        self.vault.settle_user(self.state.user_mut(account.owner(), ctx.epoch()), account, proof);

        order.emit_order_canceled<BaseAsset, QuoteAsset>(self.id.to_inner(), proof.trader(), clock.timestamp_ms());
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

    public fun claim_rebates<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &TxContext,
    ) {
        let user = self.state.user_mut(account.owner(), ctx.epoch());
        user.claim_rebates();
        self.vault.settle_user(user, account, proof);
    }

    // GETTERS

    public fun get_amount_out<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        base_amount: u64,
        quote_amount: u64,
    ): (u64, u64) {
        self.book.get_amount_out(base_amount, quote_amount)
    }

    public fun mid_price<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): u64 {
        self.book.mid_price()
    }

    public fun user_open_orders<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        user: address,
    ): VecSet<u128> {
        self.state.user(user).open_orders()
    }

    public fun get_level2_range<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
        is_bid: bool,
    ): (vector<u64>, vector<u64>) {
        self.book.get_level2_range_and_ticks(price_low, price_high, MAX_U64, is_bid)
    }

    public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        ticks: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        let (bid_price, bid_quantity) = self.book.get_level2_range_and_ticks(MIN_PRICE, MAX_PRICE, ticks, true);
        let (ask_price, ask_quantity) = self.book.get_level2_range_and_ticks(MIN_PRICE, MAX_PRICE, ticks, false);

        (bid_price, bid_quantity, ask_price, ask_quantity)
    }

    // OPERATIONAL PUBLIC

    public fun add_deep_price_point<BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset>(
        target_pool: &mut Pool<BaseAsset, QuoteAsset>,
        reference_pool: &Pool<DEEPBaseAsset, DEEPQuoteAsset>,
        clock: &Clock,
    ) {
        assert!(reference_pool.whitelisted(), EIneligibleReferencePool);
        let deep_price = reference_pool.mid_price();
        let pool_price = target_pool.mid_price();
        let deep_base_type = type_name::get<DEEPBaseAsset>();
        let deep_quote_type = type_name::get<DEEPQuoteAsset>();

        target_pool.vault.add_deep_price_point(deep_price, pool_price, deep_base_type, deep_quote_type, clock.timestamp_ms());
    }

    // OPERATIONAL OWNER

    public fun set_stable<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        _cap: &DeepBookAdminCap,
        stable: bool,
        ctx: &TxContext,
    ) {
        self.state.governance_mut(ctx).set_stable(stable);
    }

    public fun set_whitelist<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        _cap: &DeepBookAdminCap,
        whitelist: bool,
        ctx: &TxContext,
    ) {
        let base = type_name::get<BaseAsset>();
        let quote = type_name::get<QuoteAsset>();
        let deep_type = type_name::get<DEEP>();
        assert!(base == deep_type || quote == deep_type, EIneligibleWhitelist);

        self.state.governance_mut(ctx).set_whitelist(whitelist);
    }

    public(package) fun bids<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): &BigVector<Order> {
        self.book.bids()
    }

    public(package) fun asks<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): &BigVector<Order> {
        self.book.asks()
    }
}
