// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for the incentive deposit/valuation guards, driven
/// through the public registry deposit entrypoints (`deposit_sui_incentive`)
/// and the `plp::supply` incentive-valuation path: `incentive`'s deposit
/// guards, its feed-binding check, `pyth_source`'s zero-spot valuation guard,
/// and the registry's unconfigured-asset guard.
#[test_only]
module deepbook_predict::incentive_tests;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    incentive,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    coin,
    coin_registry,
    sui::SUI,
    test_scenario::{Self as test, Scenario, return_shared},
    test_utils
};

/// SUI coin decimals, as the registry would read them from `Currency<SUI>`.
const SUI_DECIMALS: u8 = 9;
/// 1 SUI (9 decimals) — an arbitrary nonzero incentive deposit.
const INCENTIVE_DEPOSIT: u64 = 1_000_000_000;
/// One day in ms; well inside `constants::max_incentive_stream_ms!()` (1 year).
const STREAM_DURATION_MS: u64 = 86_400_000;
/// A second registered Lazer feed, distinct from `test_constants::pyth_feed_id()`.
const OTHER_FEED_ID: u32 = 2;
/// 1 DUSDC — an arbitrary nonzero follow-on supply payment.
const FOLLOW_ON_SUPPLY: u64 = 1_000_000;

// === incentive::EZeroDeposit ===

#[test, expected_failure(abort_code = incentive::EZeroDeposit)]
fun deposit_zero_coin_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();

    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::zero<SUI>(scenario.ctx()),
        STREAM_DURATION_MS,
        &clock,
    );
    abort 999
}

// === incentive::EZeroStreamDuration ===

#[test, expected_failure(abort_code = incentive::EZeroStreamDuration)]
fun deposit_zero_duration_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();

    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::mint_for_testing<SUI>(INCENTIVE_DEPOSIT, scenario.ctx()),
        0,
        &clock,
    );
    abort 999
}

// === incentive::EStreamDurationTooLong ===

#[test, expected_failure(abort_code = incentive::EStreamDurationTooLong)]
fun deposit_duration_over_max_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();

    // One ms past the `constants::max_incentive_stream_ms!()` vesting bound.
    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::mint_for_testing<SUI>(INCENTIVE_DEPOSIT, scenario.ctx()),
        constants::max_incentive_stream_ms!() + 1,
        &clock,
    );
    abort 999
}

// === incentive::EFeedMismatch ===

#[test, expected_failure(abort_code = incentive::EFeedMismatch)]
fun supply_with_wrong_feed_incentive_source_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock);

    // A second registered feed: its source is real and admin-created, but it
    // is not the feed the SUI incentive was bound to at deposit time.
    let mut registry = scenario.take_shared<Registry>();
    let other_pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        OTHER_FEED_ID,
        test_constants::default_tick_size(),
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(test_constants::admin());

    let other_pyth = scenario.take_shared_by_id<PythSource>(other_pyth_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let _plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(FOLLOW_ON_SUPPLY, scenario.ctx()),
        &other_pyth,
        &other_pyth,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === pyth_source::EZeroSpot (the `value_in_dusdc` site) ===

#[test, expected_failure(abort_code = pyth_source::EZeroSpot)]
fun supply_with_zero_spot_incentive_source_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock);

    // Zero spot with FRESH timestamps: the freshness gate passes and the
    // valuation hits `value_in_dusdc`'s zero-spot guard, not EPythSpotStale.
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(0, live_ts, live_ts);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let _plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(FOLLOW_ON_SUPPLY, scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === registry::EIncentiveAssetNotConfigured ===

#[test, expected_failure(abort_code = registry::EIncentiveAssetNotConfigured)]
fun deposit_unconfigured_incentive_asset_aborts() {
    // `set_incentive_asset<SUI>` was never called, so the registry has no
    // oracle binding for SUI and must reject the deposit.
    let (mut scenario, admin_cap, clock) = begin_pool();
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();

    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::mint_for_testing<SUI>(INCENTIVE_DEPOSIT, scenario.ctx()),
        STREAM_DURATION_MS,
        &clock,
    );
    abort 999
}

// === Private bring-up helpers (these flows need the AdminCap for
// `set_incentive_asset` / `deposit_sui_incentive`, which the shared flow
// fixture holds privately) ===

/// Stand up the production-mirroring shared objects (PLP vault, registry,
/// protocol config) with no PLP supplied, plus the admin cap and a clock at
/// `now_ms`.
fun begin_pool(): (Scenario, AdminCap, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    (scenario, admin_cap, clock)
}

/// Register the default Pyth feed and create its shared source.
fun create_default_pyth(scenario: &mut Scenario, admin_cap: &AdminCap): ID {
    let mut registry = scenario.take_shared<Registry>();
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
    pyth_id
}

/// Bootstrap the pool with the default initial PLP supply through the real
/// `supply` path (1:1 mint), seeding the Pyth source with a fresh spot first.
/// Required before any incentive deposit (`plp::ENoPlpHolders`).
fun bootstrap_supply(scenario: &mut Scenario, clock: &Clock, pyth_id: ID) {
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(test_constants::default_creation_spot(), live_ts, live_ts);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let plp_coin = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(test_constants::default_initial_supply(), scenario.ctx()),
        &pyth,
        &pyth,
        clock,
        scenario.ctx(),
    );
    destroy(plp_coin);
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());
}

/// Bind SUI as an incentive asset to the default feed through the real admin
/// path. `Currency<SUI>` has no production test seam, so it is built from the
/// framework's test-only one-time-witness + currency initializer helpers.
fun configure_sui_incentive(scenario: &mut Scenario, admin_cap: &AdminCap) {
    let mut registry = scenario.take_shared<Registry>();
    let otw = test_utils::create_one_time_witness<SUI>();
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        SUI_DECIMALS,
        b"SUI".to_string(),
        b"Sui".to_string(),
        b"".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let currency = coin_registry::unwrap_for_testing(initializer);
    registry::set_incentive_asset<SUI>(
        &mut registry,
        admin_cap,
        &currency,
        test_constants::pyth_feed_id(),
    );
    destroy(currency);
    destroy(treasury_cap);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}

/// Deposit `INCENTIVE_DEPOSIT` SUI as an admin incentive vesting over
/// `STREAM_DURATION_MS` (bound to the default feed).
fun fund_sui_incentive(scenario: &mut Scenario, admin_cap: &AdminCap, clock: &Clock) {
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        admin_cap,
        coin::mint_for_testing<SUI>(INCENTIVE_DEPOSIT, scenario.ctx()),
        STREAM_DURATION_MS,
        clock,
    );
    return_shared(vault);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}
