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
    let config = protocol_config::new_for_testing(ctx);
    let allowed = config.allowed_versions();
    let current = constants::current_version!();
    assert_eq!(allowed.length(), 1);
    assert!(allowed.contains(&current));
    destroy(config);
}

#[test]
fun admin_can_enable_then_disable_a_version() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);

    let next = NEXT_VERSION;
    registry::enable_version(&mut config, &admin_cap, next);
    assert!(config.allowed_versions().contains(&next));

    registry::disable_version(&mut config, &admin_cap, next);
    assert!(!config.allowed_versions().contains(&next));

    destroy(config);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = protocol_config::ECannotDisableLastVersion)]
fun cannot_disable_last_allowed_version() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);

    registry::disable_version(&mut config, &admin_cap, constants::current_version!());
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EVersionAlreadyEnabled)]
fun enable_already_enabled_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);

    registry::enable_version(&mut config, &admin_cap, constants::current_version!());
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EVersionNotEnabled)]
fun disable_not_enabled_version_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);

    registry::disable_version(&mut config, &admin_cap, NEXT_VERSION);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun disabled_version_blocks_admin_setter() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);

    // Add NEXT_VERSION so we can disable current_version!() without leaving an empty set.
    registry::enable_version(&mut config, &admin_cap, NEXT_VERSION);
    registry::disable_version(&mut config, &admin_cap, constants::current_version!());

    registry::set_base_fee(&mut config, &admin_cap, 1);
    abort 999
}

#[test]
fun pause_cap_can_disable_version() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let current = constants::current_version!();

    registry::enable_version(&mut config, &admin_cap, NEXT_VERSION);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);

    registry::disable_version_pause_cap(&registry, &mut config, current, &pause_cap);
    assert!(!config.allowed_versions().contains(&current));

    registry::destroy_pause_cap(pause_cap);
    registry::destroy_registry_for_testing(registry);
    destroy(config);
    destroy(admin_cap);
}

#[test]
fun pause_cap_pause_trading_is_one_way() {
    let ctx = &mut tx_context::dummy();
    let (mut registry, admin_cap) = registry::new_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);

    assert!(!config.trading_paused());
    registry::pause_trading_pause_cap(&registry, &mut config, &pause_cap);
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
    let mut config = protocol_config::new_for_testing(ctx);
    registry::enable_version(&mut config, &admin_cap, NEXT_VERSION);
    let pause_cap = registry::mint_pause_cap(&mut registry, &admin_cap, ctx);
    let pause_cap_id = object::id(&pause_cap);

    registry::revoke_pause_cap(&mut registry, &admin_cap, pause_cap_id);
    registry::disable_version_pause_cap(
        &registry,
        &mut config,
        NEXT_VERSION,
        &pause_cap,
    );
    abort 999
}

#[test, expected_failure(abort_code = market_oracle::EPackageVersionDisabled)]
fun synced_market_oracle_blocks_disabled_version() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    let admin_cap = registry::create_admin_cap_for_testing(ctx);
    let cap = registry::create_market_oracle_cap(&admin_cap, ctx);
    let mut market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(NOW_MS);

    // Disable current_version, then sync the market to propagate the change.
    let current = constants::current_version!();
    registry::enable_version(&mut config, &admin_cap, NEXT_VERSION);
    registry::disable_version(&mut config, &admin_cap, current);
    market.update_allowed_versions_permissionless(&config);

    market.update_svi(
        &config,
        &cap,
        market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3),
        SVI_TIMESTAMP_MS,
        &clock,
    );
    abort 999
}
