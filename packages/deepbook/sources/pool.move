// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
module deepbook::pool {
    use std::type_name;

    use sui::{
        coin::Coin,
        sui::SUI,
        clock::Clock,
        event,
        vec_set::VecSet,
    };

    use deepbook::{
        math,
        constants,
        balance_manager::{Self, BalanceManager, TradeProof},
        order_info::{Self, OrderInfo},
        book::{Self, Book},
        state::{Self, State},
        vault::{Self, Vault, DEEP},
        deep_price::{Self, DeepPrice},
        registry::{DeepbookAdminCap, Registry},
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
    const EInvalidOrderBalanceManager: u64 = 10;
    const EIneligibleTargetPool: u64 = 11;

    const TREASURY_ADDRESS: address = @0x0; // TODO: if different per pool, move to pool struct

    public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
        id: UID,
        book: Book,
        state: State,
        vault: Vault<BaseAsset, QuoteAsset>,
        deep_price: DeepPrice,
    }

    public struct PoolCreated<phantom BaseAsset, phantom QuoteAsset> has copy, store, drop {
        pool_id: ID,
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        whitelisted_pool: bool,
    }

    /// Create a new pool. The pool is registered in the registry.
    /// Checks are performed to ensure the tick size, lot size, and min size are valid.
    /// The creation fee is transferred to the treasury address.
    /// Returns the id of the pool created
    public fun create_pool_admin<BaseAsset, QuoteAsset>(
        registry: &mut Registry,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Coin<SUI>,
        whitelisted_pool: bool,
        _cap: &DeepbookAdminCap,
        ctx: &mut TxContext,
    ): ID {
        create_pool<BaseAsset, QuoteAsset>(
            registry,
            tick_size,
            lot_size,
            min_size,
            creation_fee,
            whitelisted_pool,
            ctx,
        )
    }

