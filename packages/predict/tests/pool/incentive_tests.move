// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for the incentive deposit/valuation guards, driven
/// through the public registry deposit entrypoints (`deposit_sui_incentive`)
/// and the `plp::supply` incentive-valuation path: `incentive`'s deposit
/// guards, its feed-binding check, `pyth_source`'s zero-spot valuation guard,
/// and the registry's unconfigured-asset guard. Also pins the linear-vesting
/// rounding behavior: a compound whose release rounds down to zero still
/// advances `last_compound_ms` (deferring vesting), and the terminal branch
/// releases the full locked remainder by stream end (no loss). Also pins the
/// accepted full-exit re-bootstrap edge: after every holder exits, the next
/// supplier re-bootstraps 1:1 and captures the still-vesting stream remainder.
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
use std::unit_test::{assert_eq, destroy};
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
/// Exactly half the 1e9 deposit: at the stream midpoint the vested release is
/// mul(1_000_000_000, div(43_200_000, 86_400_000)) = mul(1e9, 0.5) = 5e8, and
/// the locked remainder is the other 5e8.
const HALF_STREAM: u64 = 500_000_000;

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
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, STREAM_DURATION_MS);

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
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, STREAM_DURATION_MS);

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

// === Linear-vesting rounding pins (incentive::compound) ===

