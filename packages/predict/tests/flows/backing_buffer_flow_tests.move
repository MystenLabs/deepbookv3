// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Backing-buffer reserve pins for the minimal floor + gap-scaled buffer design.
///
/// These tests use production mint/redeem flows and hand-derived reserve values:
/// disjoint one-lot books have M = 1e9, Σ = 2e9, gap = 1e9, so the default
/// reserve is 1.25e9; overlapping books have gap = 0, so reserve = M = Σ.
#[test_only]
module deepbook_predict::backing_buffer_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_cash,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    plp::PoolVault,
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use fixed_math::math::{Self, float_scaling as float};
use std::unit_test::{assert_eq, destroy};

const QUANTITY: u64 = 1_000_000_000;
const LEVERAGED_QUANTITY: u64 = 2_000_000_000;
const LEVERAGED_MINT_FEE: u64 = 10_000_000;
const LEVERAGED_REDEEM_FEE: u64 = 5_000_000;
const REBATE_AFTER_ONE_MINT: u64 = 2_500_000;
const REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS: u64 = 7_500_000;

const DISJOINT_MAX_LIVE: u64 = QUANTITY;
const DISJOINT_GAP: u64 = QUANTITY;
const OVERLAPPING_RESERVE: u64 = 2 * QUANTITY;

const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const LEVERAGED_CONTRIBUTION: u64 = 500_000_000;
const LEVERAGED_LIVE_BACKING: u64 = 1_500_000_000;
const LEVERAGED_BUFFERED_RESERVE: u64 = 1_750_000_000;
const LEVERAGED_REQUIRED_CASH: u64 =
    LEVERAGED_BUFFERED_RESERVE + REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS;
const LEVERAGED_SUMMED_REQUIRED_CASH: u64 =
    QUANTITY + LEVERAGED_LIVE_BACKING + REBATE_AFTER_DOWN_AND_LEVERAGED_MINTS;
const LEVERAGED_PARTIAL_REDEEM: u64 = 250_000_000;
const LEVERAGED_PARTIAL_NET_PAYOUT: u64 = LEVERAGED_PARTIAL_REDEEM - LEVERAGED_REDEEM_FEE;
const LEVERAGED_PARTIAL_RESERVE: u64 = QUANTITY + 187_500_000;
const LEVERAGED_SURVIVOR_SETTLED_PAYOUT: u64 = 700_000_000;

const FIRST_ORDER_REQUIRED_CASH: u64 = QUANTITY + REBATE_AFTER_ONE_MINT;
const CAPITAL_EFFICIENT_POST_MINT_CASH: u64 = 1_800_000_000;
const CAPITAL_EFFICIENT_PRE_SECOND_MINT_CASH: u64 =
    CAPITAL_EFFICIENT_POST_MINT_CASH - LEVERAGED_CONTRIBUTION - LEVERAGED_MINT_FEE;
const ONE_X_ATM_MINT_CASH: u64 = 505_000_000;
const LEVERAGED_MINT_CASH: u64 = LEVERAGED_CONTRIBUTION + LEVERAGED_MINT_FEE;
const CAPITAL_EFFICIENT_INITIAL_CASH: u64 =
    CAPITAL_EFFICIENT_PRE_SECOND_MINT_CASH - ONE_X_ATM_MINT_CASH;
const BELOW_BUFFER_INITIAL_CASH: u64 = FIRST_ORDER_REQUIRED_CASH - ONE_X_ATM_MINT_CASH;
const EXACT_RESERVE_INITIAL_CASH: u64 =
    LEVERAGED_REQUIRED_CASH - ONE_X_ATM_MINT_CASH - LEVERAGED_MINT_CASH;

#[test]
fun disjoint_range_book_uses_default_gap_buffer() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let _down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    let _up = mint_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);

    // M = 1e9, Σ = 2e9, λ(default) * gap = 250e6, reserve = 1.25e9.
    assert_eq!(
        math::mul(config_constants::default_backing_buffer_lambda!(), DISJOINT_GAP),
        QUANTITY / 4,
    );
    assert_eq!(market.payout_liability(), disjoint_buffered_reserve());

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

#[test]
fun overlapping_range_book_has_zero_gap() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let _first = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    let _second = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);

    // Both orders win at the same settlement points: M = Σ = 2e9, gap = 0.
    assert_eq!(math::mul(config_constants::default_backing_buffer_lambda!(), 0), 0);
    assert_eq!(market.payout_liability(), OVERLAPPING_RESERVE);

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

#[test]
fun lambda_one_is_summed_backing_identity() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_cash(
        test_constants::default_seeded_expiry_cash(),
        option::some(float!()),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let _down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    let _up = mint_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);

    // λ = 1e9 makes mul(λ, gap) exactly gap under the fixed-point identity.
    assert_eq!(market.backing_buffer_lambda(), float!());
    assert_eq!(math::mul(float!(), DISJOINT_GAP), DISJOINT_GAP);
    assert_eq!(market.payout_liability(), 2 * QUANTITY);

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

