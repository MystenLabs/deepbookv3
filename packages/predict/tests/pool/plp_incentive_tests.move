// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
/// Admin-deposited incentive assets (SUI, DEEP): streamed donation accounting,
/// fair share repricing on supply, and pro-rata in-kind payout on withdrawal.
///
/// A deposit vests linearly over a window: it lands in a locked balance and
/// streams into a claimable (released) balance over time. Only the released
/// portion is valued from its Lazer `PythSource` and folded into pool NAV on
/// `supply`, so a new depositor pays the fair value of what has already vested
/// and can't dilute existing holders — while an instant supply+withdraw cannot
/// capture the still-locked remainder (compounding advances on wall-clock time
/// only). `withdraw` returns the pro-rata DUSDC plus each incentive in-kind from
/// its released balance directly (no oracle, so a stale feed can't block exits).
/// The binding (coin -> feed + decimals) lives in the `Registry` alongside the
/// trading feed index.
module deepbook_predict::plp_incentive_tests;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    constants,
    incentive,
    plp::{Self, PoolVault, PLP},
    pricing,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, sui::SUI, test_scenario as test};
use token::deep::DEEP;

const THOUSAND_DUSDC: u64 = 1_000_000_000;
const ELEVEN_HUNDRED_DUSDC: u64 = 1_100_000_000;
const TWELVE_HUNDRED_DUSDC: u64 = 1_200_000_000;
const THIRTEEN_HUNDRED_DUSDC: u64 = 1_300_000_000;
const HUNDRED_SUI: u64 = 100_000_000_000;
const FIFTY_SUI: u64 = 50_000_000_000;
const TWENTY_FIVE_SUI: u64 = 25_000_000_000;
// DEEP has 6 decimals; 100 DEEP @ $1 = $100 in DUSDC units.
const HUNDRED_DEEP: u64 = 100_000_000;
const FIFTY_DEEP: u64 = 50_000_000;
const DEEP_DECIMALS: u8 = 6;
const SUI_DECIMALS: u8 = 9;
// `pyth_source::new_for_testing` reports feed id 0.
const SUI_FEED_ID: u32 = 0;
// 100 SUI @ $2 in DUSDC units (6 decimals): $200 == 200_000_000.
const SUI_INCENTIVE_VALUE: u64 = 200_000_000;
const NOW_MS: u64 = 1_000_000;
// Vesting window used across tests, and half of it.
const STREAM_MS: u64 = 100_000;
const HALF_MS: u64 = 50_000;

// === Helpers ===

fun usd_spot(price_usd: u64): u64 {
    price_usd * constants::float_scaling!()
}

/// Spot freshness bound incentives share with the market path.
fun fresh(): u64 {
    config_constants::default_pyth_spot_freshness_ms!()
}

fun advance(clk: &mut Clock, ms: u64) {
    let next = clk.timestamp_ms() + ms;
    clk.set_for_testing(next);
}

fun begin(): (test::Scenario, Registry, AdminCap, PoolVault, ProtocolConfig, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    registry.set_incentive_asset_for_testing<SUI>(SUI_DECIMALS, SUI_FEED_ID);
    let config = protocol_config::new_for_testing(scenario.ctx());
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(NOW_MS);
    scenario.next_tx(test_constants::admin());
    let vault = scenario.take_shared<PoolVault>();
    (scenario, registry, admin_cap, vault, config, clk)
}

fun finish(
    scenario: test::Scenario,
    registry: Registry,
    admin_cap: AdminCap,
    vault: PoolVault,
    config: ProtocolConfig,
    clk: Clock,
) {
    destroy(admin_cap);
    destroy(config);
    destroy(clk);
    test::return_shared(vault);
    registry::destroy_registry_drop_for_testing(registry);
    scenario.end();
}

/// A fresh SUI `PythSource` (feed id 0) reporting `spot`, observed at `clk`.
fun sui_source(scenario: &mut test::Scenario, clk: &Clock, spot: u64): PythSource {
    let mut source = pyth_source::new_for_testing(scenario.ctx());
    let now = clk.timestamp_ms();
    source.set_state_for_testing(spot, now, now);
    source
}

