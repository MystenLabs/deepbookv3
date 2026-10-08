// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Every queued-placement refusal after the market's book exists, each at its
/// boundary: the two stuck rules (and `queue_stuck` agreeing with them), the mint
/// capacity, the per-account cap, the cutoff on the final τ, the mandatory cost
/// cap, the order fee, the t₀ dry run, the spare-cash check, the minimum sell,
/// and the Open-record source of `enqueue_redeem_open`.
///
/// Placements run under the default policy from `now_ms = 120_000` unless a test
/// says otherwise: delay 1_000, the 200 ms channel, stuck threshold 1_500, stall
/// timeout 5_000, mint capacity 100, five waiting orders per account, a 0.02 USDC
/// order fee, and a one-lot minimum sell.
#[test_only]
module deepbook_predict::enqueue_refusal_tests;

use deepbook_predict::{
    enqueue_test_helpers as enqueue,
    expiry_market,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle, Trader},
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;
use usdc::usdc::USDC;

/// The policy's default flat order fee: 0.02 USDC.
const ORDER_FEE: u64 = 20_000;
/// A disabled request field (an unused limit, or a close-side floor of zero).
const UNUSED: u64 = 0;
/// Slippage floor that accepts any fill.
const NO_MIN_QUANTITY: u64 = 0;
/// A zero all-in cap, which a mint must not pass.
const ZERO_COST_CAP: u64 = 0;
/// A sell of nothing.
const NOTHING: u64 = 0;
/// Record IDs in placement order.
const SECOND_RECORD: u64 = 1;
const FOURTH_RECORD: u64 = 3;
/// Cohorts A, B, and C.
const THREE_COHORTS: u64 = 3;

// Small orders: 10 contracts near 0.5 cost about 5.05 USDC all-in.
const SMALL_QUANTITY: u64 = 10_000_000;
const SMALL_MAX_COST: u64 = 10_000_000;
/// Funds five small orders with their fees: 5 × (10_000_000 + 20_000) < 60 USDC.
const SMALL_TRADER_DEPOSIT: u64 = 60_000_000;

// Stuck rule 1: one order at 120_000 waits for τ 121_000.
const STUCK_TAU_MS: u64 = 121_000;
/// τ + stuck threshold 1_500: the first instant the cohort counts as stuck.
const STUCK_AT_MS: u64 = 122_500;
const JUST_BEFORE_STUCK_MS: u64 = 122_499;

// Stuck rule 2: cohorts A (τ 121_000), B (τ 121_200), and C (τ 121_400) placed
// at 120_000, 120_200, and 120_400; only C is committed, at 121_500.
const COHORT_B_PLACED_AT_MS: u64 = 120_200;
const COHORT_C_PLACED_AT_MS: u64 = 120_400;
const COHORT_C_TAU_MS: u64 = 121_400;
const COMMIT_C_AT_MS: u64 = 121_500;
/// B's τ 121_200 + 1_500: A and B are both stale from here.
const BOTH_STALE_AT_MS: u64 = 122_700;
/// Only A (stale since 122_500) is stale here: one missing tick, not stuck.
const ONE_STALE_AT_MS: u64 = 122_699;

// Capacity.
/// The default mint capacity.
const MINT_CAPACITY: u64 = 100;
/// The default per-account cap.
const PER_ACCOUNT_CAP: u64 = 5;
/// Twenty traders × five orders fill the mint capacity.
const FULL_QUEUE_TRADERS: u64 = 20;
/// Address seed for the capacity traders, clear of the named test addresses.
const FIRST_TRADER_SEED: u256 = 0x1000;

