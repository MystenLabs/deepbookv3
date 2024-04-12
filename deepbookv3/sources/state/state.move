module deepbookv3::state {
    use sui::balance::Balance;
    use sui::table::{Table, add};
    use std::string::{String, utf8};

    use deepbookv3::pool::Pool;
    use deepbookv3::pool_metadata::{Self, PoolMetadata};
    use deepbookv3::governance::{Self};

    const EPoolDoesNotExist: u64 = 1;
    const EPoolAlreadyExists: u64 = 2;
    const EProposalDoesNotExist: u64 = 3;

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

    public(package) fun track_pool<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let pool_key = utf8(b""); // TODO: pool.get_key();
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
        // get stake and calculate voting power
        let user = ctx.sender();
        let voting_power = 0; // TODO
        
        let pool_metadata = get_pool_metadata_mut(state, pool);
        let over_quorum = governance::vote(pool_metadata, proposal_id, user, voting_power);
        if (over_quorum) {
            // push changes to pool
        }
    }

    // HELPERS

    fun get_pool_metadata_mut<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>
    ): &mut PoolMetadata {
        let pool_key = utf8(b""); // TODO: pool.get_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        state.pools.borrow_mut(pool_key)
    }
}