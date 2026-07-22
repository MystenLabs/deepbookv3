// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable authority for market creation and coordinated pool valuation without granting oracle-write or root-admin power.
/// `Registry` owns the allowlist and converts a valid capability into the ability-less proof consumed by cross-module lifecycle flows.
module deepbook_predict::market_lifecycle_cap;

/// Capability authorized for privileged market lifecycle operations while its ID remains allowlisted.
public struct MarketLifecycleCap has key, store {
    id: UID,
}

/// Transaction-local proof that a lifecycle capability was allowlisted when checked.
/// With no abilities, it must be consumed by the authorized lifecycle flow in the same transaction.
public struct MarketLifecycleProof {}

/// Returns the capability identity used by the registry allowlist.
public fun id(cap: &MarketLifecycleCap): ID {
    cap.id.to_inner()
}

/// Destroy a `MarketLifecycleCap` the holder no longer needs.
public fun destroy(cap: MarketLifecycleCap) {
    let MarketLifecycleCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Constructs a capability for the registry to allowlist atomically.
public(package) fun new(ctx: &mut TxContext): MarketLifecycleCap {
    MarketLifecycleCap { id: object::new(ctx) }
}

/// Constructs a transaction-local proof after the caller validates the capability against the registry allowlist.
public(package) fun new_proof(_cap: &MarketLifecycleCap): MarketLifecycleProof {
    MarketLifecycleProof {}
}

/// Consume a lifecycle proof.
public(package) fun destroy_proof(proof: MarketLifecycleProof) {
    let MarketLifecycleProof {} = proof;
}