// Cutoff on a short-expiry market: expiry 240_000 − max(no-trade window 2_000,
// stall 5_000 + 5_000) = 230_000.
const SHORT_CUTOFF_MS: u64 = 230_000;
/// ⌊(229_000 + 1_000) / 200⌋ × 200 = 230_000, exactly the cutoff.
const TAU_AT_CUTOFF_PLACED_MS: u64 = 229_000;
/// ⌊(228_999 + 1_000) / 200⌋ × 200 = 229_800, one tick before the cutoff.
const TAU_BEFORE_CUTOFF_PLACED_MS: u64 = 228_999;
const TAU_BEFORE_CUTOFF_MS: u64 = 229_800;
/// 229_800 + stall 5_000, below the 240_000 expiry.
const TAU_BEFORE_CUTOFF_DEADLINE_MS: u64 = 234_800;
/// With delay 0 an order placed at 229_800 gets τ = 229_800; once that cohort is
/// committed, the next order is pushed to 230_000, the cutoff.
const ZERO_DELAY_PLACED_MS: u64 = 229_800;
/// All-in cap for `mint_quantity` near 0.5: 700 USDC.
const WIDE_MAX_COST: u64 = 700_000_000;

// The t₀ dry run, for `mint_quantity` = 1_000 contracts near 0.5.
/// Probability cap 0.4, below the ~0.5 at-the-money entry.
const LOW_MAX_PROBABILITY: u64 = 400_000_000;
/// All-in cap 400 USDC, below the ~505 USDC the fill costs.
const LOW_MAX_COST: u64 = 400_000_000;
/// One unit below `constants::min_premium` (1 USDC).
const BELOW_MIN_PREMIUM: u64 = 999_999;
/// Sell probability floor 0.6, above the ~0.5 at-the-money value.
const HIGH_MIN_PROBABILITY: u64 = 600_000_000;

// Spare cash.
/// ⌈1_000_000_000 × (1 - 0.01)⌉ + 1 for an exact-quantity mint of
/// `mint_quantity` at minimum entry probability 0.01.
const QUANTITY_CASH_NEED: u64 = 990_000_001;
/// All-in cap for `mint_quantity` near 0.5: 600 USDC.
const QUANTITY_MAX_COST: u64 = 600_000_000;

// Minimum sell.
/// A raised minimum sell: 1 contract.
const RAISED_MIN_SELL: u64 = 1_000_000;
/// One lot below the raised minimum.
const BELOW_RAISED_MIN_SELL: u64 = 990_000;
/// Leaves 990_000 of the 1_000_000_000 position, one lot below the minimum.
const LEAVES_BELOW_MIN_SELL: u64 = 999_010_000;
/// Leaves exactly the 1_000_000 minimum.
const LEAVES_MIN_SELL: u64 = 999_000_000;
/// The other default limits, restated so only the minimum sell moves.
const DEFAULT_SELL_CAPACITY: u64 = 100;
const DEFAULT_SETTLE_REFUND_BATCH: u64 = 450;
const DEFAULT_SETTLE_PAYOUT_BATCH: u64 = 900;

// Timing, for the committed-push scenario.
const DEFAULT_STALL_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_STUCK_THRESHOLD_MS: u64 = 1_500;
const DEFAULT_GAP_WAIT_MS: u64 = 2_000;
const NO_PRICE_BUFFER_MS: u64 = 0;
const CHANNEL_200MS: u8 = 3;
const DEFAULT_SVI_MAX_AGE_MS: u64 = 60_000;
const ZERO_DELAY_MS: u64 = 0;

// Open records.
/// The fill clock for the Open-record scenarios: one tick after τ 121_000.
const FILL_AT_MS: u64 = 121_200;
/// A record ID no order has used.
const MISSING_RECORD: u64 = 7;

// === Stuck ===

/// Rule 1: the newest uncommitted cohort reaching τ + threshold, with nothing
/// later committed, refuses new orders, and `queue_stuck` says so first.
#[test, expected_failure(abort_code = expiry_market::EQueueStuck)]
fun a_cohort_unpriced_past_the_stuck_threshold_refuses_orders() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let first = enqueue_small(&mut fx, &mut market, &mut account);
    assert_eq!(market.market().queued_order(first).destroy_some().timing().tau_ms(), STUCK_TAU_MS);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        STUCK_AT_MS,
    );
    assert!(market.market().queue_stuck(market.config(), fx.clock()));
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

