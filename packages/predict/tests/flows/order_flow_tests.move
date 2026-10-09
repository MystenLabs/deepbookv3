// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict's order-flow primitives driven directly with a test witness, the way
/// the order-flow companion drives them: the witness allowlist, admission and
/// its timing gates, commit's price provenance, mint and sell fills and their
/// refund reasons with the escrow split, the canonical receipt stages across
/// repeated partial sells, a refund and a re-sell, and a release after a
/// partial close, the settled payout, and USDC's deny list: a denied receive
/// address refuses the fill (reason 9) and skips the payout, a denied builder's
/// or referrer's fee stays in market cash, and a global pause denies everyone.
/// The tests hand Predict escrow directly; the companion takes it from the
/// account.
///
/// Arithmetic, independent of the contract (the fixture the v4 queue suites
/// used): at the 100e9 live price the `(100, +inf]` strike is at the money, the
/// fixture's minimum fee is 0.005 per unit of quantity and its base fee rounds
/// the Bernoulli term to zero, the ramp is 1 this far from expiry, inventory
/// impact is off, and no builder or referrer is set. Every probability in the
/// digital's 499_993_669..499_993_711 (1e-9) band floors to the premiums and
/// redeem values below. The market's minimum entry probability is 0.01 and its
/// backing-buffer lambda 0.31.
#[test_only]
module deepbook_predict::order_flow_tests;

use account::account;
use deepbook_predict::{
    constants,
    expiry_market::{Self, OrderReceipt},
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle},
    order,
    protocol_config,
    test_constants,
    usdc_deny_list
};
use deepbook_predict_math::lazer_price::{Self, LazerPrice};
use std::unit_test::{assert_eq, destroy};
use sui::{
    balance::{Self, Balance},
    deny_list::{Self, DenyList},
    test_scenario::{Scenario, return_shared}
};
use usdc::usdc::USDC;

/// The companion witness these tests allowlist.
public struct TestFlow() has drop;

/// A witness no one allowlisted.
public struct OtherFlow() has drop;

const QUANTITY: u64 = 4_000_000;
/// floor(p * 4m): 1_999_974.68..1_999_974.84 across the band.
const PREMIUM: u64 = 1_999_974;
/// 0.005 * 4m.
const TRADING_FEE: u64 = 20_000;
/// PREMIUM + TRADING_FEE, the fill's all-in cost with no subsidy.
const ALL_IN_COST: u64 = 2_019_974;
const ORDER_FEE: u64 = 20_000;
/// The fill's cost cap, above ALL_IN_COST.
const BUDGET: u64 = 3_000_000;
/// ceil(4m * (1 - 0.01)) + 1.
const MINT_CASH_NEED: u64 = 3_960_001;
/// A half close: floor(p * 2m) = 999_987, fee 0.005 * 2m = 10_000, so the
/// proceeds are 989_987.
const HALF: u64 = 2_000_000;
const HALF_REDEEM: u64 = 999_987;
const HALF_FEE: u64 = 10_000;
const HALF_PROCEEDS: u64 = 989_987;
/// ceil(2m * (1 - 0.31)) + 1.
const HALF_CASH_NEED: u64 = 1_380_001;
/// A quarter close: floor(p * 1m) = 499_993, fee 5_000, proceeds 494_993.
const QUARTER: u64 = 1_000_000;
const QUARTER_FEE: u64 = 5_000;
const QUARTER_PROCEEDS: u64 = 494_993;
const SVI_MAX_AGE_MS: u64 = 60_000;
const CHANNEL_50MS: u8 = 2;
const CHANNEL_200MS: u8 = 3;
const REAL_TIME_CHANNEL: u8 = 1;
const TICK_200MS: u64 = 200;
/// The fixture clock is 120_000; τ is the 200 ms tick a second later.
const TAU: u64 = 121_000;
const DEADLINE_AFTER_TAU_MS: u64 = 5_000;
const SELL_TAU: u64 = 122_000;
const SECOND_SELL_TAU: u64 = 123_000;
const THIRD_SELL_TAU: u64 = 124_000;
const US_PER_MS: u64 = 1_000;
const NO_PROBABILITY_CAP: u64 = 18_446_744_073_709_551_615;
/// A 0.6 cap the at-the-money admission dry run passes.
const MAX_PROBABILITY: u64 = 600_000_000;
/// A committed spot that moves the digital to about 0.736, above the 0.6 cap:
/// the fixture surface has total variance a = 1e-9 (sqrt 3.1623e-5), so d2 =
/// ln(100.002 / 100) / 3.1623e-5 = 0.6324.
const LIMIT_SPOT: u64 = 100_002_000_000;
/// A settlement spot inside `(100, +inf]`, so the position wins its quantity.
const WINNING_SETTLEMENT: u64 = 101_000_000_000;
const OTHER_FEED_ID: u32 = 2;
/// Market cash a 4m fill adds: PREMIUM + TRADING_FEE + ORDER_FEE.
const MINT_CASH: u64 = 2_039_974;
/// 10 USDC of sponsored incentives.
const INCENTIVES: u64 = 10_000_000;
/// The default 20% subsidy rate on the 20_000 subsidy bound.
const RESERVED_SUBSIDY: u64 = 4_000;
/// ALL_IN_COST - RESERVED_SUBSIDY: the trader pays the fee less the subsidy.
const SUBSIDIZED_COST: u64 = 2_015_974;
/// min(0.1 * 20_000, 0.005 * 4m).
const BUILDER_FEE: u64 = 2_000;
/// The default 10% referral share of the trader-paid 20_000 fee.
const REFERRAL_FEE: u64 = 2_000;
const BUILDER_CODE_INDEX: u64 = 0;
/// One 4m fill owes 4m and brings MINT_CASH, so it fills exactly when cash
/// before the fill is at least 4_000_000 - 2_039_974 = 1_960_026.
const BOUNDARY_CASH: u64 = 1_960_026;
/// A settlement spot below the 100 strike, so the `(100, +inf]` position loses.
const LOSING_SETTLEMENT: u64 = 99_000_000_000;
/// A half close's builder fee: min(0.1 * HALF_FEE, 0.005 * 2m) = min(1_000, 10_000).
const HALF_BUILDER_FEE: u64 = 1_000;
/// HALF_REDEEM - HALF_FEE - HALF_BUILDER_FEE.
const HALF_PROCEEDS_WITH_BUILDER: u64 = 988_987;

// === Mints ===