fun bootstrap_supply(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    scenario: &mut test::Scenario,
    clk: &Clock,
    amount: u64,
): coin::Coin<PLP> {
    let sync = plp::start_pool_sync(config, vault);
    // No incentives exist at bootstrap, so the sources are ignored.
    let placeholder = sui_source(scenario, clk, 0);
    let lp = plp::supply(
        vault,
        config,
        sync,
        coin::mint_for_testing<DUSDC>(amount, scenario.ctx()),
        &placeholder,
        &placeholder,
        clk,
        scenario.ctx(),
    );
    destroy(placeholder);
    lp
}

/// Supply while the pool holds a SUI incentive: `supply` itself values the
/// released portion from a fresh spot observed at `clk`.
fun supply_with_incentive(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    scenario: &mut test::Scenario,
    clk: &Clock,
    spot: u64,
    amount: u64,
): coin::Coin<PLP> {
    let sync = plp::start_pool_sync(config, vault);
    let source = sui_source(scenario, clk, spot);
    // No DEEP incentive in these tests, so its source slot is ignored; reuse the
    // SUI source as the placeholder.
    let lp = plp::supply(
        vault,
        config,
        sync,
        coin::mint_for_testing<DUSDC>(amount, scenario.ctx()),
        &source,
        &source,
        clk,
        scenario.ctx(),
    );
    destroy(source);
    lp
}

fun donate_sui(
    registry: &Registry,
    vault: &mut PoolVault,
    admin_cap: &AdminCap,
    scenario: &mut test::Scenario,
    clk: &Clock,
    amount: u64,
    duration_ms: u64,
) {
    registry::deposit_sui_incentive(
        registry,
        vault,
        admin_cap,
        coin::mint_for_testing<SUI>(amount, scenario.ctx()),
        duration_ms,
        clk,
    );
}

fun donate_deep(
    registry: &Registry,
    vault: &mut PoolVault,
    admin_cap: &AdminCap,
    scenario: &mut test::Scenario,
    clk: &Clock,
    amount: u64,
    duration_ms: u64,
) {
    registry::deposit_deep_incentive(
        registry,
        vault,
        admin_cap,
        coin::mint_for_testing<DEEP>(amount, scenario.ctx()),
        duration_ms,
        clk,
    );
}

// === pyth_source::value_in_dusdc valuation math (independently hand-computed) ===

#[test]
fun incentive_value_matches_hand_calc() {
    let mut scenario = test::begin(test_constants::admin());
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(NOW_MS);

    // 100 SUI @ $2 = $200 -> 200_000_000 DUSDC units (6 decimals).
    let source = sui_source(&mut scenario, &clk, usd_spot(2));
    assert_eq!(source.value_in_dusdc(HUNDRED_SUI, SUI_DECIMALS), SUI_INCENTIVE_VALUE);
    // 100 SUI @ $5 = $500.
    let source_five = sui_source(&mut scenario, &clk, usd_spot(5));
    assert_eq!(source_five.value_in_dusdc(HUNDRED_SUI, SUI_DECIMALS), 500_000_000);
    // 1 raw SUI unit @ $1 = $1e-9 -> 0.001 DUSDC units, rounds up to 1.
    let source_one = sui_source(&mut scenario, &clk, usd_spot(1));
    assert_eq!(source_one.value_in_dusdc(1, SUI_DECIMALS), 1);

    destroy(source);
    destroy(source_five);
    destroy(source_one);
    destroy(clk);
    scenario.end();
}

// === deposit_incentive ===