/// One millisecond earlier the same cohort is not stuck yet: the order goes in.
#[test]
fun an_order_one_ms_before_the_stuck_threshold_goes_in() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    enqueue_small(&mut fx, &mut market, &mut account);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        JUST_BEFORE_STUCK_MS,
    );
    assert!(!market.market().queue_stuck(market.config(), fx.clock()));
    let second = enqueue_small(&mut fx, &mut market, &mut account);
    assert_eq!(second, SECOND_RECORD);
    assert_pending_mints(&market, 2);

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Rule 2: two uncommitted cohorts each past the threshold refuse orders even
/// though a later cohort was committed, which rule 1 alone would accept.
#[test, expected_failure(abort_code = expiry_market::EQueueStuck)]
fun two_stale_cohorts_behind_a_committed_one_refuse_orders() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    place_three_cohorts_and_commit_the_last(&mut fx, &mut market, &mut account);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        BOTH_STALE_AT_MS,
    );
    assert!(market.market().queue_stuck(market.config(), fx.clock()));
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

/// One missing tick behind a committed cohort never pauses the market.
#[test]
fun one_stale_cohort_behind_a_committed_one_does_not_refuse() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    place_three_cohorts_and_commit_the_last(&mut fx, &mut market, &mut account);

    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        ONE_STALE_AT_MS,
    );
    assert!(!market.market().queue_stuck(market.config(), fx.clock()));
    let fourth = enqueue_small(&mut fx, &mut market, &mut account);
    assert_eq!(fourth, FOURTH_RECORD);

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Capacity and the per-account cap ===

/// The 100th waiting mint still fits the default capacity, and each account's
/// fifth order fits the per-account cap.
#[test]
fun the_hundredth_waiting_mint_fits() {
    let (mut fx, expiry_id, _) = setup_default();
    let account_ids = fill_mint_capacity(&mut fx, expiry_id);

    fx.scenario_mut().next_tx(test_constants::admin());
    let market = fx.take_market_bundle(expiry_id);
    assert_pending_mints(&market, MINT_CAPACITY);
    account_ids.do_ref!(|account_id| {
        assert_eq!(market.market().waiting_orders(*account_id), PER_ACCOUNT_CAP);
    });
    queue::assert_queue_invariants(market.market());
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EQueueFull)]
fun the_hundred_and_first_waiting_mint_aborts() {
    let (mut fx, expiry_id, _) = setup_default();
    fill_mint_capacity(&mut fx, expiry_id);
    let late = fx.create_funded_manager_as(
        trader_address(FULL_QUEUE_TRADERS),
        SMALL_TRADER_DEPOSIT,
    );
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&late);
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EAccountOrderCap)]
fun an_accounts_sixth_waiting_order_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    PER_ACCOUNT_CAP.do!(|_| { enqueue_small(&mut fx, &mut market, &mut account); });
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

// === Cutoff ===

#[test, expected_failure(abort_code = expiry_market::EPastCutoff)]
fun an_order_whose_tau_lands_on_the_cutoff_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.set_clock_for_testing(TAU_AT_CUTOFF_PLACED_MS);
    enqueue_wide(&mut fx, &mut market, &mut account);
    abort 999
}

