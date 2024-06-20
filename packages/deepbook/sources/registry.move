// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all created pools.
module deepbook::registry {
    // === Imports ===
    use std::type_name::{Self, TypeName};
    use sui::{
        bag::{Self, Bag},
    };

    // === Errors ===
    const EPoolAlreadyExists: u64 = 1;
    const EPoolDoesNotExist: u64 = 2;

    public struct REGISTRY has drop {}

    // === Structs ===
    /// DeepbookAdminCap is used to call admin functions.
    public struct DeepbookAdminCap has key, store {
        id: UID,
    }

    public struct Registry has key, store {
        id: UID,
        pools: Bag,
        treasury_address: address,
    }

    public struct PoolKey has copy, drop, store {
        base: TypeName,
        quote: TypeName,
    }

    fun init(_: REGISTRY, ctx: &mut TxContext) {
        let registry = Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
            treasury_address: ctx.sender(),
        };
        transfer::share_object(registry);
        let admin = DeepbookAdminCap {
            id: object::new(ctx),
        };
        transfer::public_transfer(admin, ctx.sender());
    }

    // === Admin Functions ===
    public fun set_treasury_address(
        self: &mut Registry,
        treasury_address: address,
        _cap: &DeepbookAdminCap,
    ) {
        self.treasury_address = treasury_address;
    }

    // === Public-Package Functions ===
    /// Register a new pool in the registry.
    /// Asserts if (Base, Quote) pool already exists or (Quote, Base) pool already exists.
    public(package) fun register_pool<BaseAsset, QuoteAsset>(
        self: &mut Registry,
        pool_id: ID,
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

        self.pools.add(key, pool_id);
    }

    /// Only admin can call this function
    public(package) fun unregister_pool<BaseAsset, QuoteAsset>(
        self: &mut Registry,
    ) {
        let key = PoolKey {
            base: type_name::get<BaseAsset>(),
            quote: type_name::get<QuoteAsset>(),
        };
        assert!(self.pools.contains(key), EPoolDoesNotExist);
        self.pools.remove<PoolKey, ID>(key);
    }

    /// Get the pool id for the given base and quote assets.
    public(package) fun get_pool_id<BaseAsset, QuoteAsset>(
        self: &Registry
    ): ID {
        let key = PoolKey {
            base: type_name::get<BaseAsset>(),
            quote: type_name::get<QuoteAsset>(),
        };
        assert!(self.pools.contains(key), EPoolDoesNotExist);

        *self.pools.borrow<PoolKey, ID>(key)
    }

    /// Get the treasury address
    public(package) fun treasury_address(self: &Registry): address {
        self.treasury_address
    }

    // === Test Functions ===
    #[test_only]
    public fun test_registry(ctx: &mut TxContext): ID {
        let registry = Registry {
            id: object::new(ctx),
            pools: bag::new(ctx),
            treasury_address: ctx.sender(),
        };
        let id = object::id(&registry);
        transfer::share_object(registry);

        id
    }

    #[test_only]
    public fun get_admin_cap_for_testing(ctx: &mut TxContext): DeepbookAdminCap {
        DeepbookAdminCap {
            id: object::new(ctx),
        }
    }
}
