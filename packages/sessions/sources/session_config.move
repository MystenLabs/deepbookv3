// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns the Sessions package version floor and the authority that advances it.
module deepbook_sessions::session_config;

// === Errors ===

const EPackageVersionDisabled: u64 = 0;
const EVersionWatermarkNotAdvanced: u64 = 1;

// === Constants ===

/// Every package upgrade must advance this compiled-in version.
macro fun current_version(): u64 { 1 }

// === Structs ===

/// Shared package-wide version floor used by session grant and trading entrypoints.
public struct SessionsConfig has key {
    id: UID,
    version_watermark: u64,
}

/// Root authority for advancing the Sessions package version floor.
public struct SessionsAdminCap has key, store {
    id: UID,
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

/// Advance the version floor to this package's compiled-in version.
/// This is ungated so an upgraded package can retire older versions, and it cannot accept a caller-selected target.
public fun bump_version_watermark(config: &mut SessionsConfig, _admin_cap: &SessionsAdminCap) {
    let version = current_version!();
    assert!(version > config.version_watermark, EVersionWatermarkNotAdvanced);
    config.version_watermark = version;
}

// === Public-Package Functions ===

/// Abort when the executing package version is below the configured floor.
public(package) fun assert_version(config: &SessionsConfig) {
    assert!(current_version!() >= config.version_watermark, EPackageVersionDisabled);
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