#[test]
fun a_mint_admits_commits_and_fills_into_a_canonical_open_receipt() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let (waiting, nodes, min_probability) = helpers::market(&market).order_flow_state();
    assert_eq!(waiting, MINT_CASH_NEED);
    // Admission pinned the finite boundary node.
    assert_eq!(nodes, 1);
    assert_eq!(min_probability, 10_000_000);
    let (
        market_id,
        stage,
        _,
        order_id,
        feed_id,
        cash_need,
        subsidy_bound,
        _,
    ) = expiry_market::receipt_info(
        &receipt,
    );
    assert_eq!(market_id, helpers::market(&market).id());
    assert_eq!(stage, constants::receipt_stage_mint!());
    assert_eq!(order_id, 0);
    assert_eq!(feed_id, test_constants::pyth_feed_id());
    assert_eq!(cash_need, MINT_CASH_NEED);
    // The t₀ trading fee, below the budget.
    assert_eq!(subsidy_bound, TRADING_FEE);

    // The market holds no incentives, so the reservation is empty.
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    assert_eq!(subsidy.value(), 0);
    let cash_before = helpers::market(&market).cash_balance();
    let (reason, kept, change, quantity, amount, fee, builder, referral, used, impact) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );
    assert_eq!(reason, 0);
    assert_eq!(quantity, QUANTITY);
    assert_eq!(amount, ALL_IN_COST);
    assert_eq!(fee, TRADING_FEE);
    assert_eq!(builder, 0);
    assert_eq!(referral, 0);
    assert_eq!(used, 0);
    assert_eq!(impact, 0);
    // The unused budget comes back; the order fee stays in market cash.
    assert_eq!(change.value(), BUDGET - ALL_IN_COST);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + PREMIUM + TRADING_FEE + ORDER_FEE,
    );
    assert_eq!(helpers::market(&market).required_cash(), QUANTITY);
    let (waiting, nodes, _) = helpers::market(&market).order_flow_state();
    assert_eq!(waiting, 0);
    // The fill reused the pinned node.
    assert_eq!(nodes, 1);

    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    let (_, _, _, order_id, _, _, _, _) = expiry_market::receipt_info(&receipt);
    let minted = order::from_id(order_id);
    assert_eq!(minted.lower_tick(), helpers::strike_tick());
    assert_eq!(minted.higher_tick(), helpers::pos_inf_tick());
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(receipt);
    finish(fx, market, account);
}

/// Reason 1: the committed price moves the order past its own probability cap.
/// The order fee stays in market cash and the budget comes back.
#[test]
fun a_mint_past_its_limits_at_the_tick_refunds_and_keeps_the_fee() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, MAX_PROBABILITY);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, LIMIT_SPOT);
    let cash_before = helpers::market(&market).cash_balance();
    let (reason, kept, change, quantity, amount, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );
    assert_eq!(reason, constants::fill_reason_limits!());
    assert!(kept.is_none());
    assert_eq!(quantity, 0);
    assert_eq!(amount, 0);
    assert_eq!(change.value(), BUDGET);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + ORDER_FEE);
    // The refund unpinned and pruned the emptied node and released the need.
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(change);
    finish(fx, market, account);
}

/// Reason 5: a fill at or past the deadline refunds the whole escrow.
#[test]
fun a_mint_at_its_deadline_refunds_the_whole_escrow() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    fx.set_clock_for_testing(TAU + DEADLINE_AFTER_TAU_MS);
    let cash_before = helpers::market(&market).cash_balance();
    let (reason, kept, change, _, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );
    assert_eq!(reason, constants::fill_reason_deadline!());
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(change);
    finish(fx, market, account);
}

/// The companion's own refunds release a mint receipt without filling it. A
/// deadline release hands back the budget and the order fee whole.
#[test]
fun releasing_a_mint_unpins_prunes_and_consumes_it() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let cash_before = helpers::market(&market).cash_balance();
    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, balance::zero()),
        constants::fill_reason_deadline!(),
        true,
    );
    assert!(kept.is_none());
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(change);
    finish(fx, market, account);
}

/// A release with reason 1 or 2 keeps the order fee in market cash, as a
/// refund out of `try_fill` does, and hands back the rest of the escrow.
#[test]
fun releasing_with_reason_1_keeps_the_order_fee_in_market_cash() {
    let (mut fx, mut market, mut account) = setup();
    fund_incentives(&mut fx, &mut market);
    let incentives_before = helpers::market(&market).fee_incentive_balance();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        constants::fill_reason_limits!(),
        true,
    );

    kept.destroy_none();
    assert_eq!(change.value(), BUDGET);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + ORDER_FEE);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), incentives_before);
    assert_flow_state(&market, 0, 0);
    destroy(change);
    finish(fx, market, account);
}

/// A sell released with reason 2 keeps its order fee and reopens whole.
#[test]
fun releasing_a_sell_with_reason_2_keeps_the_fee_and_reopens_it() {
    let (mut fx, mut market, mut account, mut receipt) = filled_mint();
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    admit_sell(&mut fx, &mut market, &mut account, &mut receipt, HALF, 0, SELL_TAU);
    let cash_before = helpers::market(&market).cash_balance();

    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(ORDER_FEE, balance::zero()),
        constants::fill_reason_admission!(),
        true,
    );

    assert_eq!(change.value(), 0);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + ORDER_FEE);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    assert_waiting(&market, 0);
    destroy(receipt);
    destroy(change);
    finish(fx, market, account);
}

/// The published previews price like a queued fill at the clock, with no
/// congestion penalty.
#[test]
fun quote_mint_prices_like_a_queued_fill_at_the_clock() {
    let (mut fx, market, account) = setup();
    let pricer = fx.load_pricer_bundle(&market);
    let (clock, ctx) = fx.clock_and_ctx();
    let quote = helpers::market(&market).quote_mint(
        helpers::config(&market),
        &pricer,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        0,
        QUANTITY,
        true,
        clock,
        ctx,
    );
    assert_eq!(quote.quantity(), QUANTITY);
    assert_eq!(quote.premium(), PREMIUM);
    assert_eq!(quote.trading_fee(), TRADING_FEE);
    assert_eq!(quote.penalty_fee(), 0);
    assert_eq!(quote.all_in_cost(), ALL_IN_COST);
    finish(fx, market, account);
}

// === Sells ===

/// Two partial closes and then a full close of the same position. Each partial
/// close leaves the held quantity less the closed quantity in a canonical open
/// receipt, and the full close consumes it.
#[test]
fun repeated_partial_sells_shrink_the_held_position_then_close_it() {
    let (mut fx, mut market, mut account, mut receipt) = filled_mint();

    let (proceeds, fee, kept) = sell(
        &mut fx,
        &mut market,
        &mut account,
        receipt,
        HALF,
        TAU,
        SELL_TAU,
    );
    assert_eq!(proceeds, HALF_PROCEEDS);
    assert_eq!(fee, HALF_FEE);
    receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY - HALF);

    let (proceeds, fee, kept) = sell(
        &mut fx,
        &mut market,
        &mut account,
        receipt,
        QUARTER,
        SELL_TAU,
        SECOND_SELL_TAU,
    );
    assert_eq!(proceeds, QUARTER_PROCEEDS);
    assert_eq!(fee, QUARTER_FEE);
    receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUARTER);

    let (proceeds, _, kept) = sell(
        &mut fx,
        &mut market,
        &mut account,
        receipt,
        QUARTER,
        SECOND_SELL_TAU,
        THIRD_SELL_TAU,
    );
    assert_eq!(proceeds, QUARTER_PROCEEDS);
    assert!(kept.is_none());
    kept.destroy_none();
    assert_eq!(helpers::market(&market).required_cash(), 0);
    assert_waiting(&market, 0);
    finish(fx, market, account);
}

