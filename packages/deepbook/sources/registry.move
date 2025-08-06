// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all created pools.
module deepbook::registry;

use deepbook::constants;
use std::type_name::{Self, TypeName};
use sui::{bag::{Self, Bag}, dynamic_field, vec_set::{Self, VecSet}, versioned::{Self, Versioned}};

// === Errors ===
const EPoolAlreadyExists: u64 = 1;
const EPoolDoesNotExist: u64 = 2;
const EPackageVersionNotEnabled: u64 = 3;
const EVersionNotEnabled: u64 = 4;
const EVersionAlreadyEnabled: u64 = 5;
const ECannotDisableCurrentVersion: u64 = 6;
const ECoinAlreadyWhitelisted: u64 = 7;
const ECoinNotWhitelisted: u64 = 8;

public struct REGISTRY has drop {}

// === Structs ===
/// DeepbookAdminCap is used to call admin functions.
public struct DeepbookAdminCap has key, store {
    id: UID,
}

public struct Registry has key {
    id: UID,
    inner: Versioned,
}

public struct RegistryInner has store {
    allowed_versions: VecSet<u64>,
    pools: Bag,
    treasury_address: address,
}

public struct PoolKey has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct StableCoinKey has copy, drop, store {}

fun init(_: REGISTRY, ctx: &mut TxContext) {
    let registry_inner = RegistryInner {
        allowed_versions: vec_set::singleton(constants::current_version()),
        pools: bag::new(ctx),
        treasury_address: ctx.sender(),
    };
    let registry = Registry {
        id: object::new(ctx),
        inner: versioned::create(
            constants::current_version(),
            registry_inner,
            ctx,
        ),
    };
    transfer::share_object(registry);
    let admin = DeepbookAdminCap { id: object::new(ctx) };
    transfer::public_transfer(admin, ctx.sender());
}

// === Public Admin Functions ===
/// Sets the treasury address where the pool creation fees are sent
/// By default, the treasury address is the publisher of the deepbook package
public fun set_treasury_address(
    self: &mut Registry,
    treasury_address: address,
    _cap: &DeepbookAdminCap,
) {
    let self = self.load_inner_mut();
    self.treasury_address = treasury_address;
}

/// Enables a package version
/// Only Admin can enable a package version
/// This function does not have version restrictions
public fun enable_version(self: &mut Registry, version: u64, _cap: &DeepbookAdminCap) {
    let self: &mut RegistryInner = self.inner.load_value_mut();
    assert!(!self.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    self.allowed_versions.insert(version);
}

/// Disables a package version
/// Only Admin can disable a package version
/// This function does not have version restrictions
public fun disable_version(self: &mut Registry, version: u64, _cap: &DeepbookAdminCap) {
    let self: &mut RegistryInner = self.inner.load_value_mut();
    assert!(version != constants::current_version(), ECannotDisableCurrentVersion);
    assert!(self.allowed_versions.contains(&version), EVersionNotEnabled);
    self.allowed_versions.remove(&version);
}

/// Adds a stablecoin to the whitelist
/// Only Admin can add stablecoin
public fun add_stablecoin<StableCoin>(self: &mut Registry, _cap: &DeepbookAdminCap) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let stable_type = type_name::get<StableCoin>();
    if (
        !dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        )
    ) {
        dynamic_field::add(
            &mut self.id,
            StableCoinKey {},
            vec_set::singleton(stable_type),
        );
    } else {
        let stable_coins: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
            &mut self.id,
            StableCoinKey {},
        );
        assert!(!stable_coins.contains(&stable_type), ECoinAlreadyWhitelisted);
        stable_coins.insert(stable_type);
    };
}

/// Removes a stablecoin from the whitelist
/// Only Admin can remove stablecoin
public fun remove_stablecoin<StableCoin>(self: &mut Registry, _cap: &DeepbookAdminCap) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let stable_type = type_name::get<StableCoin>();
    assert!(
        dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        ),
        ECoinNotWhitelisted,
    );
    let stable_coins: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
        &mut self.id,
        StableCoinKey {},
    );
    assert!(stable_coins.contains(&stable_type), ECoinNotWhitelisted);
    stable_coins.remove(&stable_type);
}

/// Returns whether the given coin is whitelisted
public fun is_stablecoin(self: &Registry, stable_type: TypeName): bool {
    let _: &RegistryInner = self.load_inner();
    if (
        !dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        )
    ) {
        false
    } else {
        let stable_coins: &VecSet<TypeName> = dynamic_field::borrow(
            &self.id,
            StableCoinKey {},
        );

        stable_coins.contains(&stable_type)
    }
}

// === Public-Package Functions ===
public(package) fun load_inner_mut(self: &mut Registry): &mut RegistryInner {
    let inner: &mut RegistryInner = self.inner.load_value_mut();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionNotEnabled);

    inner
}

/// Register a new pool in the registry.
/// Asserts if (Base, Quote) pool already exists or
/// (Quote, Base) pool already exists.
public(package) fun register_pool<BaseAsset, QuoteAsset>(self: &mut Registry, pool_id: ID) {
    let self = self.load_inner_mut();
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
public(package) fun unregister_pool<BaseAsset, QuoteAsset>(self: &mut Registry) {
    let self = self.load_inner_mut();
    let key = PoolKey {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(self.pools.contains(key), EPoolDoesNotExist);
    self.pools.remove<PoolKey, ID>(key);
}

public(package) fun load_inner(self: &Registry): &RegistryInner {
    let inner: &RegistryInner = self.inner.load_value();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionNotEnabled);

    inner
}

/// Get the pool id for the given base and quote assets.
public(package) fun get_pool_id<BaseAsset, QuoteAsset>(self: &Registry): ID {
    let self = self.load_inner();
    let key = PoolKey {
        base: type_name::get<BaseAsset>(),
        quote: type_name::get<QuoteAsset>(),
    };
    assert!(self.pools.contains(key), EPoolDoesNotExist);

    *self.pools.borrow<PoolKey, ID>(key)
}

/// Get the treasury address
public(package) fun treasury_address(self: &Registry): address {
    let self = self.load_inner();
    self.treasury_address
}

public(package) fun allowed_versions(self: &Registry): VecSet<u64> {
    let self = self.load_inner();

    self.allowed_versions
}

// === Test Functions ===
#[test_only]
public fun test_registry(ctx: &mut TxContext): ID {
    let registry_inner = RegistryInner {
        allowed_versions: vec_set::singleton(constants::current_version()),
        pools: bag::new(ctx),
        treasury_address: ctx.sender(),
    };
    let registry = Registry {
        id: object::new(ctx),
        inner: versioned::create(
            constants::current_version(),
            registry_inner,
            ctx,
        ),
    };
    let id = object::id(&registry);
    transfer::share_object(registry);

    id
}

#[test_only]
public fun get_admin_cap_for_testing(ctx: &mut TxContext): DeepbookAdminCap {
    DeepbookAdminCap { id: object::new(ctx) }
}
