module deepbookv3::state {
    use sui::balance::Balance;
    use sui::table::{Table, add};
    use std::string::{String, utf8};

    use deepbookv3::pool::Pool;
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
        let pool_key = utf8(b""); // TODO: pool.get_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata = state.pools.borrow_mut(pool_key);
        let current_epoch = ctx.epoch();
        if (pool_metadata.get_last_refresh_epoch() == current_epoch) return;

        pool_metadata.clear_proposals();
    }

    public(package) fun track_pool<BaseAsset, QuoteAsset>(
        state: &mut State,
        pool: &Pool<BaseAsset, QuoteAsset>,
        ctx: &TxContext,
    ) {
        let pool_key = utf8(b""); // TODO: pool.get_key();
        assert!(!state.pools.contains(pool_key), EPoolAlreadyExists);

        let pool_metadata = pool_metadata::new(pool, ctx);
        state.pools.add(pool_key, pool_metadata);
    }

    public(package) fun set_pool_as_stable<BaseAsset, QuoteAsset>(
        // cap: DeepbookAdminCap, TODO
        state: &mut State,
        pool: &mut Pool<BaseAsset, QuoteAsset>,
    ) {
        let pool_key = utf8(b""); // TODO: pool.get_key();
        assert!(state.pools.contains(pool_key), EPoolDoesNotExist);

        let pool_metadata = state.pools.borrow_mut(pool_key);
        pool_metadata.set_as_stable();

        // pool.set_fees() TODO
    }
}