/// A sell that reaches its deadline unfilled returns the receipt to canonical
/// open with the whole position, and the position sells again afterwards.
#[test]
fun a_refunded_sell_returns_the_whole_position_and_sells_again() {
    let (mut fx, mut market, mut account, mut receipt) = filled_mint();
    let (_, _, _, held_order_id, _, _, _, _) = expiry_market::receipt_info(&receipt);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    admit_sell(&mut fx, &mut market, &mut account, &mut receipt, HALF, 0, SELL_TAU);
    let (waiting, _, _) = helpers::market(&market).order_flow_state();
    assert_eq!(waiting, HALF_CASH_NEED);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, SELL_TAU, live_price());
    fx.set_clock_for_testing(SELL_TAU + DEADLINE_AFTER_TAU_MS);
    let (reason, kept, change, quantity, amount, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(ORDER_FEE, subsidy),
    );
    assert_eq!(reason, constants::fill_reason_deadline!());
    assert_eq!(quantity, 0);
    assert_eq!(amount, 0);
    // A deadline refund returns the order fee.
    assert_eq!(change.value(), ORDER_FEE);
    destroy(change);
    receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    let (_, _, _, order_id, _, _, _, _) = expiry_market::receipt_info(&receipt);
    assert_eq!(order_id, held_order_id);
    assert_waiting(&market, 0);

    let resell_tau = SELL_TAU + DEADLINE_AFTER_TAU_MS + 1_000;
    let (proceeds, _, kept) = sell(
        &mut fx,
        &mut market,
        &mut account,
        receipt,
        HALF,
        SELL_TAU + DEADLINE_AFTER_TAU_MS,
        resell_tau,
    );
    assert_eq!(proceeds, HALF_PROCEEDS);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY - HALF);
    destroy(receipt);
    finish(fx, market, account);
}

/// A release after a partial close puts back the remainder, not the original
/// size.
#[test]
fun releasing_a_sell_after_a_partial_close_keeps_the_remainder() {
    let (mut fx, mut market, mut account, receipt) = filled_mint();
    let (_, _, kept) = sell(
        &mut fx,
        &mut market,
        &mut account,
        receipt,
        HALF,
        TAU,
        SELL_TAU,
    );
    let mut receipt = kept.destroy_some();
    let (_, _, _, remainder_order_id, _, _, _, _) = expiry_market::receipt_info(&receipt);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), SELL_TAU);
    admit_sell(&mut fx, &mut market, &mut account, &mut receipt, QUARTER, 0, SECOND_SELL_TAU);
    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(ORDER_FEE, balance::zero()),
        constants::fill_reason_deadline!(),
        false,
    );
    assert_eq!(change.value(), ORDER_FEE);
    destroy(change);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY - HALF);
    let (_, _, _, order_id, _, _, _, _) = expiry_market::receipt_info(&receipt);
    assert_eq!(order_id, remainder_order_id);
    assert_waiting(&market, 0);
    destroy(receipt);
    finish(fx, market, account);
}

/// The sell fill pays redeem value less the fees; the quote at the clock prices
/// the same close.
#[test]
fun quote_close_prices_the_close_a_sell_fills() {
    let (mut fx, mut market, account, receipt) = filled_mint();
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    let pricer = fx.load_pricer_bundle(&market);
    let quote = helpers::market(&market).quote_close(
        &pricer,
        &receipt,
        HALF,
        option::none(),
        fx.clock(),
    );
    assert_eq!(quote.redeem_proceeds(), HALF_PROCEEDS);
    assert_eq!(quote.redeem_trading_fee(), HALF_FEE);
    assert_eq!(quote.redeem_proceeds() + quote.redeem_trading_fee(), HALF_REDEEM);
    destroy(receipt);
    finish(fx, market, account);
}

// === Settlement ===

#[test]
fun a_settled_winner_is_paid_its_quantity_once() {
    let (mut fx, mut market, account, receipt) = filled_mint_at(test_constants::short_expiry_ms());
    settle(&mut fx, &mut market, WINNING_SETTLEMENT);
    let cash_before = helpers::market(&market).cash_balance();
    let (payout, kept) = pay_settled(&mut fx, &mut market, receipt);
    assert_eq!(payout, QUANTITY);
    assert!(kept.is_none());
    kept.destroy_none();
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - QUANTITY);
    finish(fx, market, account);
}

/// A payout the market cannot cover changes nothing and hands the receipt back.
#[test]
fun a_settled_payout_the_market_cannot_cover_returns_the_receipt() {
    let (mut fx, mut market, account, receipt) = filled_mint_at(test_constants::short_expiry_ms());
    settle(&mut fx, &mut market, WINNING_SETTLEMENT);
    let cash = helpers::market(&market).cash_balance();
    let taken = helpers::market_mut(&mut market).take_market_cash_for_testing(
        cash - QUANTITY + 1,
    );
    let (payout, kept) = pay_settled(&mut fx, &mut market, receipt);
    assert_eq!(payout, QUANTITY);
    assert_eq!(helpers::market(&market).cash_balance(), QUANTITY - 1);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    destroy(taken);
    destroy(receipt);
    finish(fx, market, account);
}

// === Authority ===

#[test, expected_failure(abort_code = protocol_config::EOrderFlowNotAllowed)]
fun admitting_with_a_witness_no_one_allowlisted_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let (em, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, _) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let holder = wrapper.load_account_mut(account::generate_auth(ctx));
    let receipt = expiry_market::admit_mint(
        OtherFlow(),
        em,
        config,
        holder,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        constants::mint_kind_exact_quantity!(),
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        0,
        0,
        NO_PROBABILITY_CAP,
        BUDGET,
        ORDER_FEE,
        SVI_MAX_AGE_MS,
        CHANNEL_200MS,
        TAU,
        TAU + DEADLINE_AFTER_TAU_MS,
        clock,
        ctx,
    );
    destroy(receipt);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EOrderFlowNotAllowed)]
fun filling_after_the_witness_is_removed_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    set_witness(&mut fx, &mut market, false);
    let (_, kept, change, _, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );
    destroy(kept);
    destroy(change);
    abort 999
}

