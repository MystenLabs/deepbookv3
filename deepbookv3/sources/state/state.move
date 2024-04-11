module deepbookv3::state {
    // const EPoolDoesNotExist: u64 = 1;
    // public struct State has key, store {
    //     id: UID,
    //     last_epoch_refresh: u64,
    //     pools: Table<String, PoolMetadata>,
    //     deep_reference_price: DeepReferencePrice,
    //     stake_vault: Balance<DEEP>,
    // }

    // public fun refresh_metadata(
    //     state: &mut State,
    //     pool: &Pool,
    //     ctx: &TxContext,
    // ) {
    //     let pool_key = pool.get_key();
    //     assert!(state.pools.contains_key(pool_key), EPoolDoesNotExist);
    //     let mut pool_metadata = state.pools.get(pool_key);
    //     let current_epoch = ctx.epoch();
    //     if (state.last_epoch_refresh == current_epoch) return;

    //     state.last_epoch_refresh = current_epoch;
    // }
}