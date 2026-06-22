// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal settlement flow coverage: exact Propbook timestamp settlement,
/// settled redeem, and the settled-market PLP sweep.
#[test_only]
module deepbook_predict::settlement_flow_tests;

use deepbook_predict::{
    expiry_market::{Self, ExpiryMarket},
    flow_test_helpers as helpers,
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    test_constants
};
use dusdc::dusdc::DUSDC;
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::assert_eq;
use sui::{coin, test_scenario::return_shared};

const SECOND_SOURCE_ID: u32 = 2;
const IDLE_SEED: u64 = 1_200_000_000_000;

/// Per-trade fee floor for the default flow fixture.
const MINT_MIN_FEE: u64 = 5_000_000;
/// Manager deposit left after the 1x mint premium and min fee.
const POST_MINT_BALANCE: u64 = 495_000_000;
/// In-range settled payout adds the full 1e9 quantity to POST_MINT_BALANCE.
const POST_SETTLED_REDEEM_BALANCE: u64 = 1_495_000_000;
/// Rebate reserve after one 5e6 trading fee at the default 50% rebate rate.
const REBATE_AFTER_MINT: u64 = 2_500_000;
/// seeded + mint principal + fee - full settled payout.
const CASH_AFTER_WINNING_REDEEM: u64 = 299_505_000_000;

/// At expiry with no exact Propbook spot recorded, the market cannot settle, so the
/// permissionless `redeem_settled` aborts on its settled-state precondition rather
/// than mispricing against a missing terminal.
#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun passive_settlement_requires_exact_expiry_spot() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, bs, oracle_registry, _vault, mut market, config) = fx.take_market(expiry_id);
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
        helpers::strike_tick() + 1,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
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

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPythFeed)]
fun passive_settlement_with_wrong_pyth_feed_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let wrong_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        SECOND_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let (_pyth, _bs, oracle_registry, mut vault, mut market, config) = fx.take_market(expiry_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &wrong_pyth);

    abort 999
}

#[test]
fun passive_settled_redeem_pays_terminal_payout() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
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
        helpers::strike_tick() + 1,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot(&mut pyth, market.expiry(), settlement_price);

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
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(
            POST_SETTLED_REDEEM_BALANCE,
            MINT_MIN_FEE,
            0,
            0,
            0,
        ),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(CASH_AFTER_WINNING_REDEEM, 0, REBATE_AFTER_MINT),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun ensure_settled_is_idempotent_and_keeps_settlement_price() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
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
        helpers::strike_tick() + 1,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot(&mut pyth, market.expiry(), settlement_price);

    // First call records the settlement price from the exact expiry spot.
    assert_eq!(fx.ensure_settled(&mut market, &oracle_registry, &pyth), true);
    // Second call (clock now far past expiry) must early-return true via the
    // already-settled gate without re-reading the oracle or changing the price.
    fx.set_clock_for_testing(test_constants::short_expiry_ms() * 2);
    assert_eq!(fx.ensure_settled(&mut market, &oracle_registry, &pyth), true);

    // The redeem pays the terminal in-range payout, proving the recorded settlement
    // price is unchanged by the second `ensure_settled`.
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
    fx.check_manager(
        &wrapper,
        &root,
        expiry_id,
        helpers::expected_manager_state(POST_SETTLED_REDEEM_BALANCE, MINT_MIN_FEE, 0, 0, 0),
    );

    helpers::return_account(wrapper, root);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

#[test]
fun passive_settled_market_sweep_unblocks_pool_valuation() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    fx.insert_exact_settlement_spot(
        &mut pyth,
        market.expiry(),
        settlement_inside_default_finite_range(),
    );

    let mut valuation = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut valuation, &mut vault, &mut market, &config, &oracle_registry, &pyth, &bs);
    let pool_nav = valuation.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    assert_eq!(pool_nav, IDLE_SEED);
    assert_eq!(vault.idle_balance(), IDLE_SEED);
    assert_eq!(vault.active_expiry_markets().length(), 0);

    return_shared(config);
    return_shared(pyth);
    return_shared(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(market);
    fx.finish();
}

#[test]
fun passive_settled_standalone_rebalance_sweeps_market() {
    let mut fx = helpers::setup_market_default();
    let _trader = fx.create_funded_manager(0);
    bootstrap_pool(&mut fx, IDLE_SEED);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    fund_empty_market(&mut fx, expiry_id);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    fx.insert_exact_settlement_spot(
        &mut pyth,
        market.expiry(),
        settlement_inside_default_finite_range(),
    );

    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);

    assert_eq!(vault.idle_balance(), IDLE_SEED);
    assert_eq!(vault.active_expiry_markets().length(), 0);

    return_shared(config);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(market);
    fx.finish();
}

fun settlement_inside_default_finite_range(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}

/// Bootstrap pool idle via the genesis `lock_capital` so nonzero NAV has matching PLP
/// supply (`idle == total_supply == amount` at a 1.0 mark). The lock is operator-gated
/// and needs no trader account.
fun bootstrap_pool(fx: &mut helpers::Fixture, amount: u64) {
    fx.bootstrap_lock(amount);
}

fun fund_empty_market(fx: &mut helpers::Fixture, expiry_id: ID) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let (mut pyth, mut bs, oracle_registry, mut vault, mut market, config) = fx.take_market(
        expiry_id,
    );
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, test_constants::default_live_price());
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
}
