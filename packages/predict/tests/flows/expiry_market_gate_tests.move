// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard (gate) tests for the `expiry_market` public flows — closing the
/// happy-path-only coverage gap. Each test drives one production gate to its
/// abort. A gate that fails to fire here is a bug (the `expected_failure` test
/// would itself fail-to-abort).
#[test_only]
module deepbook_predict::expiry_market_gate_tests;

use deepbook_predict::{
    admin,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    market_oracle::{Self, MarketOracle},
    plp,
    protocol_config,
    pyth_source::PythSource,
    registry::{Self, Registry},
    test_constants
};
use std::unit_test::destroy;

const SETTLEMENT_PRICE: u64 = 100_000_000_000;
const SECOND_EXPIRY_MS: u64 = 31_536_200_000;
// Any feed id distinct from `test_constants::pyth_feed_id()` (= 1).
const SECOND_PYTH_FEED_ID: u32 = 2;

/// Mint after the oracle has expired (pending settlement, not yet settled) must be
/// rejected: `run_liquidation_pass` inside `mint_internal` asserts the oracle is
/// active. The instant `clock == expiry` is the first non-active instant.
#[test, expected_failure(abort_code = market_oracle::EMarketNotActive)]
fun mint_after_expiry_before_settlement_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    // Advance to expiry: status flips active -> pending_settlement.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// A settled-market redeem must be a full close: a partial `redeem_settled` aborts.
#[test, expected_failure(abort_code = expiry_market::EFullCloseRequired)]
fun redeem_settled_partial_close_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_PRICE);

    // Partial close (one lot short of full) on a settled order.
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity() - constants::position_lot_size!(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// A permissionless `redeem_settled` against a still-LIVE order must abort: closing
/// live risk requires a proof.
#[test, expected_failure(abort_code = expiry_market::EProofRequiredForLiveRedeem)]
fun redeem_settled_on_live_order_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Full close, but no proof and the order is live.
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Redeeming against the WRONG market oracle must abort. `assert_market_oracle`
/// fires before order parsing, so this needs no real order — only two markets and
/// a mismatched oracle. Both expiries are created while the pyth spot is still
/// grid-valid (before any live-price prep moves it).
#[test, expected_failure(abort_code = expiry_market::EWrongMarketOracle)]
fun redeem_with_wrong_oracle_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.add_idle_supply_before_expiries(test_constants::default_initial_supply());
    let (expiry_a, _oracle_a) = fx.create_expiry(test_constants::default_expiry_ms());
    let (_expiry_b, oracle_b_id) = fx.create_expiry(SECOND_EXPIRY_MS);
    let mut manager = fx.create_funded_manager(test_constants::default_manager_deposit());

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market_a, oracle_a, config) = fx.take_market(expiry_a, _oracle_a);
    let wrong_oracle = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);

    // Redeem on market A but pass oracle B: assert_market_oracle aborts before the
    // (here irrelevant) order id is parsed.
    let dummy_order_id = 0;
    fx.redeem(
        &config,
        &mut manager,
        &mut market_a,
        &wrong_oracle,
        &pyth,
        dummy_order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_market(pyth, vault, market_a, oracle_a, config);
    sui::test_scenario::return_shared(wrong_oracle);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting with the CORRECT market oracle but a Pyth source for a different feed
/// must abort: `assert_pyth_feed` in `mint_internal` fires right after
/// `assert_market_oracle` passes, before any pricing reads the source. The second
/// source is registered through the real admin path.
#[test, expected_failure(abort_code = expiry_market::EWrongPythSource)]
fun mint_with_wrong_pyth_source_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut registry = fx.scenario_mut().take_shared<Registry>();
    let second_pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        SECOND_PYTH_FEED_ID,
        test_constants::default_tick_size(),
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythSource>(second_pyth_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &wrong_pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    sui::test_scenario::return_shared(wrong_pyth);
    destroy(admin_cap);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting while this expiry's mint switch is paused must abort: `mint` checks
/// `expiry_mint_paused` immediately after the version gate.
#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun mint_while_expiry_mint_paused_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, mut config) = fx.take_market(expiry_id, oracle_id);

    fx.set_expiry_mint_paused(&mut config, expiry_id, true);
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting after the running package version has been disabled in the registry
/// (and the market's mirrored `allowed_versions` synced) must abort:
/// `assert_version_allowed` is the first gate in `mint`.
#[test, expected_failure(abort_code = expiry_market::EPackageVersionDisabled)]
fun mint_with_current_version_disabled_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let admin_cap = admin::new(fx.scenario_mut().ctx());
    let mut registry = fx.scenario_mut().take_shared<Registry>();
    registry::enable_version(&mut registry, &admin_cap, constants::current_version!() + 1);
    registry::disable_version(&mut registry, &admin_cap, constants::current_version!());
    registry::sync_expiry_market_allowed_versions(&registry, &mut market);
    sui::test_scenario::return_shared(registry);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(admin_cap);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting while global trading is paused must abort: `assert_trading_allowed`
/// checks the pause flag before the valuation lock.
#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun mint_while_trading_paused_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, mut config) = fx.take_market(expiry_id, oracle_id);

    fx.set_trading_paused(&mut config, true);
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting inside an open pool-sync valuation window must abort: trading is not
/// paused, so `assert_trading_allowed` falls through to the valuation lock. The
/// un-consumed `PoolSync` is fine to hold since the test aborts.
#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun mint_during_pool_sync_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, mut config) = fx.take_market(expiry_id, oracle_id);

    let _sync = plp::start_pool_sync(&mut config, &vault);
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// `pool_nav` outside an open pool-sync valuation window must abort: it asserts
/// the valuation lock right after the version gate, before any binding or
/// pricing checks. Called directly — it is `public(package)` and this test
/// module lives in the same package.
#[test, expected_failure(abort_code = protocol_config::EValuationNotInProgress)]
fun pool_nav_outside_pool_sync_aborts() {
    let (mut fx, expiry_id, oracle_id, manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let (_nav, _range, _floor) = market.pool_nav(&config, &oracle, &pyth, fx.clock());

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
    abort 999
}
