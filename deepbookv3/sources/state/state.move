module deepbookv3::state {
    use std::ascii::{String};

    use sui::balance::{Balance};
    use sui::table::{Table, add};
    use sui::sui::SUI;

    use deepbookv3::pool::{Pool, DEEP, Self};
    use deepbookv3::pool_metadata::{Self, PoolMetadata};
    use deepbookv3::deep_reference_price::{DeepReferencePools};

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const ENotEnoughStake: u64 = 3;

    const STAKE_REQUIRED_TO_PARTICIPATE: u64 = 1000; // TODO

    public struct State has key, store {
        id: UID,
        pools: Table<String, PoolMetadata>,
        deep_reference_pools: DeepReferencePools,
        vault: Balance<DEEP>,
    }
    
    /// Create a new pool. Calls create_pool inside Pool then registers it in the state.
    /// pool_key is a sorted, concatenated string of the two asset names. If SUI/USDC exists, you can't create USDC/SUI.
    public fun create_pool<BaseAsset, QuoteAsset>(
        state: &mut State,
        taker_fee: u64,
        maker_fee: u64,
        tick_size: u64,
        lot_size: u64,
        creation_fee: Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        let pool_key = pool::create_pool<BaseAsset, QuoteAsset>(taker_fee, maker_fee, tick_size, lot_size, creation_fee, ctx);
        assert!(!state.pools.contains(pool_key), EPoolAlreadyExists);

        let pool_metadata = pool_metadata::new(ctx);
        state.pools.add(pool_key, pool_metadata);
    }

    /// Set the as stable or volatile. This changes the fee structure of the pool.
    /// New proposals will be asserted against the new fee structure.
    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        // cap: DeepbookAdminCap, TODO
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        stable: bool,
        ctx: &TxContext,
    ) {
        let pool_metadata = get_pool_metadata_mut(state, pool, ctx);
        pool_metadata.set_as_stable(stable);

        // pool.set_fees() TODO
    }

    /// Insert a DEEP data point into a pool.
    /// reference_pool is a DEEP pool, ie DEEP/USDC. This will be validated against DeepPriceReferencePools.
    /// pool is the Pool that will have the DEEP data point added.
    public(package) fun add_deep_price_point<BaseAsset, QuoteAsset>(
        state: &State,
        reference_pool: &Pool<BaseAsset, QuoteAsset>,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let (base_conversion_rate, quote_conversion_rate) = state.deep_reference_pools.get_conversion_rates(reference_pool, pool);
        let timestamp = ctx.epoch_timestamp_ms();
        pool.add_deep_price_point(base_conversion_rate, quote_conversion_rate, timestamp);
    }

    // STAKE

    /// Stake DEEP in the pool. This will increase the user's voting power next epoch
    /// Individual user stakes are stored inside of the pool.
    /// A user's stake is tracked as stake_amount, staked before current epoch, their "active" amount,
    /// and next_stake_amount, stake_amount + new stake during this epoch. Upon refresh, stake_amount = next_stake_amount.
    /// Total voting power is maintained in the pool metadata.
    public(package) fun stake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        amount: Balance<DEEP>,
        ctx: &mut TxContext,
    ) {
        let user = ctx.sender();
        let total_user_stake = pool.increase_user_stake(user, amount.value(), ctx);

        let pool_metadata = get_pool_metadata_mut(state, pool, ctx);
        pool_metadata.add_voting_power(total_user_stake, amount.value());

        state.vault.join(amount);
    }

    /// Unstake DEEP in the pool. This will decrease the user's voting power.
    /// All stake for this user will be removed.
    /// If the user has voted, their vote will be removed.
    /// If the user had accumulated rebates during this epoch, they will be forfeited.
    public(package) fun unstake<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        ctx: &mut TxContext
    ): Balance<DEEP> {
        let user = ctx.sender();

        // total amount staked before this epoch, total amount staked during this epoch
        let (user_old_stake, user_new_stake) = pool.remove_user_stake(user, ctx);
        let pool_metadata = get_pool_metadata_mut(state, pool, ctx);
        pool_metadata.remove_voting_power(user_old_stake, user_new_stake);

        state.vault.split(user_old_stake + user_new_stake)
    }

    // GOVERNANCE 

    /// Submit a proposal to change the fee structure of a pool.
    /// The user submitting this proposal must have vested stake in the pool.
    public(package) fun submit_proposal<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
        ctx: &mut TxContext,
    ) {
        let (user_stake, _) = pool.get_user_stake(ctx.sender(), ctx);
        assert!(user_stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);
        
        let pool_metadata = get_pool_metadata_mut(state, pool, ctx);
        pool_metadata.add_proposal(maker_fee, taker_fee, stake_required);
    }

    /// Vote on a proposal using the user's full voting power.
    /// If the vote pushes proposal over quorum, PoolData is created.
    /// Set the Pool's next_pool_data with the created PoolData.
    public(package) fun vote<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        proposal_id: u64,
        ctx: &mut TxContext,
    ) {
        let user = ctx.sender();
        let (user_stake, _) = pool.get_user_stake(user, ctx);
        assert!(user_stake >= STAKE_REQUIRED_TO_PARTICIPATE, ENotEnoughStake);
        
        let pool_metadata = get_pool_metadata_mut(state, pool, ctx);
        let winning_proposal = pool_metadata.vote(proposal_id, user, user_stake);
        if (winning_proposal.is_some()) {
            // TODO: set next fees
        }
    }

    // HELPERS

    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext
    ): &mut PoolMetadata {
        let pool_key = pool.pool_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata = &mut state.pools[pool_key];
        pool_metadata.refresh(ctx);

        pool_metadata
    }
}