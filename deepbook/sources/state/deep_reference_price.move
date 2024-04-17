module deepbook::deep_reference_price {
    use std::{
        type_name,
        ascii::String,
    };
    
    use sui::vec_map::VecMap;

    use deepbook::pool::{Pool, DEEP}; // TODO: DEEP token

    const EIneligiblePool: u64 = 1;

    /// DeepReferencePools is a struct that holds the reference pools for the DEEP token.
    /// DEEP/SUI, DEEP/USDC, DEEP/WETH
    public struct DeepReferencePools has store {
        // Base or quote -> pool_key
        reference_pools: VecMap<String, String>,
    }

    /// Add a reference pool. Can be performed by the DeepbookAdminCap owner.
    public(package) fun add_reference_pool<BaseAsset, QutoeAsset>(
        deep_reference_price: &mut DeepReferencePools,
        pool: &Pool<BaseAsset, QutoeAsset>,
        // cap: &DeepbookAdminCap TODO
    ) {
        let (base, quote) = pool.get_base_quote_types();
        let deep_type = type_name::get<DEEP>().into_string();
        
        assert!(base == deep_type || quote == deep_type, EIneligiblePool);

        if (base == deep_type) {
            deep_reference_price.reference_pools.insert(quote, pool.pool_key());
        } else {
            deep_reference_price.reference_pools.insert(base, pool.pool_key());
        }
    }

    /// TODO: comments
    public(package) fun get_conversion_rates<BaseAsset, QutoeAsset>(
        _deep_reference_price: &DeepReferencePools,
        _reference_pool: &Pool<BaseAsset, QutoeAsset>,
        _pool: &Pool<BaseAsset, QutoeAsset>,
    ): (u64, u64) {
        (0, 0)
        // TODO
    }
}