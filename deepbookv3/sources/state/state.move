module deepbookv3::state {
    use std::ascii::{String};

    use sui::balance::Balance;
    use sui::table::{Table, add};
    use sui::sui::SUI;

    use deepbookv3::pool::{Pool, Self};
    use deepbookv3::pool_metadata::{Self, PoolMetadata};

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;

    public struct State has key, store {
        id: UID,
        pools: Table<String, PoolMetadata>,
        // deep_reference_price: DeepReferencePrice, TODO
        // stake_vault: Balance<DEEP>, TODO
    }

    public fun refresh_metadata<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let pool_metadata = get_pool_metadata_mut(state, pool);
        pool_metadata.refresh(ctx);
    }

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

    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        // cap: DeepbookAdminCap, TODO
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
    ) {
        let pool_metadata = get_pool_metadata_mut(state, pool);
        pool_metadata.set_as_stable();

        // pool.set_fees() TODO
    }

    // GOVERNANCE 

    public(package) fun submit_proposal<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        maker_fee: u64,
        taker_fee: u64,
        stake_required: u64,
    ) {
        // get sender
        // make sure he has enough stake to submit the proposal
        let pool_metadata = get_pool_metadata_mut(state, pool);
        pool_metadata.add_proposal(maker_fee, taker_fee, stake_required);
    }

    public(package) fun vote<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
        proposal_id: u64,
        ctx: &TxContext,
    ) {
        // get user 
        let user = ctx.sender();
        // get stake and calculate voting power
        let voting_power = 0; // TODO
        
        let pool_metadata = get_pool_metadata_mut(state, pool);
        let winning_proposal = pool_metadata.vote(proposal_id, user, voting_power);
        if (winning_proposal.is_some()) {
            // TODO: set next fees
        }
    }

    // HELPERS

    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>
    ): &mut PoolMetadata {
        let pool_key = pool.pool_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        state.pools.borrow_mut(pool_key)
    }
}