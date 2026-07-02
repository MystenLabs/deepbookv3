// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Terminal settlement flow coverage: exact Propbook timestamp settlement,
/// settled redeem, and the settled-market PLP sweep.
#[test_only]
module deepbook_predict::settlement_flow_tests;

use account::account_registry;
use deepbook_predict::{
    config_constants,
    constants,
    expiry_market,
    flow_test_helpers as helpers,
    plp,
    predict_account,
    test_constants
};
use propbook::{pyth_feed::PythFeed, registry::{Self as propbook_registry, OracleRegistry}};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

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
/// seeded + mint principal + fee; losing settled redeem pays zero.
const CASH_AFTER_LOSING_REDEEM: u64 = 300_505_000_000;
/// Losing account recovers the full 2.5m rebate reserve at full benefit power.
const POST_REBATE_CLAIM_BALANCE: u64 = 497_500_000;
/// CASH_AFTER_LOSING_REDEEM minus the paid 2.5m rebate.
const CASH_AFTER_REBATE_CLAIM: u64 = 300_502_500_000;

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
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
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
    let mut market = fx.take_market_bundle(expiry_id);
    let wrong_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(wrong_pyth_id);

    fx.rebalance_expiry_cash_bundle_with_pyth(&mut market, &wrong_pyth);

    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongPythFeed)]
fun passive_settlement_rejects_old_pyth_after_propbook_rebind() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let _rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);

    fx.ensure_settled_bundle(&mut market);

    abort 999
}

#[test]
fun passive_settlement_uses_rebound_pyth_after_exact_backfill() {
    let settlement_price = settlement_inside_default_finite_range();
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let rebound_pyth_id = fx.create_and_rebind_pyth(SECOND_SOURCE_ID);
    fx.set_clock_for_testing(test_constants::default_expiry_ms());

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle_with_pyth(expiry_id, rebound_pyth_id);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    assert_eq!(fx.ensure_settled_bundle(&mut market), true);
    assert_eq!(expiry_market::settlement_price(helpers::market(&market)), settlement_price);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun passive_settled_redeem_pays_terminal_payout() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    fx.check_manager_bundle(
        &account,
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
        helpers::market(&market),
        helpers::expected_market_cash(CASH_AFTER_WINNING_REDEEM, 0, REBATE_AFTER_MINT),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EFullCloseRequired)]
fun settled_redeem_partial_close_aborts() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity() - constants::position_lot_size!(),
    );

    abort 999
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorized_predict_app_blocks_permissionless_settled_redeem() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.deauthorize_predict_app();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );

    abort 999
}

#[test]
fun owner_auth_settled_redeem_survives_predict_app_deauth() {
    let settlement_price = settlement_inside_default_finite_range();
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.deauthorize_predict_app();
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    fx.redeem_settled_with_owner_auth_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    fx.check_manager_bundle(
        &account,
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
        helpers::market(&market),
        helpers::expected_market_cash(CASH_AFTER_WINNING_REDEEM, 0, REBATE_AFTER_MINT),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = account_registry::EAppNotAuthorized)]
fun deauthorized_predict_app_blocks_permissionless_rebate_claim() {
    let (mut fx, expiry_id, trader) = prepare_settled_loss_with_inactive_rebate_stake();

    fx.deauthorize_predict_app();
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.claim_trading_loss_rebate_permissionless_bundle(&mut market, &mut account);

    abort 999
}

