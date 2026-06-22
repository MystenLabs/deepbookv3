// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Emergency pause capability. `Registry` owns the allowlist of valid pause
/// caps and the admin mint/revoke entrypoints; this module owns only the cap
/// object itself.
module deepbook_predict::pause_cap;

/// Capability for emergency pause operations. Admin can mint these for
/// trusted operators; holders can disable versions, pause global trading,
/// and pause per-market minting. Cannot unpause anything.
public struct PauseCap has key, store {
    id: UID,
}

/// Return the pause cap object ID.
public fun id(cap: &PauseCap): ID {
    cap.id.to_inner()
}

/// Destroy a `PauseCap` the holder no longer needs.
public fun destroy(cap: PauseCap) {
    let PauseCap { id } = cap;
    id.delete();
}

// === Public-Package Functions ===

/// Construct a cap. Allow-listing is `registry::mint_pause_cap`'s job.
public(package) fun new(ctx: &mut TxContext): PauseCap {
    PauseCap { id: object::new(ctx) }
}
