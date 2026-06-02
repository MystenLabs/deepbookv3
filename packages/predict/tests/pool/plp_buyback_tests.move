// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
/// Permissionless DEEP buyback: a configurable slice of LP profit is authorized as
/// a DUSDC `buyback_budget`, and anyone may sell DEEP into the pool for DUSDC out of
/// that budget. The DEEP is priced off the registry-bound DEEP `PythSource` (rounded
/// down, minus the configured discount), paid from idle liquidity, and folded into
/// the LP-owned `incentive_deep` released balance (so it enters PLP NAV and is paid
/// in-kind on withdrawal). Funding is LP-share: the budget caps how much LP DUSDC can
/// rotate into DEEP, so a swap is NAV-neutral (or NAV-accretive when a discount applies).
module deepbook_predict::plp_buyback_tests;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    constants,
    plp::{Self, PoolVault, PLP},
    pricing,
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, test_scenario as test};
use token::deep::DEEP;

const THOUSAND_DUSDC: u64 = 1_000_000_000;
const ONE_DUSDC: u64 = 1_000_000;
// DEEP has 6 decimals; at $1, raw DEEP units map 1:1 to raw DUSDC units.
const FIFTY_DEEP: u64 = 50_000_000;
const FIFTY_DUSDC: u64 = 50_000_000;
const TWO_HUNDRED_DUSDC: u64 = 200_000_000;
const DEEP_DECIMALS: u8 = 6;
// `pyth_source::new_for_testing` reports feed id 0.
const DEEP_FEED_ID: u32 = 0;
const NOW_MS: u64 = 1_000_000;
const TEN_PERCENT: u64 = 100_000_000;

// === Helpers ===

fun usd_spot(price_usd: u64): u64 {
    price_usd * constants::float_scaling!()
}

fun fresh(): u64 {
    config_constants::default_pyth_spot_freshness_ms!()
}

/// Pool set up with DEEP bound as the buyback oracle asset (feed id 0, 6 decimals).
fun begin(): (test::Scenario, Registry, AdminCap, PoolVault, ProtocolConfig, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    registry.set_incentive_asset_for_testing<DEEP>(DEEP_DECIMALS, DEEP_FEED_ID);
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

/// A fresh DEEP `PythSource` (feed id 0) reporting `spot`, observed at `clk`.
fun deep_source(scenario: &mut test::Scenario, clk: &Clock, spot: u64): PythSource {
    let mut source = pyth_source::new_for_testing(scenario.ctx());
    let now = clk.timestamp_ms();
    source.set_state_for_testing(spot, now, now);
    source
}

/// Bootstrap the pool with `amount` DUSDC of idle liquidity (mints PLP 1:1).
fun bootstrap_supply(
    vault: &mut PoolVault,
    config: &mut ProtocolConfig,
    scenario: &mut test::Scenario,
    clk: &Clock,
    amount: u64,
): coin::Coin<PLP> {
    let sync = plp::start_pool_sync(config, vault);
    let placeholder = deep_source(scenario, clk, 0);
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

fun swap(
    registry: &Registry,
    vault: &mut PoolVault,
    config: &ProtocolConfig,
    scenario: &mut test::Scenario,
    clk: &Clock,
    spot: u64,
    deep_amount: u64,
    min_dusdc_out: u64,
): coin::Coin<DUSDC> {
    let source = deep_source(scenario, clk, spot);
    let out = registry::swap_deep_for_dusdc(
        registry,
        vault,
        config,
        &source,
        coin::mint_for_testing<DEEP>(deep_amount, scenario.ctx()),
        min_dusdc_out,
        clk,
        scenario.ctx(),
    );
    destroy(source);
    out
}

// === swap: success / pricing ===

#[test]
fun swap_pays_dusdc_and_folds_deep_into_nav() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);

    // 50 DEEP @ $1 = $50 -> 50_000_000 DUSDC units, paid from idle.
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    assert_eq!(out.value(), FIFTY_DUSDC);
    assert_eq!(vault.buyback_budget(), TWO_HUNDRED_DUSDC - FIFTY_DUSDC);
    assert_eq!(vault.idle_balance(), THOUSAND_DUSDC - FIFTY_DUSDC);
    assert_eq!(vault.incentive_deep_balance(), FIFTY_DEEP);

    destroy(out);
    destroy(alice_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test]
fun swap_rounds_payout_down() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);

    // 1 raw DEEP unit @ $1.50 = 1.5 DUSDC units, floored DOWN to 1 (the round-up
    // valuation used for NAV would give 2 — the payout must never overpay).
    let out = swap(
        &registry,
        &mut vault,
        &config,
        &mut scenario,
        &clk,
        usd_spot(1) + usd_spot(1) / 2,
        1,
        0,
    );
    assert_eq!(out.value(), 1);

    destroy(out);
    destroy(alice_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test]