#[test]
fun deposit_registers_and_mints_no_plp() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    let supply_before = vault.total_supply();

    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);

    // The whole deposit is locked and vesting; nothing is claimable at the same
    // instant, and no PLP is minted.
    assert_eq!(vault.incentive_sui_locked(), HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_balance(), 0);
    assert_eq!(vault.total_supply(), supply_before);

    // A second deposit at the same instant just adds to locked (nothing vested).
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    assert_eq!(vault.incentive_sui_locked(), 2 * HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_balance(), 0);

    destroy(alice_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === linear vesting ===

#[test]
fun donation_vests_linearly_over_window() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, mut clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);

    // A supply syncs (and thus vests) the incentive as of the current time. Half
    // the window elapsed: half vests into the claimable balance.
    advance(&mut clk, HALF_MS);
    let lp1 = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        THOUSAND_DUSDC,
    );
    assert_eq!(vault.incentive_sui_balance(), FIFTY_SUI);
    assert_eq!(vault.incentive_sui_locked(), FIFTY_SUI);

    // The window ends: the entire remainder vests and the schedule clears.
    advance(&mut clk, HALF_MS);
    let lp2 = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        THOUSAND_DUSDC,
    );
    assert_eq!(vault.incentive_sui_balance(), HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_locked(), 0);

    // Past the end, further vesting is a no-op (schedule already cleared).
    advance(&mut clk, STREAM_MS);
    let lp3 = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        THOUSAND_DUSDC,
    );
    assert_eq!(vault.incentive_sui_balance(), HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_locked(), 0);

    destroy(alice_lp);
    destroy(lp1);
    destroy(lp2);
    destroy(lp3);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test]
fun second_deposit_vests_prior_then_rolls_remainder() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, mut clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);

    // Halfway through, a second deposit lands. The deposit vests the prior
    // schedule to now (50 SUI released), then its 50 SUI remainder plus the new
    // 100 SUI re-stream over a fresh window.
    advance(&mut clk, HALF_MS);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    assert_eq!(vault.incentive_sui_balance(), FIFTY_SUI);
    assert_eq!(vault.incentive_sui_locked(), FIFTY_SUI + HUNDRED_SUI);

    // A supply after the fresh window vests the combined 150 SUI remainder.
    advance(&mut clk, STREAM_MS);
    let lp = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        THOUSAND_DUSDC,
    );
    assert_eq!(vault.incentive_sui_balance(), 2 * HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_locked(), 0);

    destroy(alice_lp);
    destroy(lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === supply repricing (fairness / anti-dilution) ===

#[test]
fun supply_after_donation_reprices_shares() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, mut clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    assert_eq!(alice_lp.value(), THOUSAND_DUSDC);

    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    // Fully vest the donation so its value is priced into NAV.
    advance(&mut clk, STREAM_MS);

    // Bob supplies 1200 DUSDC at share price 1.2 (1000 DUSDC + 100 SUI @ $2) -> 1000 PLP.
    let bob_lp = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        TWELVE_HUNDRED_DUSDC,
    );
    assert_eq!(bob_lp.value(), 1_000_000_000);

    destroy(alice_lp);
    destroy(bob_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === withdraw: pro-rata DUSDC + in-kind incentive ===

#[test]
fun withdraw_pays_pro_rata_dusdc_and_incentive_in_kind() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, mut clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    // Fully vest so all 100 SUI is claimable.
    advance(&mut clk, STREAM_MS);
    let bob_lp = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        TWELVE_HUNDRED_DUSDC,
    );

    assert_eq!(vault.idle_balance(), 2_200_000_000);
    assert_eq!(vault.incentive_sui_balance(), HUNDRED_SUI);
    assert_eq!(vault.incentive_sui_locked(), 0);
    assert_eq!(vault.total_supply(), 2_000_000_000);

    // Alice withdraws all 1e9 PLP (50%): 1100 DUSDC + 50 SUI in-kind, 0 DEEP.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (alice_dusdc, alice_sui, alice_deep) = plp::withdraw(
        &mut vault,
        &mut config,
        sync,
        alice_lp,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(alice_dusdc.value(), 1_100_000_000);
    assert_eq!(alice_sui.value(), FIFTY_SUI);
    assert_eq!(alice_deep.value(), 0);

    assert_eq!(vault.total_supply(), 1_000_000_000);
    assert_eq!(vault.idle_balance(), 1_100_000_000);
    assert_eq!(vault.incentive_sui_balance(), FIFTY_SUI);

    // Bob withdraws all (100%): drains the pool, 1100 DUSDC + 50 SUI.
    let sync2 = plp::start_pool_sync(&mut config, &vault);
    let (bob_dusdc, bob_sui, bob_deep) = plp::withdraw(
        &mut vault,
        &mut config,
        sync2,
        bob_lp,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(bob_dusdc.value(), 1_100_000_000);
    assert_eq!(bob_sui.value(), FIFTY_SUI);
    assert_eq!(bob_deep.value(), 0);

    assert_eq!(vault.total_supply(), 0);
    assert_eq!(vault.idle_balance(), 0);
    assert_eq!(vault.incentive_sui_balance(), 0);

    destroy(alice_dusdc);
    destroy(alice_sui);
    destroy(alice_deep);
    destroy(bob_dusdc);
    destroy(bob_sui);
    destroy(bob_deep);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test]
