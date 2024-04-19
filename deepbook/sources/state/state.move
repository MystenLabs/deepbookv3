// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::state { // Consider renaming this module
    use std::ascii::String;

    use sui::{
        balance::Balance,
        table::Table,
        sui::SUI,
        coin::Coin,
        clock::Clock,
    };

    use deepbook::{
        pool::{Pool, DEEP, Self},
        pool_state,
        pool_metadata::{Self, PoolMetadata},
        deep_reference_price::DeepReferencePools,
    };

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const ENotEnoughStake: u64 = 3;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 1000; // TODO
    // const STABLE_TAKER_FEE: u64 = 100;
    // const STABLE_MAKER_FEE: u64 = 50;
    const VOLATILE_TAKER_FEE: u64 = 1000;
    const VOLATILE_MAKER_FEE: u64 = 500;

    public struct State has key, store {
        id: UID,
        pools: Table<String, PoolMetadata>,
        // pools: Bag, (other places where table is used as well)
        // bag::add<Key,Value>()
        // key = PoolKey<Base, Quote>
        // string concatenation of base and quote no longer needed
        deep_reference_pools: DeepReferencePools,
        vault: Balance<DEEP>,
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
        let pool_key = pool::create_pool<BaseAsset, QuoteAsset>(
            VOLATILE_TAKER_FEE,
            VOLATILE_MAKER_FEE,
            tick_size,
            lot_size,
            min_size,
            creation_fee,
            ctx
        );

        assert!(!self.pools.contains(pool_key), EPoolAlreadyExists);

        let pool_metadata = pool_metadata::new(ctx);
        self.pools.add(pool_key, pool_metadata);
    }

    /// Set the as stable or volatile. This changes the fee structure of the pool.
    /// New proposals will be asserted against the new fee structure.
    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        // cap: DeepbookAdminCap, TODO
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.set_as_stable(stable);

        // TODO: set fees
    }

    /// Insert a DEEP data point into a pool.
    /// reference_pool is a DEEP pool, ie DEEP/USDC. This will be validated against DeepPriceReferencePools.
    /// pool is the Pool that will have the DEEP data point added.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        self: &State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        clock: &Clock,
    ) {
        let (base_conversion_rate, quote_conversion_rate) = self.deep_reference_pools
            .get_conversion_rates(reference_pool, pool);
        let timestamp = clock.timestamp_ms();
        pool.add_deep_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    // STAKE

    /// Stake DEEP in the pool. This will increase the user's voting power next epoch
    /// Individual user stakes are stored inside of the pool.
    /// A user's stake is tracked as stake_amount, staked before current epoch, their "active" amount,
    /// and next_stake_amount, stake_amount + new stake during this epoch. Upon refresh, stake_amount = next_stake_amount.
    /// Total voting power is maintained in the pool metadata.
    public(package) fun stake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        amount: Coin<DEEP>,
        ctx: &TxContext,
    ) {
        let user = ctx.sender();
        let total_user_stake = pool.increase_user_stake(user, amount.value(), ctx);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.add_voting_power(total_user_stake, amount.value());

        self.vault.join(amount.into_balance());
    }

    /// Unstake DEEP in the pool. This will decrease the user's voting power.
    /// All stake for this user will be removed.
    /// If the user has voted, their vote will be removed.
    /// If the user had accumulated rebates during this epoch, they will be forfeited.
    public(package) fun unstake<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Coin<DEEP> {
        let user = ctx.sender();

        // total amount staked before this epoch, total amount staked during this epoch
        let (user_old_stake, user_new_stake) = pool.remove_user_stake(user, ctx);
        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.remove_voting_power(user_old_stake, user_new_stake);

        self.vault.split(user_old_stake + user_new_stake).into_coin(ctx)
    }

    // GOVERNANCE

    /// Submit a proposal to change the fee structure of a pool.
    /// The user submitting this proposal must have vested stake in the pool.
    public(package) fun submit_proposal<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &TxContext,
    ) {
        let user = ctx.sender();
        let (user_stake, _) = pool.get_user_stake(user, ctx);
        assert!(user_stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        pool_metadata.add_proposal(user, maker_fee, taker_fee, stake_required);
    }

    /// Vote on a proposal using the user's full voting power.
    /// If the vote pushes proposal over quorum, PoolData is created.
    /// Set the Pool's next_pool_data with the created PoolData.
    public(package) fun vote<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        let user = ctx.sender();
        let (user_stake, _) = pool.get_user_stake(user, ctx);
        assert!(user_stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);

        let pool_metadata = self.get_pool_metadata_mut(pool, ctx);
        let winning_proposal = pool_metadata.vote(proposal_id, user, user_stake);
        let pool_state = if (winning_proposal.is_none()) {
            option::none()
        } else {
            let (stake_required, taker_fee, maker_fee) = winning_proposal
                .borrow()
                .get_proposal_params();

            let pool_state = pool_state::new_pool_epoch_state_with_gov_params(
                stake_required, taker_fee, maker_fee
            );
            option::some(pool_state)
        };
        pool.set_next_epoch(pool_state);
    }

    // HELPERS

    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        self: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext
    ): &mut PoolMetadata {
        let pool_key = pool.pool_key();
        assert!(self.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata = &mut self.pools[pool_key];
        pool_metadata.refresh(ctx);

        pool_metadata
    }
}