#[test]
fun an_order_whose_tau_lands_one_tick_before_the_cutoff_goes_in() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        TAU_BEFORE_CUTOFF_PLACED_MS,
    );
    let record_id = enqueue_wide(&mut fx, &mut market, &mut account);

    let timing = market.market().queued_order(record_id).destroy_some().timing();
    assert_eq!(timing.tau_ms(), TAU_BEFORE_CUTOFF_MS);
    assert_eq!(timing.deadline_ms(), TAU_BEFORE_CUTOFF_DEADLINE_MS);
    assert_eq!(timing.cutoff_ms(), SHORT_CUTOFF_MS);

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// The cutoff binds the final τ: a raw τ below the cutoff that the committed
/// cohort pushes onto it is refused.
#[test, expected_failure(abort_code = expiry_market::EPastCutoff)]
fun the_committed_cohort_push_onto_the_cutoff_aborts() {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    {
        let (admin_cap, clock, _) = fx.admin_parts();
        market
            .config_mut()
            .set_delayed_execution_timing(
                admin_cap,
                ZERO_DELAY_MS,
                DEFAULT_STALL_TIMEOUT_MS,
                DEFAULT_STUCK_THRESHOLD_MS,
                DEFAULT_GAP_WAIT_MS,
                NO_PRICE_BUFFER_MS,
                CHANNEL_200MS,
                DEFAULT_SVI_MAX_AGE_MS,
                clock,
            );
    };
    fx.advance_live_oracle_bundle_to(
        &mut market,
        test_constants::default_live_price(),
        ZERO_DELAY_PLACED_MS,
    );
    let first = enqueue_wide(&mut fx, &mut market, &mut account);
    assert_eq!(
        market.market().queued_order(first).destroy_some().timing().tau_ms(),
        ZERO_DELAY_PLACED_MS,
    );
    enqueue::commit_cohort(&mut fx, &mut market, ZERO_DELAY_PLACED_MS);
    enqueue_wide(&mut fx, &mut market, &mut account);
    abort 999
}

// === The mandatory cost cap ===

#[test, expected_failure(abort_code = expiry_market::EMintCostCapRequired)]
fun a_mint_with_a_zero_cost_cap_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        SMALL_QUANTITY,
        ZERO_COST_CAP,
        std::u64::max_value!(),
    );
    abort 999
}

/// The unlimited value is refused even where the cap is the sizing budget.
#[test, expected_failure(abort_code = expiry_market::EMintCostCapRequired)]
fun a_mint_with_an_unlimited_cost_cap_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_cost(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        std::u64::max_value!(),
        NO_MIN_QUANTITY,
    );
    abort 999
}

// === The order fee ===

/// A mint needs a balance strictly above the order fee.
#[test, expected_failure(abort_code = expiry_market::EFeeNotCovered)]
fun a_mint_with_a_balance_equal_to_the_fee_aborts() {
    let (mut fx, expiry_id, _) = setup_default();
    let bob = fx.create_funded_manager_as(test_constants::bob(), ORDER_FEE);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&bob);
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

/// One unit above the fee passes the fee check; the 1-unit budget then fails the
/// minimum premium in the dry run.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_mint_one_unit_above_the_fee_reaches_the_dry_run() {
    let (mut fx, expiry_id, _) = setup_default();
    let bob = fx.create_funded_manager_as(test_constants::bob(), ORDER_FEE + 1);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&bob);
    enqueue_small(&mut fx, &mut market, &mut account);
    abort 999
}

/// A sell escrows only the fee, so a balance equal to it is enough.
#[test]
fun a_sell_with_a_balance_equal_to_the_fee_goes_in() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    enqueue::withdraw_down_to(&mut fx, &mut account, ORDER_FEE);

    sell(&mut fx, &mut market, &mut account, source_id, test_constants::mint_quantity());
    assert_eq!(fx.account_balance_bundle<USDC>(&account), 0);
    assert_eq!(expiry_market::queue_escrow_for_testing(market.market()), ORDER_FEE);

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EFeeNotCovered)]
fun a_sell_with_a_balance_below_the_fee_aborts() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    enqueue::withdraw_down_to(&mut fx, &mut account, ORDER_FEE - 1);
    sell(&mut fx, &mut market, &mut account, source_id, test_constants::mint_quantity());
    abort 999
}

// === The t₀ dry run ===

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_mint_above_its_probability_cap_at_t0_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        WIDE_MAX_COST,
        LOW_MAX_PROBABILITY,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_mint_costing_more_than_its_cap_at_t0_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_quantity(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        LOW_MAX_COST,
        std::u64::max_value!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_budget_below_the_minimum_premium_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    queue::enqueue_exact_cost(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BELOW_MIN_PREMIUM,
        NO_MIN_QUANTITY,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_sell_below_its_probability_floor_at_t0_aborts() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        source_id,
        test_constants::mint_quantity(),
        HIGH_MIN_PROBABILITY,
        UNUSED,
    );
    abort 999
}

// === Spare cash ===

