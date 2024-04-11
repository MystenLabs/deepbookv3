module deepbookv3::state {
    use sui::balance::Balance;
    use sui::table::Table;
    use std::string::{String, utf8};

    use deepbookv3::pool::Pool;
    use deepbookv3::pool_metadata::PoolMetadata;

    const EPoolDoesNotExist: u64 = 1;
    public struct State has key, store {
        id: UID,
        pools: Table<String, PoolMetadata>,
        // deep_reference_price: DeepReferencePrice,
        // stake_vault: Balance<DEEP>,
    }

    public fun refresh_metadata<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let pool_key = utf8(b""); // pool.get_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        let mut pool_metadata = state.pools.borrow_mut(pool_key);
        let current_epoch = ctx.epoch();
        if (pool_metadata.get_last_refresh_epoch() == current_epoch) return;

        pool_metadata.clear_proposals();
    }
}