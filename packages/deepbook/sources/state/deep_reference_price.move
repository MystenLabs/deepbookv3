// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The deep_reference_price module provides the functionality to add DEEP reference pools
/// and calculate the conversion rates between the DEEP token and any other token pair.
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
            reference_pools: vector[],
        }
    }

    /// Add a reference pool.
    public(package) fun add_reference_pool<DEEP, QuoteAsset>(
        self: &mut DeepReferencePools,
        pool: &Pool<DEEP, QuoteAsset>,
    ) {
        let (base, quote) = pool.get_base_quote_types();
        let deep_type = type_name::get<DEEP>();

        assert!(base == deep_type || quote == deep_type, EIneligiblePool);
        
        self.reference_pools.push_back(pool.key());
    }

    /// Calculate the conversion rate between the DEEP token and the base and quote assets of a pool.
    /// Case 1: base or quote in pool is already DEEP
    /// Case 2: base and quote in pool is not DEEP
    public(package) fun get_conversion_rates<BaseAsset, QuoteAsset, DEEPBaseAsset, DEEPQuoteAsset>(
        self: &DeepReferencePools,
        pool: &Pool<BaseAsset, QuoteAsset>,
        deep_pool: &Pool<DEEPBaseAsset, DEEPQuoteAsset>,
    ): (u64, u64) {
        let (base_type, quote_type) = pool.get_base_quote_types();
        let deep_type = type_name::get<DEEP>().into_string();
        let pool_price = pool.mid_price();
        if (base_type == deep_type) {
            return (1, pool_price)
        };
        if (quote_type == deep_type) {
            return (pool_price, 1)
        };

        let (deep_base_type, deep_quote_type) = deep_pool.get_base_quote_types();
        assert!(self.reference_pools.contains(&deep_pool.key()), EIneligiblePool);
        assert!(base_type == deep_base_type || base_type == deep_quote_type, EIneligiblePool);
        assert!(quote_type == deep_base_type || quote_type == deep_quote_type, EIneligiblePool);

        let deep_price = deep_pool.mid_price();
        if (base_type == deep_base_type) {
            return (math::div(1, deep_price), math::div(deep_price, pool_price))
        } else if (base_type == deep_quote_type) {
            return (deep_price, math::div(pool_price, deep_price))
        } else if (quote_type == deep_base_type) {
            return (math::div(deep_price, pool_price), math::div(1, deep_price))
        } else {
            return (math::div(pool_price, deep_price), deep_price)
        }
    }
}
