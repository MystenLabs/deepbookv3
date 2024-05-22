// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::registry {
    use std::type_name::{Self, TypeName};

    use sui::{
        bag::{Self, Bag},
    };

    const EPoolAlreadyExists: u64 = 1;

    public struct REGISTRY has drop {}

    /// DeepbookAdminCap is used to call admin functions.
    public struct DeepbookAdminCap has key, store {
        id: UID,
    }

    public struct Registry has key, store {
        id: UID,
        pools: Bag,
    }

    public struct PoolKey has copy, drop, store {
        base: TypeName,
        quote: TypeName,
    }

    /// Register a new pool in the registry.
    /// Asserts if (Base, Quote) pool already exists or (Quote, Base) pool already exists.
    public(package) fun register_pool<BaseAsset, QuoteAsset>(
        self: &mut Registry,
    ) {
        let key = PoolKey {
            base: type_name::get<QuoteAsset>(),
            quote: type_name::get<BaseAsset>(),
        };
        assert!(!self.pools.contains(key), EPoolAlreadyExists);

        let key = PoolKey {
            base: type_name::get<BaseAsset>(),
            quote: type_name::get<QuoteAsset>(),
        };
        assert!(!self.pools.contains(key), EPoolAlreadyExists);

        self.pools.add(key, true);
    }

    fun init(_: REGISTRY, ctx: &mut TxContext) {
        let registry = Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
        };
        transfer::share_object(registry);
        let admin = DeepbookAdminCap {
            id: object::new(ctx),
        };
        transfer::public_transfer(admin, ctx.sender());
    }

    #[test_only]
    public fun test_registry(ctx: &mut TxContext): Registry {
        Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
        }
    }
}