    /// Accessor to check if the pool is whitelisted.
    public fun whitelisted<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): bool {
        self.state.governance().whitelisted()
    }

    /// Place a limit order. Quantity is in base asset terms.
    /// For current version pay_with_deep must be true, so the fee will be paid with DEEP tokens.
    public fun place_limit_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): OrderInfo {
        self.place_order_int(
            balance_manager,
            proof,
            client_order_id,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            clock,
            false,
            ctx,
        )
    }

    /// Place a market order. Quantity is in base asset terms. Calls place_limit_order with
    /// a price of MAX_PRICE for bids and MIN_PRICE for asks. Any quantity not filled is cancelled.
    public fun place_market_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &TxContext,
    ): OrderInfo {
        self.place_order_int(
            balance_manager,
            proof,
            client_order_id,
            constants::immediate_or_cancel(),
            self_matching_option,
            if (is_bid) constants::max_price() else constants::min_price(),
            quantity,
            is_bid,
            pay_with_deep,
            clock.timestamp_ms(),
            clock,
            true,
            ctx,
        )
    }

    /// Swap exact amount without needing an balance_manager.
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
            (base_quantity, _) = self.get_amount_out(0, quote_quantity, clock.timestamp_ms());
        };
        base_quantity = base_quantity - base_quantity % self.book.lot_size();

        let mut temp_balance_manager = balance_manager::new(ctx);
        temp_balance_manager.deposit(base_in, ctx);
        temp_balance_manager.deposit(quote_in, ctx);
        temp_balance_manager.deposit(deep_in, ctx);
        let proof = temp_balance_manager.generate_proof_as_owner(ctx);

        self.place_market_order(
            &mut temp_balance_manager,
            &proof,
            0,
            constants::self_matching_allowed(),
            base_quantity,
            is_bid,
            pay_with_deep,
            clock,
            ctx
        );

        let base_out = temp_balance_manager.withdraw_with_proof<BaseAsset>(&proof, 0, true).into_coin(ctx);
        let quote_out = temp_balance_manager.withdraw_with_proof<QuoteAsset>(&proof, 0, true).into_coin(ctx);
        let deep_out = temp_balance_manager.withdraw_with_proof<DEEP>(&proof, 0, true).into_coin(ctx);

        temp_balance_manager.delete();

        (base_out, quote_out, deep_out)
    }

    /// Modifies an order given order_id and new_quantity.
    /// New quantity must be less than the original quantity.
    /// Order must not have already expired.
    public fun modify_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        order_id: u128,
        new_quantity: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let (cancel_quantity, order) = self.book.modify_order(order_id, new_quantity, clock.timestamp_ms());
        assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
        let (settled, owed) = self.state.process_modify(balance_manager.id(), cancel_quantity, order, ctx);
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);

        order.emit_order_modified<BaseAsset, QuoteAsset>(self.id.to_inner(), proof.trader(), clock.timestamp_ms());
    }

    /// Cancel an order. The order must be owned by the balance_manager.
    /// The order is removed from the book and the balance_manager's open orders.
    /// The balance_manager's balance is updated with the order's remaining quantity.
    /// Order canceled event is emitted.
    public fun cancel_order<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        order_id: u128,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let mut order = self.book.cancel_order(order_id);
        assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
        let (settled, owed) = self.state.process_cancel(&mut order, balance_manager.id(), ctx);
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);

        order.emit_order_canceled<BaseAsset, QuoteAsset>(self.id.to_inner(), proof.trader(), clock.timestamp_ms());
    }

    /// Cancel all open orders placed by the balance manager in the pool.
    public fun cancel_all_orders<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let open_orders = self.state.account(balance_manager.id()).open_orders().into_keys();
        let mut i = 0;
        while (i < open_orders.length()) {
            let order_id = open_orders[i];
            self.cancel_order(balance_manager, proof, order_id, clock, ctx);
            i = i + 1;
        }
    }

    /// Stake DEEP tokens to the pool. The balance_manager must have enough DEEP tokens.
    /// The balance_manager's data is updated with the staked amount.
    public fun stake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        amount: u64,
        ctx: &TxContext,
    ) {
        let (settled, owed) = self.state.process_stake(balance_manager.id(), amount, ctx);
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);
    }

    /// Unstake DEEP tokens from the pool. The balance_manager must have enough staked DEEP tokens.
    /// The balance_manager's data is updated with the unstaked amount.
    /// Balance is transferred to the balance_manager immediately.
    public fun unstake<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        ctx: &TxContext,
    ) {
        balance_manager.validate_proof(proof);

        let (settled, owed) = self.state.process_unstake(balance_manager.id(), ctx);
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);
    }

    /// Submit a proposal to change the taker fee, maker fee, and stake required.
    /// The balance_manager must have enough staked DEEP tokens to participate.
    /// Each balance_manager can only submit one proposal per epoch.
    /// If the maximum proposal is reached, the proposal with the lowest vote is removed.
    /// If the balance_manager has less voting power than the lowest voted proposal, the proposal is not added.
    public fun submit_proposal<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        taker_fee: u64,
        maker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        balance_manager.validate_proof(proof);

        self.state.process_proposal(balance_manager.id(), taker_fee, maker_fee, stake_required, ctx);
    }

    /// Vote on a proposal. The balance_manager must have enough staked DEEP tokens to participate.
    /// Full voting power of the balance_manager is used.
    /// Voting for a new proposal will remove the vote from the previous proposal.
    public fun vote<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        proposal_id: ID,
        ctx: &TxContext,
    ) {
        balance_manager.validate_proof(proof);

        self.state.process_vote(balance_manager.id(), proposal_id, ctx);
    }

    /// Claim the rewards for the balance_manager. The balance_manager must have rewards to claim.
    /// The balance_manager's data is updated with the claimed rewards.
    public fun claim_rebates<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        ctx: &TxContext,
    ) {
        let (settled, owed) = self.state.process_claim_rebates(balance_manager.id(), ctx);
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);
    }

    // GETTERS

    /// Dry run to determine the amount out for a given base or quote amount.
    /// Only one out of base or quote amount should be non-zero.
    public fun get_amount_out<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        base_amount: u64,
        quote_amount: u64,
        current_timestamp: u64,
    ): (u64, u64) {
        self.book.get_amount_out(
            base_amount,
            quote_amount,
            current_timestamp,
        )
    }

    /// Returns the mid price of the pool.
    public fun mid_price<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        clock: &Clock,
    ): u64 {
        self.book.mid_price(clock.timestamp_ms())
    }

    /// Returns the order_id for all open order for the balance_manager in the pool.
    public fun account_open_orders<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        balance_manager: ID,
    ): VecSet<u128> {
        self.state.account(balance_manager).open_orders()
    }

    /// Returns the (price_vec, quantity_vec) for the level2 order book.
    /// The price_low and price_high are inclusive, all orders within the range are returned.
    /// is_bid is true for bids and false for asks.
    public fun get_level2_range<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        price_low: u64,
        price_high: u64,
        is_bid: bool,
    ): (vector<u64>, vector<u64>) {
        self.book.get_level2_range_and_ticks(price_low, price_high, constants::max_u64(), is_bid)
    }

    /// Returns the (price_vec, quantity_vec) for the level2 order book.
    /// Ticks are the maximum number of ticks to return starting from best bid and best ask.
    /// (bid_price, bid_quantity, ask_price, ask_quantity) are returned as 4 vectors.
    /// The price vectors are sorted in descending order for bids and ascending order for asks.
    public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        ticks: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        let (bid_price, bid_quantity) = self.book.get_level2_range_and_ticks(constants::min_price(), constants::max_price(), ticks, true);
        let (ask_price, ask_quantity) = self.book.get_level2_range_and_ticks(constants::min_price(), constants::max_price(), ticks, false);

        (bid_price, bid_quantity, ask_price, ask_quantity)
    }

    // OPERATIONAL PUBLIC

    /// Adds a price point along with a timestamp to the deep price.
    /// Allows for the calculation of deep price per base asset.
    public fun add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
        target_pool: &mut Pool<BaseAsset, QuoteAsset>,
        reference_pool: &Pool<ReferenceBaseAsset, ReferenceQuoteAsset>,
        clock: &Clock,
    ) {
        assert!(reference_pool.whitelisted(), EIneligibleReferencePool);
        let reference_pool_price = reference_pool.mid_price(clock);
        let reference_base_type = type_name::get<ReferenceBaseAsset>();
        let reference_quote_type = type_name::get<ReferenceQuoteAsset>();
        let target_base_type = type_name::get<BaseAsset>();
        let target_quote_type = type_name::get<QuoteAsset>();
        let deep_type = type_name::get<DEEP>();
        let timestamp = clock.timestamp_ms();

        assert!((reference_base_type == deep_type || reference_quote_type == deep_type), EIneligibleTargetPool);

        let reference_deep_is_base = reference_base_type == deep_type;
        let reference_other_type = if (reference_deep_is_base) {
            reference_quote_type
        } else {
            reference_base_type
        };
        let reference_other_is_target_base = reference_other_type == target_base_type;
        let reference_other_is_target_quote = reference_other_type == target_quote_type;
        assert!(reference_other_is_target_base || reference_other_is_target_quote, EIneligibleTargetPool);

        // For DEEP/USDC pool, reference_deep_is_base is true, DEEP per USDC is reference_pool_price
        // For USDC/DEEP pool, reference_deep_is_base is false, USDC per DEEP is reference_pool_price
        let deep_per_reference_other_price = if (reference_deep_is_base) {
            math::div(1_000_000_000, reference_pool_price)
        } else {
            reference_pool_price
        };

        // For USDC/SUI pool, reference_other_is_target_base is true, add price point to deep per base
        // For SUI/USDC pool, reference_other_is_target_base is false, add price point to deep per quote
        if (reference_other_is_target_base){
            target_pool.deep_price.add_price_point(deep_per_reference_other_price, timestamp, true);
        } else {
            target_pool.deep_price.add_price_point(deep_per_reference_other_price, timestamp, false);
        }
    }

    /// Burns DEEP tokens from the pool. Amount to burn is within history
    public fun burn_deep<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
    ) {
        let balance_to_burn = self.state.history_mut().reset_balance_to_burn();
        assert!(balance_to_burn > 0, EInvalidAmountIn);
        // TODO: burn deep balance
        // let deep_balance = self.vault.withdraw_deep(balance_to_burn);
    }

    // OPERATIONAL OWNER

    /// Set a pool as a stable pool. Stable pools have a lower fee.
    /// Only Admin can set a pool as stable.
    public fun set_stable<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        _cap: &DeepbookAdminCap,
        stable: bool,
        ctx: &TxContext,
    ) {
        self.state.governance_mut(ctx).set_stable(stable);
    }

    public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
    ) {
        balance_manager.validate_proof(proof);

        let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);
    }

    public fun vault_balances<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
    ): (u64, u64, u64) {
        self.vault.balances()
    }

    public fun unregister_pool_admin<BaseAsset, QuoteAsset>(
        registry: &mut Registry,
        _cap: &DeepbookAdminCap,
    ) {
        registry.unregister_pool<BaseAsset, QuoteAsset>();
    }

    public fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(
        registry: &Registry,
    ): ID {
        registry.get_pool_id<BaseAsset, QuoteAsset>()
    }

    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        registry: &mut Registry,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Coin<SUI>,
        whitelisted_pool: bool,
        ctx: &mut TxContext,
    ): ID {
        assert!(creation_fee.value() == constants::pool_creation_fee(), EInvalidFee);
        assert!(tick_size > 0, EInvalidTickSize);
        assert!(lot_size > 0, EInvalidLotSize);
        assert!(min_size > 0, EInvalidMinSize);

        assert!(type_name::get<BaseAsset>() != type_name::get<QuoteAsset>(), ESameBaseAndQuote);
        let pool_uid = object::new(ctx);
        let pool_id = pool_uid.to_inner();

        let mut pool = Pool<BaseAsset, QuoteAsset> {
            id: pool_uid,
            book: book::empty(tick_size, lot_size, min_size, ctx),
            state: state::empty(ctx),
            vault: vault::empty(),
            deep_price: deep_price::empty(),
        };

        registry.register_pool<BaseAsset, QuoteAsset>(pool_id);
        if (whitelisted_pool) {
            pool.set_whitelist(ctx);
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
            whitelisted_pool,
        });

        // TODO: reconsider sending the Coin here. User pays gas;
        // TODO: depending on the frequency of the event;
        transfer::public_transfer(creation_fee, TREASURY_ADDRESS);
        let pool_id = object::id(&pool);
        transfer::share_object(pool);

        pool_id
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

    /// Set a pool as a whitelist pool at pool creation. Whitelist pools have zero fees.
    /// Only called by admin during pool creation
    fun set_whitelist<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let base = type_name::get<BaseAsset>();
        let quote = type_name::get<QuoteAsset>();
        let deep_type = type_name::get<DEEP>();
        assert!(base == deep_type || quote == deep_type, EIneligibleWhitelist);

        self.state.governance_mut(ctx).set_whitelist(true);
    }

    fun place_order_int<BaseAsset, QuoteAsset>(
        self: &mut Pool<BaseAsset, QuoteAsset>,
        balance_manager: &mut BalanceManager,
        proof: &TradeProof,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        market_order: bool,
        ctx: &TxContext,
    ): OrderInfo {
        assert!(pay_with_deep || self.whitelisted(), EFeeTypeNotSupported);
        let whitelisted = self.whitelisted();
        let (conversion_is_base, deep_per_asset) = self.deep_price.deep_per_asset(whitelisted);

        let mut order_info = order_info::new(
            self.id.to_inner(),
            balance_manager.id(),
            client_order_id,
            proof.trader(),
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            ctx.epoch(),
            expire_timestamp,
            deep_per_asset,
            conversion_is_base,
            market_order,
        );
        self.book.create_order(&mut order_info, clock.timestamp_ms());
        let (settled, owed) = self.state.process_create(
            &mut order_info,
            whitelisted,
            ctx
        );
        self.vault.settle_balance_manager(settled, owed, balance_manager, proof);
        if (order_info.remaining_quantity() > 0) order_info.emit_order_placed();

        order_info
    }
}