/// Removing the witness stops fills only; the receipt still drains.
#[test]
fun release_still_drains_after_the_witness_is_removed() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    set_witness(&mut fx, &mut market, false);
    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, balance::zero()),
        constants::fill_reason_deadline!(),
        true,
    );
    kept.destroy_none();
    destroy(change);
    assert_flow_state(&market, 0, 0);
    finish(fx, market, account);
}

#[test, expected_failure(abort_code = expiry_market::ENotRecordOwner)]
fun selling_another_accounts_position_aborts() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    let bob = fx.create_funded_manager_as(test_constants::bob(), test_constants::mint_deposit());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.scenario_mut().next_tx(test_constants::bob());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut bob_account = fx.take_account_bundle(&bob);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    admit_sell(&mut fx, &mut market, &mut bob_account, &mut receipt, HALF, 0, SELL_TAU);
    abort 999
}

// === Admission timing ===

#[test]
fun admission_accepts_tau_on_the_50ms_grid() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit_on(&mut fx, &mut market, &mut account, CHANNEL_50MS, TAU + 50);
    let (_, _, _, _, _, _, _, _, _, _, tau, _, channel) = receipt.receipt_state_for_testing();
    assert_eq!(tau, TAU + 50);
    assert_eq!(channel, CHANNEL_50MS);
    destroy(receipt);
    finish(fx, market, account);
}

#[test, expected_failure(abort_code = expiry_market::EInvalidOrderTiming)]
fun admission_on_an_unsupported_channel_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit_on(&mut fx, &mut market, &mut account, REAL_TIME_CHANNEL, TAU);
    destroy(receipt);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EInvalidOrderTiming)]
fun admission_off_the_channel_grid_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit_on(&mut fx, &mut market, &mut account, CHANNEL_200MS, TAU + 100);
    destroy(receipt);
    abort 999
}

/// The fixture clock is 120_000, so τ 119_600 is two 200 ms ticks in the past.
#[test, expected_failure(abort_code = expiry_market::EInvalidOrderTiming)]
fun admission_with_tau_more_than_a_tick_before_now_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit_on(
        &mut fx,
        &mut market,
        &mut account,
        CHANNEL_200MS,
        test_constants::now_ms() - 2 * TICK_200MS,
    );
    destroy(receipt);
    abort 999
}

// === Commit provenance ===

/// The backup tick, one channel tick after τ, commits, and the fill prices at it.
#[test]
fun commit_accepts_the_backup_tick() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let backup_ms = TAU + TICK_200MS;
    fx.set_clock_for_testing(backup_ms);
    let generation_us = (TAU + 150) * US_PER_MS;
    let subsidy = commit_price(
        &fx,
        &mut market,
        &mut receipt,
        &price(test_constants::pyth_feed_id(), CHANNEL_200MS, backup_ms * US_PER_MS, generation_us),
    );
    let (_, _, _, _, _, _, _, _, spot, tick, _, _, _) = receipt.receipt_state_for_testing();
    assert_eq!(spot, live_price());
    assert_eq!(tick, backup_ms);
    destroy(subsidy);
    destroy(receipt);
    finish(fx, market, account);
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun commit_of_another_feed_aborts() {
    commit_bad_price(OTHER_FEED_ID, CHANNEL_200MS, TAU * US_PER_MS, TAU * US_PER_MS, TAU);
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun commit_on_another_channel_aborts() {
    commit_bad_price(
        test_constants::pyth_feed_id(),
        CHANNEL_50MS,
        TAU * US_PER_MS,
        TAU * US_PER_MS,
        TAU,
    );
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun commit_of_an_envelope_off_tau_and_the_backup_aborts() {
    let envelope_us = (TAU + 100) * US_PER_MS;
    commit_bad_price(
        test_constants::pyth_feed_id(),
        CHANNEL_200MS,
        envelope_us,
        envelope_us,
        TAU + TICK_200MS,
    );
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun commit_of_a_price_generated_before_tau_aborts() {
    commit_bad_price(
        test_constants::pyth_feed_id(),
        CHANNEL_200MS,
        TAU * US_PER_MS,
        TAU * US_PER_MS - 1,
        TAU,
    );
}

#[test, expected_failure(abort_code = expiry_market::EWrongPrice)]
fun commit_of_an_envelope_after_now_aborts() {
    commit_bad_price(
        test_constants::pyth_feed_id(),
        CHANNEL_200MS,
        TAU * US_PER_MS,
        TAU * US_PER_MS,
        TAU - 1,
    );
}

#[test, expected_failure(abort_code = expiry_market::EWrongStage)]
fun committing_twice_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let first = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let second = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    destroy(first);
    destroy(second);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EWrongStage)]
fun filling_before_commit_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let (_, kept, change, _, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, balance::zero()),
    );
    destroy(kept);
    destroy(change);
    abort 999
}

// === Escrow ===

#[test, expected_failure(abort_code = expiry_market::EEscrowMismatch)]
fun filling_with_short_escrow_aborts() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let (_, kept, change, _, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE - 1, subsidy),
    );
    destroy(kept);
    destroy(change);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EEscrowMismatch)]
fun releasing_with_escrow_short_of_the_order_aborts() {
    let (mut fx, mut market, mut account) = setup();
    fund_incentives(&mut fx, &mut market);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE - 1, subsidy),
        constants::fill_reason_deadline!(),
        true,
    );
    destroy(kept);
    destroy(change);
    abort 999
}

// === Accounting ===

/// The reservation leaves the incentives at commit and the fill uses all of
/// it: the market gains the whole fee, and the escrow handed back is the unused
/// budget. Escrow in 3_000_000 + 20_000 + 4_000 = 3_024_000 = MINT_CASH
/// 2_039_974 + change 984_026.
#[test]
fun a_subsidized_fill_uses_the_reservation_once() {
    let (mut fx, mut market, mut account) = setup();
    fund_incentives(&mut fx, &mut market);
    let incentives_before = helpers::market(&market).fee_incentive_balance();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    assert_eq!(subsidy.value(), RESERVED_SUBSIDY);
    assert_eq!(
        helpers::market(&market).fee_incentive_balance(),
        incentives_before - RESERVED_SUBSIDY,
    );
    let cash_before = helpers::market(&market).cash_balance();

    let (reason, kept, change, _, amount, fee, _, _, used, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, 0);
    assert_eq!(used, RESERVED_SUBSIDY);
    assert_eq!(fee, TRADING_FEE);
    assert_eq!(amount, SUBSIDIZED_COST);
    assert_eq!(change.value(), BUDGET - SUBSIDIZED_COST);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH);
    assert_eq!(
        helpers::market(&market).fee_incentive_balance(),
        incentives_before - RESERVED_SUBSIDY,
    );
    assert_flow_state(&market, 0, 1);
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    finish(fx, market, account);
}

