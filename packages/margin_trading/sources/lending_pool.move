// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all lending pools.
module margin_trading::lending_pool;

use deepbook::constants;
use std::type_name::{Self, TypeName};
use sui::bag::{Self, Bag};
use sui::dynamic_field;
use sui::vec_set::{Self, VecSet};
use sui::versioned::{Self, Versioned};

// === Errors ===
const EPoolAlreadyExists: u64 = 1;
const EPoolDoesNotExist: u64 = 2;
const EPackageVersionNotEnabled: u64 = 3;
const EVersionNotEnabled: u64 = 4;
const EVersionAlreadyEnabled: u64 = 5;
const ECannotDisableCurrentVersion: u64 = 6;
const ECoinAlreadyWhitelisted: u64 = 7;
const ECoinNotWhitelisted: u64 = 8;

public struct LENDING_POOL has drop {}

// === Structs ===
/// DeepbookAdminCap is used to call admin functions.
public struct MarginAdminCap has key, store {
    id: UID,
}

public struct LendingPoolRegistry has key, store {
    id: UID,
    inner: Versioned,
    allowed_pairs: VecSet<PoolKey>,
    lending_pools: VecSet<TypeName>,
}

public struct PoolKey has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct StableCoinKey has copy, drop, store {}
