// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::state { // Consider renaming this module
    use sui::{
        balance::{Self, Balance},
        bag::{Self, Bag},
        sui::SUI,
    };

    use deepbook::{
        account::{Account, TradeProof},
        pool::{Pool, DEEP, Self},
        state_manager,
        pool_metadata::{Self, PoolMetadata},
        deep_reference_price::{Self, DeepReferencePools},
    };

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const ENotEnoughStake: u64 = 3;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 100;
    const DEFAULT_TAKER_FEE: u64 = 1000;
    const DEFAULT_MAKER_FEE: u64 = 500;

    public struct State has key {
        id: UID,
        // TODO: upgrade-ability plan? do we need?
        pools: Bag,
        deep_reference_pools: DeepReferencePools,
        vault: Balance<DEEP>,
    }

    /// Create a new State and share it. Called once during init.
    public(package) fun create_and_share(ctx: &mut TxContext) {
        let state = State {
            id: object::new(ctx),
            pools: bag::new(ctx),
            deep_reference_pools: deep_reference_price::new(),
            vault: balance::zero(),
        };
        transfer::share_object(state);
    }

    /// Create a new pool. Calls create_pool inside Pool then registers it in
    /// the state. `pool_key` is a sorted, concatenated string of the two asset
    /// names. If SUI/USDC exists, you can't create USDC/SUI.
    public(package) fun create_pool<BaseAsset, QuoteAsset>(
        self: &mut State,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        let (pool_key, rev_key) = pool::create_pool<BaseAsset, QuoteAsset>(
            DEFAULT_TAKER_FEE,
            DEFAULT_MAKER_FEE,
            tick_size,
            lot_size,
            min_size,
            creation_fee,
            ctx
        );

        assert!(!self.pools.contains(pool_key) && !self.pools.contains(rev_key), EPoolAlreadyExists);

        let pool_metadata = pool_metadata::new(ctx);
        self.pools.add(pool_key, pool_metadata);
    }

    /// Set the as stable or volatile. This changes the fee structure of the pool.
    /// New proposals will be asserted against the new fee structure.
    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        self.get_pool_metadata_mut(pool, ctx)
            .set_as_stable(stable);

        // TODO: set fees
    }

    /// Insert a DEEP data point into a pool.
    /// reference_pool is a DEEP pool, ie DEEP/USDC. This will be validated against DeepPriceReferencePools.
    /// pool is the Pool that will have the DEEP data point added.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset>(
        self: &State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
        pool: &mut Pool<DEEPBaseAsset, DEEPQuoteAsset>,
        timestamp: u64,
    ) {
        let (base_conversion_rate, quote_conversion_rate) = self.deep_reference_pools
            .get_conversion_rates(reference_pool, pool);

        pool.add_deep_price_point(
            base_conversion_rate,
            quote_conversion_rate,
            timestamp,
        );
    }

    /// Add a DEEP reference pool: DEEP/USDC, DEEP/SUI, etc.
    /// This will be used to validate DEEP data points.
    public(package) fun add_reference_pool<BaseAsset, QuoteAsset>(
        self: &mut State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
    ) {
        self.deep_reference_pools.add_reference_pool(reference_pool);
    }

    /// Stake DEEP in the pool. This will increase the user's voting power next epoch
    /// Individual user stakes are stored inside of the pool.
    /// A user's stake is tracked as stake_amount, staked before current epoch, their "active" amount,
    /// and next_stake_amount, stake_amount + new stake during this epoch. Upon refresh, stake_amount = next_stake_amount.
    /// Total voting power is maintained in the pool metadata.
    public(package) fun stake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        let user = account.owner();
        let (old_stake, new_stake) = pool.increase_user_stake(user, amount, ctx);
        self.get_pool_metadata_mut(pool, ctx)
            .add_voting_power(old_stake, new_stake);
        let balance = account.withdraw_with_proof<DEEP>(proof, amount, ctx).into_balance();
        self.vault.join(balance);
    }

    /// Unstake DEEP in the pool. This will decrease the user's voting power.
    /// All stake for this user will be removed.
    /// If the user has voted, their vote will be removed.
    /// If the user had accumulated rebates during this epoch, they will be forfeited.
    public(package) fun unstake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        account: &mut Account,
        proof: &TradeProof,
        ctx: &mut TxContext
    ) {
        let user = account.owner();
        let (old_stake, new_stake) = pool.remove_user_stake(user, ctx);
        self.get_pool_metadata_mut(pool, ctx)
            .remove_voting_power(old_stake, new_stake);
        let balance = self.vault.split(old_stake + new_stake).into_coin(ctx);
        account.deposit_with_proof<DEEP>(proof, balance);
    }

    /// Submit a proposal to change the fee structure of a pool.
    /// The user submitting this proposal must have vested stake in the pool.
    public(package) fun submit_proposal<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        user: address,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        let (stake, _) = pool.get_user_stake(user, ctx);
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.add_proposal(user, maker_fee, taker_fee, stake_required);
    }

    /// Vote on a proposal using the user's full voting power.
    /// If the vote pushes proposal over quorum, PoolData is created.
    /// Set the Pool's next_pool_data with the created PoolData.
    public(package) fun vote<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        user: address,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        let (stake, _) = pool.get_user_stake(user, ctx);
        assert!(stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        let winning_proposal = pool_metadata.vote(proposal_id, user, stake);
        let next_trade_params = if (winning_proposal.is_none()) {
            option::none()
        } else {
            let (stake_required, taker_fee, maker_fee) = winning_proposal
                .borrow()
                .get_proposal_params();

            let fees = state_manager::new_trade_params(taker_fee, maker_fee, stake_required);
            option::some(fees)
        };
        pool.set_next_trade_params(next_trade_params);
    }

    /// Check whether pool exists, refresh and return its metadata.
    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext
    ): &mut PoolMetadata {
        let pool_key = pool.key();
        assert!(self.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata: &mut PoolMetadata = &mut self.pools[pool_key];
        pool_metadata.refresh(ctx);
        pool_metadata
    }
}