/// A refund at the tick returns the whole reservation to the incentives.
#[test]
fun a_refund_at_the_tick_returns_the_reservation() {
    let (mut fx, mut market, mut account) = setup();
    fund_incentives(&mut fx, &mut market);
    let incentives_before = helpers::market(&market).fee_incentive_balance();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, MAX_PROBABILITY);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, LIMIT_SPOT);
    let cash_before = helpers::market(&market).cash_balance();

    let (reason, kept, change, _, _, _, _, _, used, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, constants::fill_reason_limits!());
    assert_eq!(used, 0);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), incentives_before);
    // Reason 1 keeps the order fee; the budget comes back.
    assert_eq!(change.value(), BUDGET);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + ORDER_FEE);
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(change);
    finish(fx, market, account);
}

/// A release returns the reservation the companion escrowed.
#[test]
fun releasing_a_committed_mint_returns_the_reservation() {
    let (mut fx, mut market, mut account) = setup();
    fund_incentives(&mut fx, &mut market);
    let incentives_before = helpers::market(&market).fee_incentive_balance();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());

    let (kept, change) = release(
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        constants::fill_reason_deadline!(),
        true,
    );

    kept.destroy_none();
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), incentives_before);
    assert_flow_state(&market, 0, 0);
    destroy(change);
    finish(fx, market, account);
}

/// The builder fee comes out of the escrow and leaves the market.
#[test]
fun a_builder_fee_comes_out_of_the_escrow() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let (reason, kept, change, _, amount, _, builder, referral, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, 0);
    assert_eq!(builder, BUILDER_FEE);
    assert_eq!(referral, 0);
    assert_eq!(amount, ALL_IN_COST + BUILDER_FEE);
    assert_eq!(change.value(), BUDGET - ALL_IN_COST - BUILDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH);
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    finish(fx, market, account);
}

/// The referral comes out of the trading fee, not the trader's cost, and
/// leaves the market.
#[test]
fun a_referral_fee_comes_out_of_the_trading_fee() {
    let (mut fx, expiry_id, trader, _) = referred_setup();
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let (reason, kept, change, _, amount, _, _, referral, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, 0);
    assert_eq!(referral, REFERRAL_FEE);
    assert_eq!(amount, ALL_IN_COST);
    assert_eq!(change.value(), BUDGET - ALL_IN_COST);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH - REFERRAL_FEE);
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    finish(fx, market, account);
}

/// Reason 8 at its boundary: with cash before the fill at exactly
/// BOUNDARY_CASH the fill lands cash on required cash and fills.
#[test]
fun a_fill_landing_cash_on_required_cash_fills() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let taken = drain_cash_to(&mut market, BOUNDARY_CASH);

    let (reason, kept, change, _, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, 0);
    assert_eq!(helpers::market(&market).cash_balance(), QUANTITY);
    assert_eq!(helpers::market(&market).required_cash(), QUANTITY);
    helpers::assert_market_backed_bundle(&market);
    destroy(taken);
    destroy(change);
    destroy(kept);
    finish(fx, market, account);
}

/// One unit less and the fill would leave cash below required cash: reason 8
/// returns the whole escrow, order fee included, moves no market cash, and
/// takes the order out of the ledger.
#[test]
fun a_fill_one_unit_short_of_required_cash_refunds_with_reason_8() {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let taken = drain_cash_to(&mut market, BOUNDARY_CASH - 1);

    let (reason, kept, change, quantity, _, _, _, _, _, _) = fill(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );

    assert_eq!(reason, constants::fill_reason_no_cash!());
    assert_eq!(quantity, 0);
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), BOUNDARY_CASH - 1);
    assert_eq!(helpers::market(&market).required_cash(), 0);
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(taken);
    destroy(change);
    finish(fx, market, account);
}

// === USDC deny list ===

/// Reason 9: the trader's receive address is denied, so the fill is refused
/// before anything moves. The whole escrow comes back, order fee included,
/// market cash is untouched, and the order leaves the ledger.
#[test]
fun a_mint_for_a_denied_receive_address_refunds_with_reason_9() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let trader_address = receive_address(&mut account);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::deny(scenario, trader_address),
    );
    let cash_before = helpers::market(&market).cash_balance();
    let deny_list = usdc_deny_list::take(fx.scenario_mut());

    let (reason, kept, change, quantity, amount, _, _, _, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        &deny_list,
    );

    assert_eq!(reason, constants::fill_reason_recipient_denied!());
    assert_eq!(quantity, 0);
    assert_eq!(amount, 0);
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    assert_flow_state(&market, 0, 0);
    kept.destroy_none();
    destroy(change);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A sell for a denied receive address is refused the same way: the order fee
/// comes back and the receipt reopens whole, with nothing paid out.
#[test]
fun a_sell_for_a_denied_receive_address_refunds_with_reason_9_and_reopens() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let trader_address = receive_address(&mut account);
    let mut receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    admit_sell(&mut fx, &mut market, &mut account, &mut receipt, HALF, 0, SELL_TAU);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, SELL_TAU, live_price());
    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::deny(scenario, trader_address),
    );
    let cash_before = helpers::market(&market).cash_balance();

    let deny_list = usdc_deny_list::take(fx.scenario_mut());
    let (reason, kept, change, quantity, amount, _, _, _, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(ORDER_FEE, subsidy),
        &deny_list,
    );

    assert_eq!(reason, constants::fill_reason_recipient_denied!());
    assert_eq!(quantity, 0);
    assert_eq!(amount, 0);
    assert_eq!(change.value(), ORDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    assert_eq!(helpers::market(&market).required_cash(), QUANTITY);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    assert_waiting(&market, 0);
    destroy(receipt);
    destroy(change);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A denied builder's fee is not sent: it stays in market cash and the mint
/// fills. The trader is charged as usual and the fill reports the fee.
#[test]
fun a_denied_builders_mint_fee_stays_in_market_cash() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    let code_id = fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    usdc_deny_list::deny(fx.scenario_mut(), code_id.to_address());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let deny_list = usdc_deny_list::take(fx.scenario_mut());
    let (reason, kept, change, _, amount, _, builder, _, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        &deny_list,
    );

    assert_eq!(reason, 0);
    assert_eq!(builder, BUILDER_FEE);
    assert_eq!(amount, ALL_IN_COST + BUILDER_FEE);
    assert_eq!(change.value(), BUDGET - ALL_IN_COST - BUILDER_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH + BUILDER_FEE);
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A sell's builder fee leaves with the trading fee's split, so a denied
/// builder's fee stays in market cash and never reaches the trader: the
/// proceeds are the redeem value less both fees, and market cash gains the
/// order fee, the trading fee, and the builder fee and pays the redeem value.
#[test]
fun a_denied_builders_sell_fee_stays_in_market_cash() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::default_expiry_ms());
    let code_id = fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    usdc_deny_list::deny(fx.scenario_mut(), code_id.to_address());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    admit_sell(&mut fx, &mut market, &mut account, &mut receipt, HALF, 0, SELL_TAU);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, SELL_TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let deny_list = usdc_deny_list::take(fx.scenario_mut());
    let (reason, kept, change, quantity, proceeds, fee, builder, _, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(ORDER_FEE, subsidy),
        &deny_list,
    );

    assert_eq!(reason, 0);
    assert_eq!(quantity, HALF);
    assert_eq!(fee, HALF_FEE);
    assert_eq!(builder, HALF_BUILDER_FEE);
    assert_eq!(proceeds, HALF_PROCEEDS_WITH_BUILDER);
    assert_eq!(change.value(), 0);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + ORDER_FEE + HALF_FEE + HALF_BUILDER_FEE - HALF_REDEEM,
    );
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A denied referrer's share stays in market cash: the trader's cost is
/// unchanged and the market keeps the whole trading fee.
#[test]
fun a_denied_referrers_fee_stays_in_market_cash() {
    let (mut fx, expiry_id, trader, referrer) = referred_setup();
    fx.scenario_mut().next_tx(referrer.owner());
    let mut referrer_account = fx.take_account_bundle(&referrer);
    let referrer_address = receive_address(&mut referrer_account);
    helpers::return_account_bundle(referrer_account);
    usdc_deny_list::deny(fx.scenario_mut(), referrer_address);
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, TAU, live_price());
    let cash_before = helpers::market(&market).cash_balance();

    let deny_list = usdc_deny_list::take(fx.scenario_mut());
    let (reason, kept, change, _, amount, _, _, referral, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        &deny_list,
    );

    assert_eq!(reason, 0);
    assert_eq!(referral, REFERRAL_FEE);
    assert_eq!(amount, ALL_IN_COST);
    assert_eq!(change.value(), BUDGET - ALL_IN_COST);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH);
    helpers::assert_market_backed_bundle(&market);
    destroy(change);
    destroy(kept);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A denied winner's payout is skipped with nothing moved, and paid once the
