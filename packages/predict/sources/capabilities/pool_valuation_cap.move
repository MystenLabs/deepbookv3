// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable authority to start the full-pool valuation (the flush) without granting market-creation, oracle-write, or root-admin power.
/// `Registry` owns the allowlist and converts a valid capability into the ability-less proof `plp::start_pool_valuation` consumes.
module deepbook_predict::pool_valuation_cap;

/// Capability authorized to start a pool valuation while its ID remains allowlisted.
public struct PoolValuationCap has key, store {
    id: UID,
}

/// Transaction-local proof that a pool-valuation capability was allowlisted when checked.
/// With no abilities, it must be consumed by `plp::start_pool_valuation` in the same transaction.
public struct PoolValuationProof {}

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

/// Constructs a transaction-local proof after the caller validates the capability against the registry allowlist.
public(package) fun new_proof(_cap: &PoolValuationCap): PoolValuationProof {
    PoolValuationProof {}
}

/// Consume a pool-valuation proof.
public(package) fun destroy_proof(proof: PoolValuationProof) {
    let PoolValuationProof {} = proof;
}
