// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines revocable emergency authority that can engage global trading or per-market mint pauses but cannot unpause.
/// `Registry` owns the allowlist and all state transitions authorized by this capability.
module deepbook_predict::pause_cap;

/// Capability authorized for one-way emergency pauses while its ID remains allowlisted.
public struct PauseCap has key, store {
    id: UID,
}

/// Returns the capability identity used by the registry allowlist.
public fun id(cap: &PauseCap): ID {
    cap.id.to_inner()
}

/// Destroy a `PauseCap` the holder no longer needs.
public fun destroy(cap: PauseCap) {
    let PauseCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Constructs a capability for the registry to allowlist atomically.
public(package) fun new(ctx: &mut TxContext): PauseCap {
    PauseCap { id: object::new(ctx) }
}
