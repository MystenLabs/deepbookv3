// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::deep_reference_price {
    use std::{
        type_name::{Self, TypeName},
    };

    use sui::vec_map::{Self, VecMap};

    use deepbook::pool::{Pool, PoolKey, DEEP}; // TODO: DEEP token

    const EIneligiblePool: u64 = 1;

    /// DeepReferencePools is a struct that holds the reference pools for the DEEP token.
    /// DEEP/SUI, DEEP/USDC, DEEP/WETH
    public struct DeepReferencePools has store {
        // Base or quote -> pool_key
        reference_pools: VecMap<TypeName, PoolKey>,
    }

    public(package) fun new(): DeepReferencePools {
        DeepReferencePools {
            reference_pools: vec_map::empty(),
        }
    }

    /// Add a reference pool. Can be performed by the DeepbookAdminCap owner.
    public(package) fun add_reference_pool<BaseAsset, QuoteAsset>(
        deep_reference_price: &mut DeepReferencePools,
        pool: &Pool<BaseAsset, QuoteAsset>,
    ) {
        let (base, quote) = pool.get_base_quote_types();
        let deep_type = type_name::get<DEEP>();

        assert!(base == deep_type || quote == deep_type, EIneligiblePool);

        if (base == deep_type) {
            deep_reference_price.reference_pools.insert(quote, pool.key());
        } else {
            deep_reference_price.reference_pools.insert(base, pool.key());
        }
    }

    /// TODO: comments
    public(package) fun get_conversion_rates<BaseAsset, QuoteAsset>(
        _deep_reference_price: &DeepReferencePools,
        _reference_pool: &Pool<BaseAsset, QuoteAsset>,
        _pool: &Pool<BaseAsset, QuoteAsset>,
    ): (u64, u64) {
        (0, 0)
        // TODO
    }
}