#[test]
fun mint_succeeds_when_cash_between_buffered_reserve_and_old_sum() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_cash(
        CAPITAL_EFFICIENT_INITIAL_CASH,
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let _down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    assert_eq!(market.cash_balance(), CAPITAL_EFFICIENT_PRE_SECOND_MINT_CASH);
    let _up = mint_leveraged_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);

    // Cash is 1.8e9: above new required cash 1.7575e9, below old Σ
    // requirement 2.5075e9. The second mint would have failed under the old
    // summed reserve.
    assert_eq!(market.cash_balance(), CAPITAL_EFFICIENT_POST_MINT_CASH);
    assert_eq!(market.payout_liability(), LEVERAGED_BUFFERED_RESERVE);
    assert!(market.cash_balance() >= LEVERAGED_REQUIRED_CASH);
    assert!(market.cash_balance() < LEVERAGED_SUMMED_REQUIRED_CASH);

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun mint_below_buffered_reserve_aborts() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_cash(
        BELOW_BUFFER_INITIAL_CASH,
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let _down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    assert_eq!(market.cash_balance(), FIRST_ORDER_REQUIRED_CASH);

    // The 2x UP mint adds 510e6 cash, leaving 1.5125e9 cash against the
    // 1.7575e9 buffered required cash for the disjoint live orders.
    let _up = mint_leveraged_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    abort 999
}

#[test, expected_failure(abort_code = expiry_cash::EInsufficientCash)]
fun exact_reserve_full_close_hits_single_number_wall() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_cash(
        EXACT_RESERVE_INITIAL_CASH,
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (pyth, _vault, mut market, oracle, config) = fx.take_market(expiry_id, oracle_id);

    let down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    let _up = mint_leveraged_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    assert_eq!(market.cash_balance(), LEVERAGED_REQUIRED_CASH);

    // Closing the DOWN side would pay 495e6 net, but the remaining leveraged
    // UP reserve still needs 1.5e9 plus the higher rebate reserve.
    let (_closed, _replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        down,
        QUANTITY,
    );
    abort 999
}

#[test]
fun exact_reserve_partial_close_preserves_settlement_floor() {
    let (mut fx, expiry_id, oracle_id, mut manager) = setup_live_market_with_cash(
        EXACT_RESERVE_INITIAL_CASH,
        option::none(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);

    let down = mint_down(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    let up = mint_leveraged_up(&mut fx, &config, &mut manager, &mut market, &oracle, &pyth);
    assert_eq!(market.cash_balance(), LEVERAGED_REQUIRED_CASH);

    // Closing half of the leveraged UP side pays 250e6 gross, with 5e6 retained
    // as fee, and lowers the live reserve to 1.1875e9.
    let balance_before_close = manager.balance();
    let (_closed, replacement) = fx.redeem(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        up,
        QUANTITY,
    );
    let up_survivor = replacement.destroy_some();
    assert_eq!(manager.balance() - balance_before_close, LEVERAGED_PARTIAL_NET_PAYOUT);
    assert_eq!(market.cash_balance(), LEVERAGED_REQUIRED_CASH - LEVERAGED_PARTIAL_NET_PAYOUT);
    assert_eq!(market.payout_liability(), LEVERAGED_PARTIAL_RESERVE);

    fx.settle_oracle(&config, &mut oracle, &mut pyth, helpers::min_strike() + 1);
    let before_down_redeem = manager.balance();
    fx.redeem_settled(&config, &mut manager, &mut market, &oracle, &pyth, down, QUANTITY);
    assert_eq!(manager.balance() - before_down_redeem, 0);

    let before_up_redeem = manager.balance();
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        up_survivor,
        QUANTITY,
    );
    assert_eq!(manager.balance() - before_up_redeem, LEVERAGED_SURVIVOR_SETTLED_PAYOUT);
    assert_eq!(market.payout_liability(), 0);
    assert_eq!(
        market.cash_balance(),
        LEVERAGED_REQUIRED_CASH
            - LEVERAGED_PARTIAL_NET_PAYOUT
            - LEVERAGED_SURVIVOR_SETTLED_PAYOUT,
    );

    cleanup(fx, pyth, vault, market, oracle, config, manager);
}

fun mint_down(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): u256 {
    fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        QUANTITY,
        test_constants::leverage_one_x(),
    )
}

fun mint_up(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): u256 {
    fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        QUANTITY,
        test_constants::leverage_one_x(),
    )
}

fun mint_leveraged_up(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): u256 {
    fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    )
}

fun default_gap_buffer(gap: u64): u64 {
    math::mul(config_constants::default_backing_buffer_lambda!(), gap)
}

fun disjoint_buffered_reserve(): u64 {
    DISJOINT_MAX_LIVE + default_gap_buffer(DISJOINT_GAP)
}

fun setup_live_market_with_cash(
    seed_cash: u64,
    backing_buffer_lambda: Option<u64>,
): (helpers::Fixture, ID, ID, PredictManager) {
    let mut fx = helpers::setup_market_default();
    backing_buffer_lambda.do!(|value| fx.set_template_backing_buffer_lambda(value));
    let (expiry_id, oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let manager = fx.create_funded_manager(test_constants::default_manager_deposit());
    let (mut pyth, vault, mut market, mut oracle, config) = fx.take_market(expiry_id, oracle_id);
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());
    fx.seed_market_cash(&mut market, seed_cash);
    helpers::return_market(pyth, vault, market, oracle, config);
    fx.scenario_mut().next_tx(test_constants::admin());
    (fx, expiry_id, oracle_id, manager)
}

fun cleanup(
    fx: helpers::Fixture,
    pyth: PythSource,
    vault: PoolVault,
    market: ExpiryMarket,
    oracle: MarketOracle,
    config: ProtocolConfig,
    manager: PredictManager,
) {
    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