fun swap_applies_discount() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    config.set_buyback_discount(&admin_cap, TEN_PERCENT);

    // 50 DEEP @ $1 = $50, less 10% discount = $45 -> 45_000_000 DUSDC units.
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    assert_eq!(out.value(), 45_000_000);
    assert_eq!(vault.buyback_budget(), TWO_HUNDRED_DUSDC - 45_000_000);
    assert_eq!(vault.incentive_deep_balance(), FIFTY_DEEP);

    destroy(out);
    destroy(alice_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === swap: NAV continuity ===

#[test]
fun nav_unchanged_by_swap_at_oracle_mid() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    // Alice bootstraps 1000 DUSDC -> 1000 PLP at share price 1.0.
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    assert_eq!(alice_lp.value(), THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);

    // Swap rotates 50 DUSDC of idle into 50 DEEP at oracle mid: NAV stays 1000
    // (950 idle + $50 DEEP). A later supply at the DEEP spot must still price 1:1.
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);

    let sync = plp::start_pool_sync(&mut config, &vault);
    let src = deep_source(&mut scenario, &clk, usd_spot(1));
    let bob_lp = plp::supply(
        &mut vault,
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(THOUSAND_DUSDC, scenario.ctx()),
        &src,
        &src,
        &clk,
        scenario.ctx(),
    );
    // Share price unchanged at 1.0, so 1000 DUSDC still mints exactly 1000 PLP.
    assert_eq!(bob_lp.value(), THOUSAND_DUSDC);

    destroy(src);
    destroy(out);
    destroy(alice_lp);
    destroy(bob_lp);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === firewall: withdraw does not touch the budget ===

#[test]
fun withdraw_does_not_spend_buyback_budget() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);

    // A full withdrawal pays only from idle and never decrements the budget.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc, sui, deep) = plp::withdraw(
        &mut vault,
        &mut config,
        sync,
        alice_lp,
        &clk,
        scenario.ctx(),
    );
    assert_eq!(dusdc.value(), THOUSAND_DUSDC);
    assert_eq!(deep.value(), 0);
    assert_eq!(vault.buyback_budget(), TWO_HUNDRED_DUSDC);

    destroy(dusdc);
    destroy(sui);
    destroy(deep);
    finish(scenario, registry, admin_cap, vault, config, clk);
}

// === swap: abort coverage ===

