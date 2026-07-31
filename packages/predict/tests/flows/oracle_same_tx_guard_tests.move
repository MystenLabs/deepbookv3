// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the same-transaction oracle-write guard: a live pricer may
/// not be built from an observation written in the current PTB. Pins Variant A
/// (mint → update → mint), Variant C (update → redeem seasoned position), the
/// no-false-positive multi-leg path, isolated forward / SVI / fresh-Pyth writes,
/// the Pyth provenance-only exemptions, and the accepted residual — the guard is
/// a build-time check, so it refuses write→price but not price→write (RP-23).
#[test_only]
module deepbook_predict::oracle_same_tx_guard_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, pricing, test_constants};
use std::unit_test::assert_eq;

/// Lot-aligned position size used across the mint/redeem scenarios.
const QUANTITY: u64 = 840_000_000;
/// 1x leverage in 1e9 fixed point: no floor, so no liquidation interaction.
const LEVERAGE_ONE_X: u64 = 1_000_000_000;
/// Later source stamp used when rewriting the surface mid-test. Must be ≥ the
/// fixture clock so Block Scholes `published_at <= recorded_at` accepts the batch.
const FRESHER_SOURCE_TS: u64 = 121_000;
/// Keep the default ATM price so admission bounds stay satisfied; the guard
/// keys on writer digest, not the printed level.
const FRESHER_PRICE: u64 = 100_000_000_000;
/// +20% on the seeded ATM level: the correction a trader pushes after filling
/// against the stale surface. Drives the strike deep in the money for the UP leg.
const PUSHED_PRICE: u64 = 120_000_000_000;
/// Tight Pyth freshness used to force a same-tx Pyth write into the stale branch.
const TIGHT_PYTH_FRESHNESS_MS: u64 = 1_000;
const STALE_PYTH_CLOCK_MS: u64 = 122_001;
const STALE_PYTH_SOURCE_MS: u64 = 121_000;

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun write_feed_then_load_pricer_same_tx_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_live_oracle_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test]
fun write_feed_then_mint_next_tx_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    {
        let mut market = fx.take_market_bundle(expiry_id);
        // Routine seed (dummy digest) advances the surface in this transaction.
        fx.prepare_live_oracle_bundle_at(
            &mut market,
            test_constants::default_live_price(),
            test_constants::now_ms(),
        );
        helpers::return_market_bundle(market);
    };

    // Distinct digest: next_tx advances the scenario transaction number.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun variant_a_mint_update_mint_aborts_on_second_pricer() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Leg A against the seeded surface.
    let _order_a = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    // Push a fresher surface, then try to load a second pricer for the complement.
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_live_oracle_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun variant_c_write_then_redeem_seasoned_position_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let order = {
        let mut market = fx.take_market_bundle(expiry_id);
        let mut account = fx.take_account_bundle(&trader);
        let order = fx.mint_bundle(
            &mut market,
            &mut account,
            helpers::strike_tick(),
            constants::pos_inf_tick!(),
            QUANTITY,
            LEVERAGE_ONE_X,
        );
        helpers::return_account_bundle(account);
        helpers::return_market_bundle(market);
        order
    };

    // Later transaction: advance the clock past opened_at so the legacy
    // same-timestamp mint/redeem guard does not fire first, rewrite the oracle,
    // then redeem the seasoned position — the new digest guard must abort.
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_live_oracle_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    fx.redeem_bundle(
        &mut market,
        &mut account,
        order,
        QUANTITY,
    );

    abort 999
}

#[test]
fun ordinary_mint_without_oracle_write_succeeds() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun multi_leg_mints_share_one_pricer_without_oracle_write() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // One pricer load per mint helper call, but no oracle write in this PTB —
    // every leg must succeed (no false positive from shared digest alone).
    let order_a = fx.mint_bundle(
        &mut market,
        &mut account,
        0,
        helpers::strike_tick(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    let order_b = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order_a));
    assert!(helpers::has_position_bundle(&account, expiry_id, order_b));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun write_bs_forward_only_then_load_pricer_same_tx_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Spot stays on the seeded digest; only forward is rewritten in this PTB.
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_bs_forward_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun write_bs_svi_only_then_load_pricer_same_tx_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_bs_svi_in_current_tx_bundle(&mut market, FRESHER_SOURCE_TS);
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun write_fresh_pyth_only_then_load_pricer_same_tx_aborts() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Re-anchor on: a fresh same-tx Pyth write must trip the guard even though
    // every Block Scholes observation still carries the seeded digest.
    fx.set_use_pyth_spot_for_forward_bundle(&mut market, true);
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_pyth_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );

    abort 999
}

#[test]
fun pyth_write_same_tx_succeeds_when_reanchor_disabled() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_use_pyth_spot_for_forward_bundle(&mut market, false);
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    // Pyth advances in this transaction; BS surface is left alone so the
    // price-feeding reads keep the prior writer's digest.
    fx.write_pyth_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        FRESHER_SOURCE_TS,
    );
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun pyth_write_same_tx_succeeds_when_pyth_read_is_stale() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    fx.set_use_pyth_spot_for_forward_bundle(&mut market, true);
    fx.set_pyth_spot_freshness_bundle(&mut market, TIGHT_PYTH_FRESHNESS_MS);
    // Clock past the tightened window; Pyth source still advances past the prior
    // row, so the write lands but stays provenance-only. BS at 119_000 remains
    // inside the default 10s freshness budget.
    fx.set_clock_for_testing(STALE_PYTH_CLOCK_MS);
    fx.write_pyth_in_current_tx_bundle(
        &mut market,
        FRESHER_PRICE,
        STALE_PYTH_SOURCE_MS,
    );
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));
    assert_eq!(
        fx.load_pricer_bundle(&market).pyth_spot_source_timestamp_ms(),
        STALE_PYTH_SOURCE_MS,
    );

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The guard runs at `Pricer` construction, so it cannot see a write that lands
/// later in the same PTB: `load pricer (stale) → mint → write` is permitted. The
/// trader fills at the stale mark and pushes the correction in one atomic
/// transaction; only the closing leg must cross a transaction boundary, and since
/// that leg is a mint of the complement rather than a redeem, no minimum-holding
/// guard applies to it either. RP-23 accepts this residual — this test pins that
/// it is what ships, so closing the ordering turns the assertion red instead of
/// changing behavior silently.
#[test]
fun price_then_write_same_tx_is_permitted() {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Fill the UP leg against the stale surface, then push the correction — one tx.
    let order = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        QUANTITY,
        LEVERAGE_ONE_X,
    );
    let value_at_stale_mark = fx.order_value_bundle(&market, order);
    fx.set_clock_for_testing(FRESHER_SOURCE_TS);
    fx.write_live_oracle_in_current_tx_bundle(
        &mut market,
        PUSHED_PRICE,
        FRESHER_SOURCE_TS,
    );
    assert!(helpers::has_position_bundle(&account, expiry_id, order));

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    // Next transaction: the position bought at the stale mark now carries the level
    // this same trader pushed. Both bounds come from the payoff, not from Predict's
    // pricing — a range digital struck at the seeded spot is worth strictly more
    // once spot sits 20% above the strike, and never more than its max payout.
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let value_at_pushed_mark = fx.order_value_bundle(&market, order);
    assert!(value_at_pushed_mark > value_at_stale_mark);
    assert!(value_at_pushed_mark <= QUANTITY);

    helpers::return_market_bundle(market);
    fx.finish();
}