fun instant_supply_withdraw_returns_less_dusdc_and_cannot_capture_locked() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, mut clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);

    // Halfway through vesting: 50 SUI claimable, 50 SUI still locked.
    advance(&mut clk, HALF_MS);

    // Bob supplies 1100 DUSDC at NAV = 1000 DUSDC + 50 SUI ($100) = 1100 -> 1000 PLP.
    let bob_lp = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        ELEVEN_HUNDRED_DUSDC,
    );
    assert_eq!(bob_lp.value(), 1_000_000_000);
    assert_eq!(vault.incentive_sui_balance(), FIFTY_SUI);
    assert_eq!(vault.incentive_sui_locked(), FIFTY_SUI);

    // Bob withdraws immediately (same instant, no further vesting): 50% of the
    // pool. He gets back LESS DUSDC than the 1100 he deposited, plus an in-kind
    // slice of only the *released* incentive — the locked 50 SUI is untouchable.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (bob_dusdc, bob_sui, bob_deep) = plp::withdraw(
        &mut vault,
        &mut config,
        sync,
        bob_lp,
        &clk,
        scenario.ctx(),
    );

    assert_eq!(bob_dusdc.value(), 1_050_000_000);
    assert_eq!(bob_sui.value(), TWENTY_FIVE_SUI);
    assert_eq!(bob_deep.value(), 0);
    assert_eq!(vault.incentive_sui_locked(), FIFTY_SUI);
    assert_eq!(vault.incentive_sui_balance(), TWENTY_FIVE_SUI);

    destroy(alice_lp);
    destroy(bob_dusdc);
    destroy(bob_sui);
    destroy(bob_deep);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test]
