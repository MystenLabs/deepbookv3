// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::registry {
    use std::type_name::{Self, TypeName};

    use sui::{
        bag::{Self, Bag},
    };

    const EPoolAlreadyExists: u64 = 1;

    public struct Registry has key {
        id: UID,
        pools: Bag,
    }

    public struct PoolKey has copy, drop, store {
        base: TypeName,
        quote: TypeName,
    }

    public(package) fun register_pool<BaseAsset, QuoteAsset>(
        self: &mut Registry,
    ) {
        let key = PoolKey {
            base: type_name::get<BaseAsset>(),
            quote: type_name::get<QuoteAsset>(),
        };
        assert!(!self.pools.contains(key), EPoolAlreadyExists);

        self.pools.add(key, true);
    }

    public(package) fun create_and_share(ctx: &mut TxContext) {
        let registry = Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
        };

        transfer::share_object(registry);
    }

    #[test_only]
    public fun test_registry(ctx: &mut TxContext): Registry {
        Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
        }
    }
}