// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns the Sessions package version floor, the DeepBook pools session-key spot
/// trades may use, and the authority that maintains both.
module deepbook_sessions::session_config;

use sui::{dynamic_field as df, event, vec_set::{Self, VecSet}};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;

// === Errors ===

const EPackageVersionDisabled: u64 = 0;
const EVersionWatermarkNotAdvanced: u64 = 1;
const EPoolNotAllowed: u64 = 2;

// === Constants ===

/// Every package upgrade must advance this compiled-in version.
macro fun current_version(): u64 { 4 }

// === Structs ===

/// Shared package-wide version floor used by session grant and trading entrypoints.
public struct SessionsConfig has key {
    id: UID,
    version_watermark: u64,
}

/// Root authority for advancing the Sessions package version floor and
/// maintaining the spot pool allowlist.
public struct SessionsAdminCap has key, store {
    id: UID,
}

/// Dynamic-field key on `SessionsConfig` for the spot pool allowlist, a
/// `VecSet<ID>` of DeepBook pool IDs. `SessionsConfig` was published without
/// it, so it is attached by the first `admin_allow_pool`.
public struct AllowedPoolsKey() has copy, drop, store;

/// A DeepBook pool was added to the session spot allowlist.
public struct SessionPoolAllowed has copy, drop {
    pool_id: ID,
}

/// A DeepBook pool was removed from the session spot allowlist.
public struct SessionPoolDisallowed has copy, drop {
    pool_id: ID,
}

/// Create the shared version config and transfer its administration capability to the publisher.
fun init(ctx: &mut TxContext) {
    let (_, admin_cap) = create_and_share(ctx);
    transfer::public_transfer(admin_cap, ctx.sender());
}

// === Public Functions ===

/// Return the config object ID for external PTB construction.
public fun id(config: &SessionsConfig): ID {
    config.id.to_inner()
}

/// Return the minimum Sessions package version accepted by gated entrypoints.
public fun version_watermark(config: &SessionsConfig): u64 {
    config.version_watermark
}

/// Return the DeepBook pool IDs session-key spot orders may trade on, in the
/// order they were allowed, for SDK and devInspect reads. Empty until the first
/// `admin_allow_pool`.
public fun allowed_pools(config: &SessionsConfig): vector<ID> {
    if (!config.id.exists_(AllowedPoolsKey())) return vector[];
    *config.id.borrow<_, VecSet<ID>>(AllowedPoolsKey()).keys()
}

/// Advance the version floor to this package's compiled-in version.
/// This is ungated so an upgraded package can retire older versions, and it cannot accept a caller-selected target.
public fun bump_version_watermark(config: &mut SessionsConfig, _admin_cap: &SessionsAdminCap) {
    let version = current_version!();
    assert!(version > config.version_watermark, EVersionWatermarkNotAdvanced);
    config.version_watermark = version;
}

/// Let session-key spot orders trade on `pool_id`. Aborts through `vec_set` if
/// the pool is already allowed.
public fun admin_allow_pool(
    config: &mut SessionsConfig,
    _admin_cap: &SessionsAdminCap,
    pool_id: ID,
) {
    config.assert_version();
    if (!config.id.exists_(AllowedPoolsKey())) {
        config.id.add(AllowedPoolsKey(), vec_set::empty<ID>());
    };
    config.id.borrow_mut<_, VecSet<ID>>(AllowedPoolsKey()).insert(pool_id);
    event::emit(SessionPoolAllowed { pool_id });
}

/// Stop session-key spot orders on `pool_id`. Aborts `EPoolNotAllowed` if the
/// pool is not allowed, so a mistyped ID cannot pass for a removal. Session
/// cancels and settled withdrawals on the pool keep working.
public fun admin_disallow_pool(
    config: &mut SessionsConfig,
    _admin_cap: &SessionsAdminCap,
    pool_id: ID,
) {
    config.assert_version();
    config.assert_pool_allowed(pool_id);
    config.id.borrow_mut<_, VecSet<ID>>(AllowedPoolsKey()).remove(&pool_id);
    event::emit(SessionPoolDisallowed { pool_id });
}

// === Public-Package Functions ===

/// Abort when the executing package version is below the configured floor.
public(package) fun assert_version(config: &SessionsConfig) {
    assert!(current_version!() >= config.version_watermark, EPackageVersionDisabled);
}

/// Abort unless `pool_id` is on the spot pool allowlist. An allowlist that was
/// never attached allows no pool.
public(package) fun assert_pool_allowed(config: &SessionsConfig, pool_id: ID) {
    assert!(
        config.id.exists_(AllowedPoolsKey())
            && config.id.borrow<_, VecSet<ID>>(AllowedPoolsKey()).contains(&pool_id),
        EPoolNotAllowed,
    );
}

// === Private Functions ===

fun create_and_share(ctx: &mut TxContext): (ID, SessionsAdminCap) {
    let config = SessionsConfig {
        id: object::new(ctx),
        version_watermark: current_version!(),
    };
    let id = config.id();
    transfer::share_object(config);
    (id, SessionsAdminCap { id: object::new(ctx) })
}

// === Test-Only Functions ===

#[test_only]
/// Create test-only package state and return the config ID with its administration capability.
public fun init_for_testing(ctx: &mut TxContext): (ID, SessionsAdminCap) {
    create_and_share(ctx)
}

#[test_only]
/// Emulate a watermark written by another package version, which one compiled test package cannot produce.
public fun set_version_watermark_for_testing(config: &mut SessionsConfig, version_watermark: u64) {
    config.version_watermark = version_watermark;
}