/// denial lifts.
#[test]
fun a_denied_winners_payout_is_skipped_until_the_denial_lifts() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let trader_address = receive_address(&mut account);
    let receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    settle(&mut fx, &mut market, WINNING_SETTLEMENT);
    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::deny(scenario, trader_address),
    );
    let cash_before = helpers::market(&market).cash_balance();
    let deny_list = usdc_deny_list::take(fx.scenario_mut());

    let (payout, kept) = pay_settled_against(&mut fx, &mut market, receipt, &deny_list);
    assert_eq!(payout, QUANTITY);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    assert_eq!(helpers::market(&market).payout_liability(), QUANTITY);
    let receipt = kept.destroy_some();
    assert_canonical_open(&receipt, QUANTITY);
    return_shared(deny_list);

    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::undeny(scenario, trader_address),
    );
    let deny_list = usdc_deny_list::take(fx.scenario_mut());
    let (payout, kept) = pay_settled_against(&mut fx, &mut market, receipt, &deny_list);
    assert_eq!(payout, QUANTITY);
    kept.destroy_none();
    assert_eq!(helpers::market(&market).cash_balance(), cash_before - QUANTITY);
    assert_eq!(helpers::market(&market).payout_liability(), 0);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// A loser's zero payout sends nothing, so a denied loser's receipt is still
/// consumed.
#[test]
fun a_denied_losers_zero_payout_consumes_the_receipt() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let trader_address = receive_address(&mut account);
    let receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    settle(&mut fx, &mut market, LOSING_SETTLEMENT);
    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::deny(scenario, trader_address),
    );
    let cash_before = helpers::market(&market).cash_balance();
    let deny_list = usdc_deny_list::take(fx.scenario_mut());

    let (payout, kept) = pay_settled_against(&mut fx, &mut market, receipt, &deny_list);

    assert_eq!(payout, 0);
    kept.destroy_none();
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    return_shared(deny_list);
    finish(fx, market, account);
}

/// While USDC is globally paused every address counts as denied: a fill
/// refuses with reason 9 and hands back the whole escrow, and a winner's
/// payout is skipped.
#[test]
fun a_global_usdc_pause_refuses_fills_and_skips_payouts() {
    let (mut fx, expiry_id, trader) = live_setup(test_constants::short_expiry_ms());
    fx.scenario_mut().next_tx(trader.owner());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let held = mint_and_fill(&mut fx, &mut market, &mut account);
    fx.advance_live_oracle_bundle_to(&mut market, live_price(), TAU);
    let mut receipt = admit_with(
        &mut fx,
        &mut market,
        &mut account,
        QUANTITY,
        NO_PROBABILITY_CAP,
        CHANNEL_200MS,
        SELL_TAU,
    );
    let subsidy = commit_at(&mut fx, &mut market, &mut receipt, SELL_TAU, live_price());
    let (mut market, account) = between_txs!(
        &mut fx,
        market,
        account,
        expiry_id,
        &trader,
        |scenario| usdc_deny_list::set_global_pause(scenario, true),
    );
    let deny_list = usdc_deny_list::take(fx.scenario_mut());

    let (reason, kept, change, _, _, _, _, _, _, _) = fill_against(
        &mut fx,
        &mut market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
        &deny_list,
    );
    assert_eq!(reason, constants::fill_reason_recipient_denied!());
    assert_eq!(change.value(), BUDGET + ORDER_FEE);
    kept.destroy_none();
    destroy(change);

    settle(&mut fx, &mut market, WINNING_SETTLEMENT);
    let (payout, kept) = pay_settled_against(&mut fx, &mut market, held, &deny_list);
    assert_eq!(payout, QUANTITY);
    assert_eq!(helpers::market(&market).payout_liability(), QUANTITY);
    destroy(kept);
    return_shared(deny_list);
    finish(fx, market, account);
}

// === Retired instant trading ===

#[test, expected_failure(abort_code = expiry_market::EDelayedExecutionRequired)]
fun the_instant_mint_is_retired() {
    let (mut fx, mut market, mut account) = setup();
    let pricer = fx.load_pricer_bundle(&market);
    let (em, config, _, _, _) = market.market_parts_mut();
    let (wrapper, root) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let auth = account::generate_auth(ctx);
    em.mint_exact_quantity(
        wrapper,
        auth,
        config,
        &pricer,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        BUDGET,
        NO_PROBABILITY_CAP,
        root,
        clock,
        ctx,
    );
    abort 999
}

// === Helpers ===

fun live_price(): u64 { test_constants::default_live_price() }

/// The default live market across the cutover, with `TestFlow` allowlisted
/// and Sui's deny list shared over a regulated test USDC. Returns the fixture
/// in an admin transaction.
fun live_setup(expiry_ms: u64): (Fixture, ID, helpers::Trader) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(expiry_ms, live_price());
    fx.cutover();
    let mut market = fx.take_market_bundle(expiry_id);
    set_witness(&mut fx, &mut market, true);
    helpers::return_market_bundle(market);
    usdc_deny_list::setup(fx.scenario_mut());
    (fx, expiry_id, trader)
}

