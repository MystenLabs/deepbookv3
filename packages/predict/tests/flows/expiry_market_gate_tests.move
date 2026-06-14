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
    protocol_config,
    registry::{Self, Registry},
    test_constants
};
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    pyth_feed::{Self, PythFeed},
    registry::OracleRegistry
};
use std::unit_test::destroy;

// A propbook feed id / underlying distinct from `test_constants::pyth_feed_id()` (= 1),
// for the unrelated second feed that the wrong-feed binding tests pass.
const SECOND_FEED_ID: u32 = 2;

/// Mint after the market has expired (clock == expiry) must be rejected:
/// `run_liquidation_pass` inside `mint_internal` calls `assert_active`, and the
/// instant `clock == expiry` is the first non-active instant.
#[test, expected_failure(abort_code = expiry_market::EMarketNotActive)]
fun mint_after_expiry_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);

    // Advance to expiry: the market flips active -> not active.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// A permissionless `redeem_settled` against a still-LIVE order must abort: closing
/// live risk requires a proof. (Settlement is stubbed — `is_settled()` is always
/// false — so every order is on the live branch.)
#[test, expected_failure(abort_code = expiry_market::EProofRequiredForLiveRedeem)]
fun redeem_settled_on_live_order_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);

    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Full close, but no proof and the order is live.
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Redeeming with the WRONG Pyth feed must abort. `assert_feeds` fires before order
/// parsing, so this needs no real order — only a second, unrelated `PythFeed`
/// created through the real propbook path.
#[test, expected_failure(abort_code = expiry_market::EWrongPythFeed)]
fun redeem_with_wrong_pyth_feed_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = pyth_feed::create_and_share(
        &mut oracle_registry,
        SECOND_FEED_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    // Redeem on the real market but pass an unrelated Pyth feed: assert_feeds aborts
    // before the (here irrelevant) order id is parsed.
    let dummy_order_id = 0;
    fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &wrong_pyth,
        &bs,
        dummy_order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    sui::test_scenario::return_shared(wrong_pyth);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting with the CORRECT Pyth feed but the WRONG Block Scholes feed must abort:
/// `assert_feeds` checks the Pyth binding first, then the BS binding, so a correct
/// Pyth + unrelated BS feed reaches the second assert.
#[test, expected_failure(abort_code = expiry_market::EWrongBlockScholesFeed)]
fun mint_with_wrong_block_scholes_feed_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_bs_id = block_scholes_feed::create_and_share(
        &mut oracle_registry,
        SECOND_FEED_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);
    let wrong_bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(wrong_bs_id);

    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &wrong_bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    sui::test_scenario::return_shared(wrong_bs);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting while this expiry's mint switch is paused must abort: `mint` checks
/// the expiry-local mint pause immediately after the version gate.
#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun mint_while_expiry_mint_paused_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);

    fx.set_expiry_mint_paused(&mut market, true);
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting after the running package version has been disabled in the registry
/// (and the market's mirrored `allowed_versions` synced) must abort:
/// `assert_version_allowed` is the first gate in `mint`.
#[test, expected_failure(abort_code = expiry_market::EPackageVersionDisabled)]
fun mint_with_current_version_disabled_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, config) = fx.take_market(expiry_id);

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
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    destroy(admin_cap);
    destroy(manager);
    fx.finish();
    abort 999
}

/// Minting while global trading is paused must abort.
#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun mint_while_trading_paused_aborts() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, vault, mut market, mut config) = fx.take_market(expiry_id);

    fx.set_trading_paused(&mut config, true);
    fx.mint(
        &config,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_market(pyth, bs, vault, market, config);
    destroy(manager);
    fx.finish();
    abort 999
}
