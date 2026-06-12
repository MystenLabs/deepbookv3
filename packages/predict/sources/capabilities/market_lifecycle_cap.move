// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market lifecycle capability. Authorizes market lifecycle operations —
/// `registry::create_expiry_market` and `plp::compact_storage` — without
/// granting any oracle write authority. `PoolVault` owns the allowlist of
/// valid lifecycle caps and the admin mint/revoke entrypoints; this module
/// owns only the cap object itself.
module deepbook_predict::market_lifecycle_cap;

/// Capability authorized for market lifecycle operations. Independent of
/// `MarketOracleWriterCap`: holding one grants nothing of the other.
public struct MarketLifecycleCap has key, store {
    id: UID,
}

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

/// Construct a cap. Allow-listing is `plp::mint_lifecycle_cap`'s job.
public(package) fun new(ctx: &mut TxContext): MarketLifecycleCap {
    MarketLifecycleCap { id: object::new(ctx) }
}