#[test]
fun zero_rounded_release_advances_window_and_vests_nothing() {
    let (mut scenario, admin_cap, mut clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    // 1 SUI vesting over the maximum 1-year stream, deposited at T0 = now_ms.
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, constants::max_incentive_stream_ms!());

    // First sync 20 ms in. The release fraction floors to zero:
    //   div(20, 31_536_000_000) = floor(20 * 1e9 / 31_536_000_000) = floor(0.63..) = 0
    //   release = mul(1_000_000_000, 0) = 0
    // ...yet compound still advances last_compound_ms to T0 + 20.
    clock.set_for_testing(test_constants::now_ms() + 20);
    let (released, locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, 0);
    assert_eq!(locked, INCENTIVE_DEPOSIT);

    // Second sync 20 ms later. Because the window restarted at T0 + 20, elapsed
    // is again 20 ms (not 40):
    //   div(20, 31_536_000_000 - 20) = 0, release = 0
    // 40 ms have passed since the deposit and nothing has vested — the control
    // test below shows a single 40 ms compound releases 1 unit.
    clock.set_for_testing(test_constants::now_ms() + 40);
    let (released, locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, 0);
    assert_eq!(locked, INCENTIVE_DEPOSIT);

    destroy(admin_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun same_elapsed_in_one_compound_vests_one_unit() {
    let (mut scenario, admin_cap, mut clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, constants::max_incentive_stream_ms!());

    // Control for the zero-release test: the same 40 ms after the deposit, but
    // compounded once instead of twice:
    //   div(40, 31_536_000_000) = floor(40 * 1e9 / 31_536_000_000) = floor(1.26..) = 1
    //   release = mul(1_000_000_000, 1) = floor(1_000_000_000 * 1 / 1e9) = 1
    clock.set_for_testing(test_constants::now_ms() + 40);
    let (released, locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, 1);
    assert_eq!(locked, INCENTIVE_DEPOSIT - 1);

    destroy(admin_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun zero_rounded_deferrals_fully_vest_by_stream_end() {
    let (mut scenario, admin_cap, mut clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, constants::max_incentive_stream_ms!());

    // Two zero-release window restarts (as in the zero-release pin above)...
    clock.set_for_testing(test_constants::now_ms() + 20);
    let (released, _locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, 0);
    clock.set_for_testing(test_constants::now_ms() + 40);
    let (released, _locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, 0);

    // ...then a sync exactly at stream end takes the terminal branch and
    // releases the entire locked remainder: the rounding deferral is
    // self-correcting and no vesting is lost.
    clock.set_for_testing(test_constants::now_ms() + constants::max_incentive_stream_ms!());
    let (released, locked) = supply_and_read_sui_incentive(&mut scenario, &clock, pyth_id);
    assert_eq!(released, INCENTIVE_DEPOSIT);
    assert_eq!(locked, 0);

    destroy(admin_cap);
    destroy(clock);
    scenario.end();
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

// === Full-exit re-bootstrap capture (decision-pinned) ===

/// Decision-pinned (D027, 2026-06-09: PLP supply mechanics stay as-is): after
/// EVERY holder exits, `total_supply` returns to 0 while the locked incentive
/// remainder keeps vesting, and the next supplier re-bootstraps 1:1 (the
/// bootstrap branch checks only the DUSDC side) — capturing the entire
/// orphaned remainder for an arbitrary payment. The exiting holder is paid
/// exactly fairly on the way out; what the re-bootstrapper earns is the
/// not-yet-vested stream — accepted as "the incentive pays whoever is the
/// pool during vesting." Mitigation is operational: the protocol seeds the
/// pool and does not fully exit.
#[test]
fun full_exit_then_rebootstrap_captures_orphaned_stream() {
    let (mut scenario, admin_cap, mut clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    let lp1 = bootstrap_supply_keep(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock, STREAM_DURATION_MS);

    // --- Full exit at the stream midpoint: LP1 is the sole holder, so the
    // pro-rata ratio is exactly 1.0 (div(S, S) = 1e9) and the band fee is 0
    // (no expiries). LP1 takes the entire idle balance and exactly the vested
    // half of the stream: mul(1e9, div(43_200_000, 86_400_000)) = 5e8.
    let half_ms = test_constants::now_ms() + STREAM_DURATION_MS / 2;
    clock.set_for_testing(half_ms);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc1, sui1, deep1) = vault.withdraw(&mut config, sync, lp1, &clock, scenario.ctx());
    assert_eq!(dusdc1.value(), test_constants::default_initial_supply());
    assert_eq!(sui1.value(), HALF_STREAM);
    assert_eq!(deep1.value(), 0);
    // The pool is now holder-empty and DUSDC-empty, but the locked half keeps
    // vesting toward it.
    assert_eq!(vault.total_supply(), 0);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(vault.incentive_sui_locked(), HALF_STREAM);
    return_shared(config);
    return_shared(vault);
    scenario.next_tx(test_constants::bob());

    // --- Re-bootstrap by a fresh address: the bootstrap branch requires only
    // `dusdc_value == 0` and mints 1:1, so 1 DUSDC buys 100% of the supply —
    // paying nothing for the locked half-stream. (The Pyth spot is re-seeded
    // fresh at the new clock for the incentive sync gate.)
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    pyth.set_state_for_testing(test_constants::default_creation_spot(), half_ms, half_ms);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let lp2 = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(FOLLOW_ON_SUPPLY, scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(lp2.value(), FOLLOW_ON_SUPPLY);

    // --- THE PIN: at stream end the terminal compound releases the full
    // locked remainder, and LP2's full-supply withdraw claims all of it:
    // mul(5e8, div(1e6, 1e6)) = 500_000_000. A 1-DUSDC round-trip captured
    // the half-stream the depositor funded for the prior LP cohort.
    clock.set_for_testing(test_constants::now_ms() + STREAM_DURATION_MS);
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc2, sui2, deep2) = vault.withdraw(&mut config, sync, lp2, &clock, scenario.ctx());
    assert_eq!(dusdc2.value(), FOLLOW_ON_SUPPLY);
    assert_eq!(sui2.value(), HALF_STREAM);
    assert_eq!(deep2.value(), 0);
    assert_eq!(vault.incentive_sui_locked(), 0);
    assert_eq!(vault.incentive_sui_balance(), 0);
    assert_eq!(vault.total_supply(), 0);

    destroy(dusdc1);
    destroy(dusdc2);
    destroy(sui1);
    destroy(sui2);
    destroy(deep1);
    destroy(deep2);
    destroy(admin_cap);
    destroy(clock);
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    scenario.end();
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
    destroy(bootstrap_supply_keep(scenario, clock, pyth_id));
}

/// `bootstrap_supply` returning the minted PLP coin, for scenarios that later
/// withdraw the bootstrap position.
fun bootstrap_supply_keep(
    scenario: &mut Scenario,
    clock: &Clock,
    pyth_id: ID,
): coin::Coin<plp::PLP> {
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
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());
    plp_coin
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
/// `duration_ms` (bound to the default feed).
fun fund_sui_incentive(
    scenario: &mut Scenario,
    admin_cap: &AdminCap,
    clock: &Clock,
    duration_ms: u64,
) {
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        admin_cap,
        coin::mint_for_testing<SUI>(INCENTIVE_DEPOSIT, scenario.ctx()),
        duration_ms,
        clock,
    );
    return_shared(vault);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}

/// Run one follow-on supply at the current clock — re-seeding the Pyth spot
/// fresh at the clock so the incentive freshness gate passes — which drives
/// `incentive::sync_value`'s compound. Returns the post-supply SUI incentive
/// `(released, locked)` balances.
fun supply_and_read_sui_incentive(scenario: &mut Scenario, clock: &Clock, pyth_id: ID): (u64, u64) {
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let now_ms = clock.timestamp_ms();
    pyth.set_state_for_testing(test_constants::default_creation_spot(), now_ms, now_ms);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let plp_coin = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(FOLLOW_ON_SUPPLY, scenario.ctx()),
        &pyth,
        &pyth,
        clock,
        scenario.ctx(),
    );
    destroy(plp_coin);
    let released = vault.incentive_sui_balance();
    let locked = vault.incentive_sui_locked();
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());
    (released, locked)
}
