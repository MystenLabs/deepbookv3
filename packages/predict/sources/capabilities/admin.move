// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines the root capability used by state-owning modules to authorize Predict
/// governance operations. Possession is the sole authority; the package exposes
/// no on-chain revocation or rotation mechanism for this capability.
module deepbook_predict::admin;

/// Root authority for protocol administration.
public struct AdminCap has key, store {
    id: UID,
}

/// Returns the capability identity for administration tooling and object discovery.
public fun id(cap: &AdminCap): ID {
    cap.id.to_inner()
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}