/// A mint whose own cash need equals the market's spare cash goes in, moving no
/// market cash.
#[test]
fun a_mint_needing_exactly_the_spare_cash_goes_in() {
    let (mut fx, expiry_id, trader) = enqueue::setup_queue_market_with_cash(
        test_constants::default_expiry_ms(),
        QUANTITY_CASH_NEED,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    enqueue_quantity(&mut fx, &mut market, &mut account);

    assert_eq!(market.market().waiting_cash_need(), QUANTITY_CASH_NEED);
    assert_eq!(market.market().spare_cash(), QUANTITY_CASH_NEED);

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EInsufficientMarketCash)]
fun a_mint_needing_one_unit_more_than_the_spare_cash_aborts() {
    let (mut fx, expiry_id, trader) = enqueue::setup_queue_market_with_cash(
        test_constants::default_expiry_ms(),
        QUANTITY_CASH_NEED - 1,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    enqueue_quantity(&mut fx, &mut market, &mut account);
    abort 999
}

// === Minimum sell ===

#[test, expected_failure(abort_code = expiry_market::EBelowMinSell)]
fun a_sell_of_nothing_aborts() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    sell(&mut fx, &mut market, &mut account, source_id, NOTHING);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EBelowMinSell)]
fun a_sell_below_the_minimum_aborts() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    raise_min_sell(&mut fx, &mut market);
    sell(&mut fx, &mut market, &mut account, source_id, BELOW_RAISED_MIN_SELL);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EBelowMinSell)]
fun a_partial_sell_leaving_less_than_the_minimum_aborts() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    raise_min_sell(&mut fx, &mut market);
    sell(&mut fx, &mut market, &mut account, source_id, LEAVES_BELOW_MIN_SELL);
    abort 999
}

#[test]
fun a_partial_sell_leaving_exactly_the_minimum_goes_in() {
    let (mut fx, mut market, mut account, source_id) = enter_with_open_record();
    raise_min_sell(&mut fx, &mut market);
    let record_id = sell(&mut fx, &mut market, &mut account, source_id, LEAVES_MIN_SELL);
    assert_eq!(
        market.market().queued_order(record_id).destroy_some().request().quantity(),
        LEAVES_MIN_SELL,
    );

    queue::assert_queue_invariants(market.market());
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Open-record source ===

/// A missing ID is not an Open record, even in a market whose first order this
/// would be.
#[test, expected_failure(abort_code = expiry_market::ERecordNotOpen)]
fun selling_a_missing_record_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    sell(&mut fx, &mut market, &mut account, MISSING_RECORD, test_constants::mint_quantity());
    abort 999
}

/// A record still waiting for its price holds no position yet.
#[test, expected_failure(abort_code = expiry_market::ERecordNotOpen)]
fun selling_a_pending_record_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let pending = enqueue_small(&mut fx, &mut market, &mut account);
    sell(&mut fx, &mut market, &mut account, pending, test_constants::mint_quantity());
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::ENotRecordOwner)]
fun selling_another_accounts_open_record_aborts() {
    let (mut fx, expiry_id, trader) = setup_default();
    let open_record = enqueue::fill_exact_quantity(
        &mut fx,
        expiry_id,
        &trader,
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        FILL_AT_MS,
    );
    let bob = fx.create_funded_manager_as(test_constants::bob(), test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&bob);
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), FILL_AT_MS);
    sell(&mut fx, &mut market, &mut account, open_record, test_constants::mint_quantity());
    abort 999
}

// === Helpers ===

fun setup_default(): (Fixture, ID, Trader) {
    queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    )
}

/// Exact-quantity mint of 10 contracts over `(strike_tick, +inf]`.
fun enqueue_small(fx: &mut Fixture, market: &mut MarketBundle, account: &mut AccountBundle): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        SMALL_QUANTITY,
        SMALL_MAX_COST,
        std::u64::max_value!(),
    )
}

/// Exact-quantity mint of `mint_quantity` capped at 600 USDC.
fun enqueue_quantity(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        std::u64::max_value!(),
    )
}

