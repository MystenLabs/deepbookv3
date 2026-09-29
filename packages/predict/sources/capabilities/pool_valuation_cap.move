// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable authority to start the full-pool valuation (the flush) without granting market-creation, oracle-write, or root-admin power.
/// `Registry` owns the allowlist and issues the transaction-local proof `plp::start_pool_valuation` consumes.
module deepbook_predict::pool_valuation_cap;

/// Capability authorized to start a pool valuation while its ID remains allowlisted.
public struct PoolValuationCap has key, store {
    id: UID,
}

/// Returns the capability identity used by the registry allowlist.
public fun id(cap: &PoolValuationCap): ID {
    cap.id.to_inner()
}

/// Destroy a `PoolValuationCap` the holder no longer needs.
public fun destroy(cap: PoolValuationCap) {
    let PoolValuationCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Constructs a capability for the registry to allowlist atomically.
public(package) fun new(ctx: &mut TxContext): PoolValuationCap {
    PoolValuationCap { id: object::new(ctx) }
}
