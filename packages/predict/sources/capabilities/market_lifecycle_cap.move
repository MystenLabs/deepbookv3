// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable authority for market creation without granting pool-valuation, oracle-write, or root-admin power.
/// `Registry` owns the allowlist and the creation entrypoint this capability gates.
module deepbook_predict::market_lifecycle_cap;

/// Capability authorized for privileged market lifecycle operations while its ID remains allowlisted.
public struct MarketLifecycleCap has key, store {
    id: UID,
}

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