#[test]
fun owner_auth_rebate_claim_survives_predict_app_deauth() {
    let (mut fx, expiry_id, trader) = prepare_settled_loss_with_inactive_rebate_stake();

    fx.deauthorize_predict_app();
    fx.scenario_mut().next_epoch(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            POST_REBATE_CLAIM_BALANCE,
            0,
            0,
            config_constants::default_upper_benefit_power!(),
            0,
        ),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(CASH_AFTER_REBATE_CLAIM, 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
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
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, settlement_price);

    // First call records the settlement price from the exact expiry spot.
    assert_eq!(fx.ensure_settled_bundle(&mut market), true);
    // Second call (clock now far past expiry) must early-return true via the
    // already-settled gate without re-reading the oracle or changing the price.
    fx.set_clock_for_testing(test_constants::short_expiry_ms() * 2);
    assert_eq!(fx.ensure_settled_bundle(&mut market), true);

    // The redeem pays the terminal in-range payout, proving the recorded settlement
    // price is unchanged by the second `ensure_settled`.
    fx.redeem_settled_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(POST_SETTLED_REDEEM_BALANCE, MINT_MIN_FEE, 0, 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
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
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );

    let mut valuation = fx.start_flush_bundle(&mut market);
    fx.value_expiry_bundle(&mut valuation, &mut market);
    let pool_nav = fx.finish_flush_bundle(valuation, &mut market, option::none(), option::none());

    assert_eq!(pool_nav, IDLE_SEED);
    assert_eq!(helpers::vault(&market).idle_balance(), IDLE_SEED);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    helpers::return_market_bundle(market);
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
    let mut market = fx.take_market_bundle(expiry_id);
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_inside_default_finite_range(),
    );

    fx.rebalance_expiry_cash_bundle(&mut market);

    assert_eq!(helpers::vault(&market).idle_balance(), IDLE_SEED);
    assert_eq!(helpers::vault(&market).active_expiry_markets().length(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

fun settlement_inside_default_finite_range(): u64 {
    (helpers::strike_tick() + 1) * test_constants::default_tick_size()
}

fun settlement_below_default_finite_range(): u64 {
    (helpers::strike_tick() - 1) * test_constants::default_tick_size()
}

/// The plp rebate-claim wrapper's own settled gate: past expiry with no exact
/// Propbook spot recorded, the claim aborts before touching rebate or account state.
#[test, expected_failure(abort_code = plp::EMarketNotSettled)]
fun rebate_claim_requires_settled_market() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);

    abort 999
}

/// A rebate claim resolves the account's expiry summary, which requires every
/// position on the expiry closed: with an order still open after settlement it
/// aborts instead of paying against an incomplete loss picture.
#[test, expected_failure(abort_code = predict_account::EExpirySummaryHasOpenPositions)]
fun rebate_claim_with_open_position_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let _order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    // The position is never redeemed, so summary resolution must refuse the claim.
    fx.claim_trading_loss_rebate_bundle(&mut market, &mut account);

    abort 999
}

#[test]
fun unstake_deep_returns_all_staked_custody() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.fund_deep_bundle(&mut account, config_constants::default_upper_benefit_power!());
    fx.stake_deep_bundle(
        &mut market,
        &mut account,
        config_constants::default_upper_benefit_power!(),
    );
    assert_eq!(
        helpers::vault(&market).staked_deep(),
        config_constants::default_upper_benefit_power!(),
    );

    fx.unstake_deep_bundle(&mut market, &mut account);

    // All staked DEEP custody (active and inactive) left the vault for the account.
    assert_eq!(helpers::vault(&market).staked_deep(), 0);
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun prepare_settled_loss_with_inactive_rebate_stake(): (helpers::Fixture, ID, helpers::Trader) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::strike_tick() + 10,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    fx.set_clock_for_testing(test_constants::short_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(
        &mut market,
        settlement_below_default_finite_range(),
    );
    fx.redeem_settled_with_owner_auth_bundle(
        &mut market,
        &mut account,
        order_id,
        test_constants::mint_quantity(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 0, 0, 0),
    );
    helpers::check_market_cash(
        helpers::market(&market),
        helpers::expected_market_cash(CASH_AFTER_LOSING_REDEEM, 0, REBATE_AFTER_MINT),
    );

    fx.fund_deep_bundle(&mut account, config_constants::default_upper_benefit_power!());
    fx.stake_deep_bundle(
        &mut market,
        &mut account,
        config_constants::default_upper_benefit_power!(),
    );
    fx.check_manager_bundle(
        &account,
        expiry_id,
        helpers::expected_manager_state(
            POST_MINT_BALANCE,
            MINT_MIN_FEE,
            0,
            0,
            config_constants::default_upper_benefit_power!(),
        ),
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    (fx, expiry_id, trader)
}

/// Bootstrap pool idle via the genesis `lock_capital` so nonzero NAV has matching PLP
/// supply (`idle == total_supply == amount` at a 1.0 mark). The lock is operator-gated
/// and needs no trader account.
fun bootstrap_pool(fx: &mut helpers::Fixture, amount: u64) {
    fx.bootstrap_lock(amount);
}

fun fund_empty_market(fx: &mut helpers::Fixture, expiry_id: ID) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, test_constants::default_live_price());
    fx.rebalance_expiry_cash_bundle(&mut market);
    helpers::return_market_bundle(market);
}
