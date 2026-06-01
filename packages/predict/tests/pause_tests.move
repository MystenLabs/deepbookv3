// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::pause_tests;

use deepbook_predict::{constants, i64, market_oracle, protocol_config, registry};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const NEXT_VERSION: u64 = 2;
const EXPIRY_MS: u64 = 100_000;
const NOW_MS: u64 = 10_000;
const SVI_TIMESTAMP_MS: u64 = 1_000;

#[test]
fun default_allowed_versions_contains_current() {
    let ctx = &mut tx_context::dummy();
    let (registry, admin_cap) = registry::new_for_testing(ctx);
    let allowed = registry.allowed_versions();
    let current = constants::current_version!();
    assert_eq!(allowed.length(), 1);
    assert!(allowed.contains(&current));
    registry::destroy_registry_for_testing(registry);
    destroy(admin_cap);
}

#[test]
fun admin_can_enable_then_disable_a_version() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);

    let next = NEXT_VERSION;
    registry::enable_version(&mut registry, &admin_cap, next);
    assert!(registry.allowed_versions().contains(&next));

    registry::disable_version(&mut registry, &admin_cap, next);
    assert!(!registry.allowed_versions().contains(&next));

    registry::destroy_registry_for_testing(registry);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = registry::ECannotDisableLastVersion)]
fun cannot_disable_last_allowed_version() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);

    registry::disable_version(&mut registry, &admin_cap, constants::current_version!());
    abort 999
}

#[test, expected_failure(abort_code = registry::EVersionAlreadyEnabled)]
fun enable_already_enabled_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);

    registry::enable_version(&mut registry, &admin_cap, constants::current_version!());
    abort 999
}

#[test, expected_failure(abort_code = registry::EVersionNotEnabled)]
fun disable_not_enabled_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);

    registry::disable_version(&mut registry, &admin_cap, NEXT_VERSION);
    abort 999
}

#[test]
fun pause_cap_can_disable_version() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let current = constants::current_version!();

    registry::enable_version(&mut registry, &admin_cap, NEXT_VERSION);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);

    registry::disable_version_pause_cap(&mut registry, &pause_cap, current);
    assert!(!registry.allowed_versions().contains(&current));

    registry::destroy_pause_cap(pause_cap);
    registry::destroy_registry_for_testing(registry);
    destroy(admin_cap);
}

#[test]
fun pause_cap_pause_trading_is_one_way() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);

    assert!(!config.trading_paused());
    registry::pause_trading_pause_cap(&mut config, &registry, &pause_cap);
    assert!(config.trading_paused());

    registry::destroy_pause_cap(pause_cap);
    registry::destroy_registry_for_testing(registry);
    destroy(config);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoked_pause_cap_cannot_act() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    registry::enable_version(&mut registry, &admin_cap, NEXT_VERSION);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);
    let pause_cap_id = object::id(&pause_cap);

    registry::revoke_pause_cap(&mut registry, &admin_cap, pause_cap_id);
    registry::disable_version_pause_cap(&mut registry, &pause_cap, NEXT_VERSION);
    abort 999
}

#[test]
fun sync_market_oracle_copies_registry_allowed_versions() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let current = constants::current_version!();
    let next = NEXT_VERSION;

    // Market mirrors only {current_version!()} at creation.
    assert_eq!(market.allowed_versions().length(), 1);
    assert!(market.allowed_versions().contains(&current));

    // Admin adds NEXT_VERSION; the market's mirror is still stale.
    registry::enable_version(&mut registry, &admin_cap, next);
    assert!(!market.allowed_versions().contains(&next));

    // Sync copies the registry's set verbatim into the market.
    registry::sync_market_oracle_allowed_versions(&registry, &mut market);
    assert_eq!(market.allowed_versions().length(), 2);
    assert!(market.allowed_versions().contains(&current));
    assert!(market.allowed_versions().contains(&next));

    registry::destroy_registry_for_testing(registry);
    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = market_oracle::EPackageVersionDisabled)]
fun synced_market_oracle_blocks_disabled_version() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let config = protocol_config::new_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    // Disable current_version on the registry, then sync the market.
    let current = constants::current_version!();
    registry::enable_version(&mut registry, &admin_cap, NEXT_VERSION);
    registry::disable_version(&mut registry, &admin_cap, current);
    registry::sync_market_oracle_allowed_versions(&registry, &mut market);

    market.update_svi(
        &config,
        &cap,
        market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3),
        SVI_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}
