// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// L2/L3 liquidation lifecycle: a 2x order is knocked out by a 1% price drop,
/// and the test pins that liquidation is a pure knockout (liability drops by
/// exactly the order's backing, no cash moves, the holder's manager is
/// untouched), that a second liquidation attempt on the same id returns false
/// (no double-liquidation), and that the holder's redeem of the tombstone pays
/// EXACTLY zero with no fee and clears the position (no double-pay) — after
/// which a third liquidation attempt is still false.
#[test_only]
module deepbook_predict::no_double_pay_liquidation_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, order, test_constants};
use std::unit_test::{assert_eq, destroy};

const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 2x ATM mint of quantity 1e9 on [min_strike, +inf): entry_value
/// = floor(0.5 * 1e9) = 500_000_000 (p = Φ(0) = 0.5 exactly);
/// net_premium = floor(entry_value / 2) = 250_000_000.
const MINT_CONTRIBUTION: u64 = 250_000_000;
/// Fee floors at min_fee (fixture base_fee = 1 makes the raw Bernoulli fee
/// round to 0; the default max-multiplier 1.0 keeps the short-expiry ramp inert).
const MINT_MIN_FEE: u64 = 5_000_000;
/// mint_deposit − net_premium − fee = 1e9 − 250e6 − 5e6.
const POST_MINT_BALANCE: u64 = 745_000_000;
/// financed_amount = entry_value − net_premium = 250_000_000. Floor index at open
/// (clock 100_000, expiry 200_000, window 31_536_000_000 ms):
///   phase = floor(31_535_900_000 * 1e9 / 31_536_000_000) = 999_996_829;
///   phase² = floor(phase * phase / 1e9) = 999_993_658;
///   premium = floor((1.2e9 − 1e9) * phase² / 1e9) = 199_998_731;
///   index_open = 1_199_998_731.
/// floor_shares = floor(250_000_000 * 1e9 / index_open) = 208_333_553
/// (same hand-derived value as strike_exposure_c1_tests).
const FLOOR_SHARES: u64 = 208_333_553;
/// floor_at_open = floor(FLOOR_SHARES * index_open / 1e9) = 249_999_999 — the
/// round-down round-trip loses 1 vs the 250_000_000 seed, so the order's live
/// backing is quantity − 249_999_999.
const LIVE_BACKING: u64 = 750_000_001;
/// floor(5e6 fee basis * 0.5 default rebate rate).
const MINT_REBATE: u64 = 2_500_000;
/// 1% spot drop: with the default near-zero SVI variance the digital collapses to
/// ~0, far below the liquidation threshold floor(249_999_999 * 1e9 / 0.85e9) =
/// 294_117_645.
const DROPPED_SPOT: u64 = 99_000_000_000;
/// Strictly after the setup's 99_000 source timestamp and <= clock 100_000;
/// the clock itself never advances, so the floor index stays at index_open.
const DROPPED_SOURCE_TS: u64 = 99_500;

#[test]
fun liquidated_order_pays_zero_once_and_only_once() {
    let (mut fx, expiry_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);

    // --- Baseline.
    let seeded_cash = test_constants::default_seeded_expiry_cash();
    helpers::check_market_cash(&market, helpers::expected_market_cash(seeded_cash, 0, 0));
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(test_constants::mint_deposit(), 0, 0, 0, 0),
    );

    // --- Mint the 2x semi-infinite order. Live backing is quantity minus the
    // floor at open (one unit below the seed from the round-down round-trip).
    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );
    assert_eq!(order::from_order_id(order_id).floor_shares(), FLOOR_SHARES);
    let cash_after_mint = seeded_cash + MINT_CONTRIBUTION + MINT_MIN_FEE;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_mint, LIVE_BACKING, MINT_REBATE),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );
    assert!(manager.has_position(expiry_id, order_id));

    // --- Drop the spot 1% and liquidate. The knockout removes the order's
    // full live terms (liability → 0 exactly), moves no cash, and leaves the
    // holder's manager untouched (tombstone persists until the holder redeems).
    fx.prepare_live_oracle_at(&market, &mut pyth, &mut bs, DROPPED_SPOT, DROPPED_SOURCE_TS);
    let liquidated = fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_id);
    assert!(liquidated);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_mint, 0, MINT_REBATE),
    );
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 1, 0, 0),
    );
    assert!(manager.has_position(expiry_id, order_id));

    // --- A second liquidation attempt on the same id returns false: the
    // tombstoned order is no longer in the active candidate set.
    assert!(!fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_id));

    // --- The holder clears the tombstone with a full close: exactly zero
    // payout, zero fee, position removed, market sheet bit-identical.
    let balance_before = manager.balance();
    let (closed_id, replacement) = fx.redeem(
        &config,
        &oracle_registry,
        &mut manager,
        &mut market,
        &pyth,
        &bs,
        order_id,
        test_constants::mint_quantity(),
    );
    assert_eq!(manager.balance(), balance_before);
    assert_eq!(closed_id, order_id);
    assert!(replacement.is_none());
    assert!(!manager.has_position(expiry_id, order_id));
    helpers::check_manager(
        &manager,
        expiry_id,
        helpers::expected_manager_state(POST_MINT_BALANCE, MINT_MIN_FEE, 0, 0, 0),
    );
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_mint, 0, MINT_REBATE),
    );
    // After the tombstone is cleared the id is gone from the liquidation
    // index entirely — still false, still no state change.
    assert!(!fx.liquidate_order(&config, &oracle_registry, &mut market, &pyth, &bs, order_id));

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    destroy(manager);
    fx.finish();
}