#[test, expected_failure(abort_code = plp::EZeroDeepIn)]
fun swap_zero_deep_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), 0, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = plp::EMinDusdcOutNotMet)]
fun swap_below_min_out_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    // 50 DEEP @ $1 yields 50_000_000; demand one unit more.
    let out = swap(
        &registry,
        &mut vault,
        &config,
        &mut scenario,
        &clk,
        usd_spot(1),
        FIFTY_DEEP,
        FIFTY_DUSDC + 1,
    );
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = plp::EInsufficientBuybackBudget)]
fun swap_exceeds_budget_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    // Budget below the 50_000_000 the swap would pay.
    vault.set_buyback_budget_for_testing(FIFTY_DUSDC - 1);
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = plp::EInsufficientIdleBalance)]
fun swap_exceeds_idle_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    // Only 1 DUSDC of idle, but the budget is ample: the idle guard must bind.
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, ONE_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = plp::EZeroDusdcOut)]
fun swap_full_discount_aborts_zero_out() {
    let (mut scenario, registry, admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    // A 100% discount floors every payout to zero.
    config.set_buyback_discount(&admin_cap, constants::float_scaling!());
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = plp::EIncentiveFeedMismatch)]
fun swap_wrong_feed_id_aborts() {
    let (mut scenario, mut registry, _admin_cap, mut vault, mut config, clk) = begin();
    // Re-bind DEEP to feed id 7; the test source reports feed id 0.
    registry.set_incentive_asset_for_testing<DEEP>(DEEP_DECIMALS, 7);
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = pricing::EPythSpotStale)]
fun swap_stale_spot_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    let stale_ms = NOW_MS - fresh() - 1;
    let mut source = pyth_source::new_for_testing(scenario.ctx());
    source.set_state_for_testing(usd_spot(1), stale_ms, stale_ms);
    let out = registry::swap_deep_for_dusdc(
        &registry,
        &mut vault,
        &config,
        &source,
        coin::mint_for_testing<DEEP>(FIFTY_DEEP, scenario.ctx()),
        0,
        &clk,
        scenario.ctx(),
    );
    destroy(out);
    destroy(source);
    destroy(alice_lp);
    abort
}

#[test, expected_failure(abort_code = registry::EIncentiveAssetNotConfigured)]
fun swap_unconfigured_deep_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    // DEEP is never registered as an incentive asset.
    let (registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    let mut clk = clock::create_for_testing(scenario.ctx());
    clk.set_for_testing(NOW_MS);
    scenario.next_tx(test_constants::admin());
    let mut vault = scenario.take_shared<PoolVault>();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    destroy(admin_cap);
    abort
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun swap_during_valuation_aborts() {
    let (mut scenario, registry, _admin_cap, mut vault, mut config, clk) = begin();
    let alice_lp = bootstrap_supply(&mut vault, &mut config, &mut scenario, &clk, THOUSAND_DUSDC);
    vault.set_buyback_budget_for_testing(TWO_HUNDRED_DUSDC);
    config.begin_valuation();
    let out = swap(&registry, &mut vault, &config, &mut scenario, &clk, usd_spot(1), FIFTY_DEEP, 0);
    destroy(out);
    destroy(alice_lp);
    abort
}

// === admin config bounds ===

#[test]
fun default_buyback_config_matches_constants() {
    let (scenario, registry, admin_cap, vault, config, clk) = begin();
    assert_eq!(config.fee_config().buyback_share(), config_constants::default_buyback_share!());
    assert_eq!(
        config.fee_config().buyback_discount(),
        config_constants::default_buyback_discount!(),
    );
    finish(scenario, registry, admin_cap, vault, config, clk);
}

#[test, expected_failure(abort_code = config_constants::EInvalidBuybackShare)]
fun set_buyback_share_above_max_aborts() {
    let (scenario, registry, admin_cap, vault, mut config, clk) = begin();
    config.set_buyback_share(&admin_cap, constants::float_scaling!() + 1);
    finish(scenario, registry, admin_cap, vault, config, clk);
    abort
}

#[test, expected_failure(abort_code = config_constants::EInvalidBuybackDiscount)]
fun set_buyback_discount_above_max_aborts() {
    let (scenario, registry, admin_cap, vault, mut config, clk) = begin();
    config.set_buyback_discount(&admin_cap, constants::float_scaling!() + 1);
    finish(scenario, registry, admin_cap, vault, config, clk);
    abort
}