/// Return the held bundles, run `$edit` on the scenario (a deny-list change and
/// the epoch it takes effect in), and retake both in the trader's next
/// transaction.
macro fun between_txs(
    $fx: &mut Fixture,
    $market: MarketBundle,
    $account: AccountBundle,
    $expiry_id: ID,
    $trader: &helpers::Trader,
    $edit: |&mut Scenario|,
): (MarketBundle, AccountBundle) {
    let fx = $fx;
    let trader = $trader;
    helpers::return_account_bundle($account);
    helpers::return_market_bundle($market);
    $edit(fx.scenario_mut());
    fx.scenario_mut().next_tx(trader.owner());
    (fx.take_market_bundle($expiry_id), fx.take_account_bundle(trader))
}

fun receive_address(account: &mut AccountBundle): address {
    let (wrapper, _) = account.account_parts_mut();
    wrapper.load_account().receive_address()
}

/// `live_setup` with the trader referred by bob. Returns bob's handle.
fun referred_setup(): (Fixture, ID, helpers::Trader, helpers::Trader) {
    let (mut fx, expiry_id, trader, referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        live_price(),
    );
    fx.cutover();
    let mut market = fx.take_market_bundle(expiry_id);
    set_witness(&mut fx, &mut market, true);
    helpers::return_market_bundle(market);
    usdc_deny_list::setup(fx.scenario_mut());
    (fx, expiry_id, trader, referrer)
}

/// `live_setup` at the default expiry, in the trader's transaction.
fun setup(): (Fixture, MarketBundle, AccountBundle) {
    setup_at(test_constants::default_expiry_ms())
}

fun setup_at(expiry_ms: u64): (Fixture, MarketBundle, AccountBundle) {
    let (mut fx, expiry_id, trader) = live_setup(expiry_ms);
    fx.scenario_mut().next_tx(trader.owner());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);
    (fx, market, account)
}

/// Sponsor the pool and let a rebalance hand the market its fee incentives.
fun fund_incentives(fx: &mut Fixture, market: &mut MarketBundle) {
    fx.sponsor_fee_incentives_bundle(market, INCENTIVES);
    fx.rebalance_expiry_cash_bundle(market);
}

/// Take market cash down to `cash` with no liability change (a test-only
/// seam), returning what it took.
fun drain_cash_to(market: &mut MarketBundle, cash: u64): Balance<USDC> {
    let drain = helpers::market(market).cash_balance() - cash;
    helpers::market_mut(market).take_market_cash_for_testing(drain)
}

fun set_witness(fx: &mut Fixture, market: &mut MarketBundle, enabled: bool) {
    let (admin_cap, clock, _) = fx.admin_parts();
    helpers::config_mut(market).set_order_flow<TestFlow>(admin_cap, enabled, clock);
}

/// One 4m exact-quantity mint filled at τ, at the default expiry.
fun filled_mint(): (Fixture, MarketBundle, AccountBundle, OrderReceipt) {
    filled_mint_at(test_constants::default_expiry_ms())
}

fun filled_mint_at(expiry_ms: u64): (Fixture, MarketBundle, AccountBundle, OrderReceipt) {
    let (mut fx, mut market, mut account) = setup_at(expiry_ms);
    let receipt = mint_and_fill(&mut fx, &mut market, &mut account);
    (fx, market, account, receipt)
}

fun mint_and_fill(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
): OrderReceipt {
    let mut receipt = admit(fx, market, account, QUANTITY, NO_PROBABILITY_CAP);
    let subsidy = commit_at(fx, market, &mut receipt, TAU, live_price());
    let (reason, kept, change, _, _, _, _, _, _, _) = fill(
        fx,
        market,
        receipt,
        escrow(BUDGET + ORDER_FEE, subsidy),
    );
    assert_eq!(reason, 0);
    destroy(change);
    kept.destroy_some()
}

fun admit(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    quantity: u64,
    max_probability: u64,
): OrderReceipt {
    admit_with(fx, market, account, quantity, max_probability, CHANNEL_200MS, TAU)
}

fun admit_on(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    channel: u8,
    tau_ms: u64,
): OrderReceipt {
    admit_with(fx, market, account, QUANTITY, NO_PROBABILITY_CAP, channel, tau_ms)
}

fun admit_with(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    quantity: u64,
    max_probability: u64,
    channel: u8,
    tau_ms: u64,
): OrderReceipt {
    let (em, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, _) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let holder = wrapper.load_account_mut(account::generate_auth(ctx));
    expiry_market::admit_mint(
        TestFlow(),
        em,
        config,
        holder,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        constants::mint_kind_exact_quantity!(),
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        quantity,
        0,
        0,
        max_probability,
        BUDGET,
        ORDER_FEE,
        SVI_MAX_AGE_MS,
        channel,
        tau_ms,
        tau_ms + DEADLINE_AFTER_TAU_MS,
        clock,
        ctx,
    )
}

fun admit_sell(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    receipt: &mut OrderReceipt,
    close_quantity: u64,
    min_proceeds: u64,
    tau_ms: u64,
) {
    let (em, config, oracle_registry, pyth, bs) = market.market_parts_mut();
    let (wrapper, _) = account.account_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    let holder = wrapper.load_account_mut(account::generate_auth(ctx));
    expiry_market::admit_sell(
        TestFlow(),
        em,
        config,
        holder,
        receipt,
        oracle_registry,
        pyth,
        bs.values(),
        bs.svi(),
        close_quantity,
        0,
        min_proceeds,
        ORDER_FEE,
        SVI_MAX_AGE_MS,
        CHANNEL_200MS,
        tau_ms,
        tau_ms + DEADLINE_AFTER_TAU_MS,
        clock,
        ctx,
    );
}

/// Admit a sell from fresh feeds at `placed_at_ms`, commit it at `tau_ms` at
/// the live price, and fill it. Returns the proceeds, the trading fee, and the
/// receipt the fill kept.
fun sell(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    mut receipt: OrderReceipt,
    close_quantity: u64,
    placed_at_ms: u64,
    tau_ms: u64,
): (u64, u64, Option<OrderReceipt>) {
    fx.advance_live_oracle_bundle_to(market, live_price(), placed_at_ms);
    admit_sell(fx, market, account, &mut receipt, close_quantity, 0, tau_ms);
    let subsidy = commit_at(fx, market, &mut receipt, tau_ms, live_price());
    let (reason, kept, change, quantity, proceeds, fee, builder, referral, used, _) = fill(
        fx,
        market,
        receipt,
        escrow(ORDER_FEE, subsidy),
    );
    assert_eq!(reason, 0);
    assert_eq!(quantity, close_quantity);
    assert_eq!(builder, 0);
    assert_eq!(referral, 0);
    assert_eq!(used, 0);
    // The fill keeps the whole order fee.
    assert_eq!(change.value(), 0);
    destroy(change);
    (proceeds, fee, kept)
}

