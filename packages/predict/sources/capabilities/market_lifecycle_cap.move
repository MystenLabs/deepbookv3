// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market lifecycle capability. Authorizes market lifecycle operations without
/// granting any oracle write authority. `Registry` owns the allowlist of valid
/// lifecycle caps and the admin mint/revoke entrypoints; this module owns the cap
/// object and the transaction-local proof consumed by cross-module lifecycle
/// actions.
module deepbook_predict::market_lifecycle_cap;

/// Capability authorized for privileged market lifecycle operations.
public struct MarketLifecycleCap has key, store {
    id: UID,
}

/// Transaction-local proof that a `MarketLifecycleCap` was valid in the
/// registry allowlist when the proof was created. It has no abilities, so the
/// lifecycle action that accepts it must consume it in the same transaction.
public struct MarketLifecycleProof {}

/// Return the lifecycle cap object ID.
public fun id(cap: &MarketLifecycleCap): ID {
    cap.id.to_inner()
}

/// Destroy a `MarketLifecycleCap` the holder no longer needs.
public fun destroy(cap: MarketLifecycleCap) {
    let MarketLifecycleCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Construct a cap. Allow-listing is `registry::mint_lifecycle_cap`'s job.
public(package) fun new(ctx: &mut TxContext): MarketLifecycleCap {
    MarketLifecycleCap { id: object::new(ctx) }
}

/// Construct a transaction-local lifecycle proof after the caller validates the
/// cap against the authoritative allowlist.
public(package) fun new_proof(_cap: &MarketLifecycleCap): MarketLifecycleProof {
    MarketLifecycleProof {}
}

/// Consume a lifecycle proof.
public(package) fun destroy_proof(proof: MarketLifecycleProof) {
    let MarketLifecycleProof {} = proof;
}
