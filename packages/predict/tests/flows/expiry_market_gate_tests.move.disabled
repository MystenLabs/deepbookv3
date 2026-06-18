// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard (gate) tests for the `expiry_market` public flows — closing the
/// happy-path-only coverage gap. Each test drives one production gate to its
/// abort. A gate that fails to fire here is a bug (the `expected_failure` test
/// would itself fail-to-abort).
#[test_only]
module deepbook_predict::expiry_market_gate_tests;

use deepbook_predict::{
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    pricing,
    protocol_config,
    test_constants
};
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};

// A source id distinct from `test_constants::pyth_feed_id()` (= 1), for the
// unrelated second feed that the wrong-feed binding tests pass.
const SECOND_SOURCE_ID: u32 = 2;

/// Mint after the market has expired (clock == expiry) must be rejected by the
/// live-pricing boundary before any trade mutation.
#[test, expected_failure(abort_code = pricing::ELivePricingExpired)]
fun mint_after_expiry_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    // Advance to expiry: the market flips active -> not active.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}

/// A permissionless `redeem_settled` against a still-LIVE (unexpired) market must
/// abort: the settled-redeem path requires the market to be terminally settled, and
/// `ensure_settled` returns false before expiry.
#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun redeem_settled_on_live_order_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
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
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}

/// Redeeming with the WRONG Pyth feed must abort at the live-pricing binding
/// check. `redeem` decodes the order before loading the pricer, so the test mints
/// a valid order first and then passes a second, unrelated `PythFeed`.
#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun redeem_with_wrong_pyth_feed_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    // Redeem on the real market but pass an unrelated Pyth feed: the live-pricing
    // binding check rejects it after decoding the valid order id.
    fx.redeem(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &wrong_pyth,
        &bs,
        order_id,
        test_constants::mint_quantity(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    sui::test_scenario::return_shared(wrong_pyth);
    fx.finish();
    abort 999
}

/// Minting with the CORRECT Pyth feed but the WRONG Block Scholes feed must abort:
/// the pricing boundary checks the Pyth binding first, then the BS binding, so a
/// correct Pyth + unrelated BS feed reaches the second assert.
#[test, expected_failure(abort_code = pricing::EWrongBlockScholesFeed)]
fun mint_with_wrong_block_scholes_feed_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_bs_id = propbook_registry::create_and_share_block_scholes_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    sui::test_scenario::return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();
    let wrong_bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(wrong_bs_id);

    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &wrong_bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    sui::test_scenario::return_shared(wrong_bs);
    fx.finish();
    abort 999
}

/// Minting while this expiry's mint switch is paused must abort: `mint` checks
/// the expiry-local mint pause immediately after the version gate.
#[test, expected_failure(abort_code = expiry_market::EMintPaused)]
fun mint_while_expiry_mint_paused_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.set_expiry_mint_paused(&mut market, &config, true);
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}

/// A version-disabled package (watermark pushed above the running `current_version!()`)
/// must block expiry-market flows. `set_mint_paused` is a version-gated public
/// entrypoint whose first line is `config.assert_version()`; the rooted `mint`/`redeem`
/// entrypoints gate identically (they share the same `config.assert_version()` first
/// line), so the cheap pause path stands in for the whole family here.
#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun expiry_market_flow_with_version_disabled_aborts() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (_pyth, _bs, _oracle_registry, _vault, mut market, mut config) = fx.take_market(expiry_id);

    protocol_config::set_version_watermark_for_testing(
        &mut config,
        constants::current_version!() + 1,
    );
    fx.set_expiry_mint_paused(&mut market, &config, true);
    abort 999
}

/// Minting while global trading is paused must abort.
#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun mint_while_trading_paused_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, vault, mut market, mut config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    fx.set_trading_paused(&mut config, true);
    fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
    abort 999
}