fun price(feed_id: u32, channel: u8, envelope_us: u64, generation_us: u64): LazerPrice {
    lazer_price::new_for_testing(feed_id, channel, envelope_us, generation_us, live_price())
}

/// Move the clock to `tick_ms` and commit the update stamped and generated
/// there at `spot`.
fun commit_at(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    receipt: &mut OrderReceipt,
    tick_ms: u64,
    spot: u64,
): Balance<USDC> {
    fx.set_clock_for_testing(tick_ms);
    let committed = lazer_price::new_for_testing(
        test_constants::pyth_feed_id(),
        CHANNEL_200MS,
        tick_ms * US_PER_MS,
        tick_ms * US_PER_MS,
        spot,
    );
    commit_price(fx, market, receipt, &committed)
}

fun commit_price(
    fx: &Fixture,
    market: &mut MarketBundle,
    receipt: &mut OrderReceipt,
    committed: &LazerPrice,
): Balance<USDC> {
    let (em, config, _, _, _) = market.market_parts_mut();
    expiry_market::commit(TestFlow(), em, config, receipt, committed, fx.clock())
}

/// Admit at τ and commit a price at clock `now_ms` that the provenance checks
/// refuse.
fun commit_bad_price(feed_id: u32, channel: u8, envelope_us: u64, generation_us: u64, now_ms: u64) {
    let (mut fx, mut market, mut account) = setup();
    let mut receipt = admit(&mut fx, &mut market, &mut account, QUANTITY, NO_PROBABILITY_CAP);
    fx.set_clock_for_testing(now_ms);
    let subsidy = commit_price(
        &fx,
        &mut market,
        &mut receipt,
        &price(feed_id, channel, envelope_us, generation_us),
    );
    destroy(subsidy);
    abort 999
}

/// `try_fill` with no address denied: an empty deny list stands in for Sui's.
fun fill(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    receipt: OrderReceipt,
    escrow: Balance<USDC>,
): (u8, Option<OrderReceipt>, Balance<USDC>, u64, u64, u64, u64, u64, u64, u64) {
    let none_denied = deny_list::new_for_testing(fx.scenario_mut().ctx());
    let (
        reason,
        kept,
        change,
        quantity,
        amount,
        fee,
        builder,
        referral,
        used,
        impact,
    ) = fill_against(
        fx,
        market,
        receipt,
        escrow,
        &none_denied,
    );
    destroy(none_denied);
    (reason, kept, change, quantity, amount, fee, builder, referral, used, impact)
}

/// `try_fill` against `deny_list`, Sui's shared one in the deny-list tests. A
/// transaction takes the shared list once, since `test_scenario` makes a
/// returned object available again only in the next transaction.
fun fill_against(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    receipt: OrderReceipt,
    escrow: Balance<USDC>,
    deny_list: &DenyList,
): (u8, Option<OrderReceipt>, Balance<USDC>, u64, u64, u64, u64, u64, u64, u64) {
    let (em, config, _, _, _) = market.market_parts_mut();
    let (clock, ctx) = fx.clock_and_ctx();
    expiry_market::try_fill(TestFlow(), em, config, receipt, escrow, deny_list, clock, ctx)
}

/// `try_pay_settled` with no address denied.
fun pay_settled(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    receipt: OrderReceipt,
): (u64, Option<OrderReceipt>) {
    let none_denied = deny_list::new_for_testing(fx.scenario_mut().ctx());
    let (payout, kept) = pay_settled_against(fx, market, receipt, &none_denied);
    destroy(none_denied);
    (payout, kept)
}

fun pay_settled_against(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    receipt: OrderReceipt,
    deny_list: &DenyList,
): (u64, Option<OrderReceipt>) {
    let (em, config, _, _, _) = market.market_parts_mut();
    let (_, ctx) = fx.clock_and_ctx();
    em.try_pay_settled(config, receipt, deny_list, ctx)
}

fun release(
    market: &mut MarketBundle,
    receipt: OrderReceipt,
    escrow: Balance<USDC>,
    reason: u8,
    prune: bool,
): (Option<OrderReceipt>, Balance<USDC>) {
    let (em, config, _, _, _) = market.market_parts_mut();
    em.release(config, receipt, escrow, reason, prune)
}

/// The order's escrow: `amount` of fresh USDC plus its reserved subsidy.
fun escrow(amount: u64, subsidy: Balance<USDC>): Balance<USDC> {
    let mut funds = balance::create_for_testing<USDC>(amount);
    funds.join(subsidy);
    funds
}

/// Settle the market at its expiry from an exact Pyth observation of `spot`.
fun settle(fx: &mut Fixture, market: &mut MarketBundle, spot: u64) {
    fx.set_clock_for_testing(helpers::market(market).expiry());
    fx.insert_exact_settlement_spot_bundle(market, spot);
    assert!(fx.try_settle_bundle(market));
}

/// The open stage keeps the position and zeroes everything else, and the held
/// quantity is the size the order ID names.
fun assert_canonical_open(receipt: &OrderReceipt, held: u64) {
    let (
        stage,
        kind,
        quantity,
        held_quantity,
        budget,
        order_fee,
        cash_need,
        subsidy_reserved,
        spot,
        tick,
        tau,
        deadline,
        channel,
    ) = receipt.receipt_state_for_testing();
    assert_eq!(stage, constants::receipt_stage_open!());
    assert_eq!(kind, 0);
    assert_eq!(quantity, 0);
    assert_eq!(held_quantity, held);
    assert_eq!(budget, 0);
    assert_eq!(order_fee, 0);
    assert_eq!(cash_need, 0);
    assert_eq!(subsidy_reserved, 0);
    assert_eq!(spot, 0);
    assert_eq!(tick, 0);
    assert_eq!(tau, 0);
    assert_eq!(deadline, 0);
    assert_eq!(channel, 0);
    let (_, _, _, order_id, _, _, _, _) = expiry_market::receipt_info(receipt);
    assert_eq!(order::from_id(order_id).quantity(), held);
}

/// The market's waiting cash need and payout-tree node count, with its 0.01
/// minimum entry probability.
fun assert_flow_state(market: &MarketBundle, waiting: u64, nodes: u64) {
    let (waiting_cash_need, node_count, min_probability) = helpers::market(
        market,
    ).order_flow_state();
    assert_eq!(waiting_cash_need, waiting);
    assert_eq!(node_count, nodes);
    assert_eq!(min_probability, 10_000_000);
}

fun assert_waiting(market: &MarketBundle, waiting: u64) {
    let (waiting_cash_need, _, _) = helpers::market(market).order_flow_state();
    assert_eq!(waiting_cash_need, waiting);
}

fun finish(fx: Fixture, market: MarketBundle, account: AccountBundle) {
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}