fun supply_and_withdraw_value_both_sui_and_deep() {
    let (mut scenario, mut registry, admin_cap, mut vault, mut config, mut clk) = begin();
    // Configure DEEP as a second incentive asset (test sources all report feed 0).
    registry.set_incentive_asset_for_testing<DEEP>(DEEP_DECIMALS, SUI_FEED_ID);
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);

    // Donate both incentives; each lands fully locked, then fully vests.
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    donate_deep(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_DEEP, STREAM_MS);
    assert_eq!(vault.incentive_deep_locked(), HUNDRED_DEEP);
    assert_eq!(vault.incentive_deep_balance(), 0);
    advance(&mut clk, STREAM_MS);

    // Bob supplies against NAV = 1000 DUSDC + $200 SUI + $100 DEEP = 1300 -> 1000 PLP.
    // supply values BOTH incentives inline from their (distinct-spot) sources.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let sui_src = sui_source(&mut scenario, &clk, usd_spot(2));
    let deep_src = sui_source(&mut scenario, &clk, usd_spot(1));
    let bob_lp = plp::supply(
        &mut vault,
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(THIRTEEN_HUNDRED_DUSDC, scenario.ctx()),
        &sui_src,
        &deep_src,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(bob_lp.value(), 1_000_000_000);
    assert_eq!(vault.incentive_sui_balance(), HUNDRED_SUI);
    assert_eq!(vault.incentive_deep_balance(), HUNDRED_DEEP);
    destroy(sui_src);
    destroy(deep_src);

    // Bob withdraws 50%: 1150 DUSDC + 50 SUI + 50 DEEP, all in one call.
    let sync2 = plp::start_pool_sync(&mut config, &vault);
    let (bob_dusdc, bob_sui, bob_deep) = plp::withdraw(
        &mut vault,
        &mut config,
        sync2,
        bob_lp,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(bob_dusdc.value(), 1_150_000_000);
    assert_eq!(bob_sui.value(), FIFTY_SUI);
    assert_eq!(bob_deep.value(), FIFTY_DEEP);
    assert_eq!(vault.incentive_sui_balance(), FIFTY_SUI);
    assert_eq!(vault.incentive_deep_balance(), FIFTY_DEEP);

    destroy(alice_lp);
    destroy(bob_dusdc);
    destroy(bob_sui);
    destroy(bob_deep);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === valuation abort coverage ===

#[test, expected_failure(abort_code = pyth_source::EZeroSpot)]
fun valuing_with_zero_spot_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(NOW_MS);
    let source = sui_source(&mut scenario, &clk, 0);
    source.value_in_dusdc(HUNDRED_SUI, SUI_DECIMALS);
    abort
}

#[test, expected_failure(abort_code = incentive::EFeedMismatch)]
fun supply_wrong_feed_id_aborts() {
    let (mut scenario, mut registry, admin_cap, mut vault, mut config, clk) = begin();
    // Re-bind SUI to feed id 7; the test PythSource reports feed id 0.
    registry.set_incentive_asset_for_testing<SUI>(SUI_DECIMALS, 7);
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    // supply values the SUI incentive; the source reports feed id 0, not 7.
    let bob_lp = supply_with_incentive(
        &mut vault,
        &mut config,
        &mut scenario,
        &clk,
        usd_spot(2),
        TWELVE_HUNDRED_DUSDC,
    );
    destroy(alice_lp);
    destroy(bob_lp);
    abort
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun supply_stale_spot_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    let sync = plp::start_pool_sync(&mut config, &vault);
    // Spot observed long enough ago to be stale at NOW_MS (feed id 0 matches SUI).
    let stale_ms = NOW_MS - fresh() - 1;
    let mut source = pyth_source::new_for_testing(scenario.ctx());
    source.set_state_for_testing(usd_spot(2), stale_ms, stale_ms);
    let bob_lp = plp::supply(
        &mut vault,
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(THOUSAND_DUSDC, scenario.ctx()),
        &source,
        &source,
        &clk,
        scenario.ctx(),
    );
    destroy(alice_lp);
    destroy(bob_lp);
    destroy(source);
    abort
}

// === deposit / sync abort coverage ===

#[test, expected_failure(abort_code = plp::ENoPlpHolders)]
fun deposit_before_any_plp_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, _config, clk) = begin();
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, STREAM_MS);
    abort
}

#[test, expected_failure(abort_code = incentive::EZeroDeposit)]
fun deposit_zero_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, 0, STREAM_MS);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = incentive::EZeroStreamDuration)]
fun deposit_zero_duration_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(&registry, &mut vault, &admin_cap, &mut scenario, &clk, HUNDRED_SUI, 0);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = incentive::EStreamDurationTooLong)]
fun deposit_duration_too_long_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    donate_sui(
        &registry,
        &mut vault,
        &admin_cap,
        &mut scenario,
        &clk,
        HUNDRED_SUI,
        constants::max_incentive_stream_ms!() + 1,
    );
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = registry::EIncentiveAssetNotConfigured)]
fun deposit_unconfigured_asset_aborts() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    // DEEP is never configured as an incentive asset in `begin`.
    registry::deposit_deep_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::mint_for_testing<DEEP>(1_000_000, scenario.ctx()),
        STREAM_MS,
        &clk,
    );
    destroy(alice_lp);
    abort
}