/// Exact-quantity mint of `mint_quantity` capped at 700 USDC.
fun enqueue_wide(fx: &mut Fixture, market: &mut MarketBundle, account: &mut AccountBundle): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        WIDE_MAX_COST,
        std::u64::max_value!(),
    )
}

/// A default queue market where alice holds an Open record of `mint_quantity`
/// over `(strike_tick, +inf]`, filled at `FILL_AT_MS`, with the feeds reseeded
/// there so a sell's dry run can price. Returns the record ID with the bundles.
fun enter_with_open_record(): (Fixture, MarketBundle, AccountBundle, u64) {
    let (mut fx, expiry_id, trader) = setup_default();
    let source_id = enqueue::fill_exact_quantity(
        &mut fx,
        expiry_id,
        &trader,
        test_constants::mint_quantity(),
        QUANTITY_MAX_COST,
        FILL_AT_MS,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), FILL_AT_MS);
    (fx, market, account, source_id)
}

/// Queued sell of `close_quantity` from Open record `record_id`, with no floors.
fun sell(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    record_id: u64,
    close_quantity: u64,
): u64 {
    queue::enqueue_redeem_open(fx, market, account, record_id, close_quantity, UNUSED, UNUSED)
}

/// Raise the minimum sell to one contract, keeping every other limit at its
/// default.
fun raise_min_sell(fx: &mut Fixture, market: &mut MarketBundle) {
    let (admin_cap, clock, _) = fx.admin_parts();
    market
        .config_mut()
        .set_delayed_execution_limits(
            admin_cap,
            MINT_CAPACITY,
            DEFAULT_SELL_CAPACITY,
            PER_ACCOUNT_CAP,
            RAISED_MIN_SELL,
            DEFAULT_SETTLE_REFUND_BATCH,
            DEFAULT_SETTLE_PAYOUT_BATCH,
            clock,
        );
}

/// Alice's small mints at 120_000, 120_200, and 120_400 open cohorts at τ
/// 121_000, 121_200, and 121_400; then only the last is committed, at 121_500.
fun place_three_cohorts_and_commit_the_last(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
) {
    enqueue_small(fx, market, account);
    fx.set_clock_for_testing(COHORT_B_PLACED_AT_MS);
    enqueue_small(fx, market, account);
    fx.set_clock_for_testing(COHORT_C_PLACED_AT_MS);
    enqueue_small(fx, market, account);
    let (cohorts, _, _) = market.market().waiting_cohorts();
    assert_eq!(cohorts, THREE_COHORTS);
    fx.set_clock_for_testing(COMMIT_C_AT_MS);
    enqueue::commit_cohort(fx, market, COHORT_C_TAU_MS);
    let (_, _, _, last_committed_tau_ms) = market.market().queue_heads();
    assert_eq!(last_committed_tau_ms, COHORT_C_TAU_MS);
}

/// Twenty fresh traders each place five small mints at 120_000, filling the
/// default mint capacity. Returns their account IDs, read while each trader's
/// bundle is taken: a returned shared object is not takable again until the
/// next transaction.
fun fill_mint_capacity(fx: &mut Fixture, expiry_id: ID): vector<ID> {
    let mut account_ids = vector[];
    FULL_QUEUE_TRADERS.do!(|index| {
        let trader = fx.create_funded_manager_as(trader_address(index), SMALL_TRADER_DEPOSIT);
        let mut market = fx.take_market_bundle(expiry_id);
        let mut account = fx.take_account_bundle(&trader);
        PER_ACCOUNT_CAP.do!(|_| { enqueue_small(fx, &mut market, &mut account); });
        account_ids.push_back(helpers::account_id_bundle(&account));
        helpers::return_account_bundle(account);
        helpers::return_market_bundle(market);
    });
    account_ids
}

fun trader_address(index: u64): address {
    sui::address::from_u256(FIRST_TRADER_SEED + (index as u256))
}

fun assert_pending_mints(market: &MarketBundle, expected: u64) {
    let (pending_mints, _) = market.market().pending_counts();
    assert_eq!(pending_mints, expected);
}
