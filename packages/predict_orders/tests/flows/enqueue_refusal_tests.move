// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Every queued-placement refusal, each at its boundary: the two stuck rules
/// (and `queue_stuck` agreeing with them), the mint capacity, the per-account
/// cap, the cutoff on the final τ, the mandatory cost cap, the order fee, the
/// minimum sell, and the Open-record source of `enqueue_redeem_open`, all the
/// queue's own; then the refusals Predict's admission makes for the queue: the
/// t₀ dry run and the spare-cash check.
///
/// Placements run under the fixture policy from `now_ms = 120_000` unless a
/// test says otherwise: delay 1_000, the 200 ms channel, stuck threshold 1_500,
/// stall timeout 5_000, mint capacity 100, five waiting orders per account, a
/// 0.02 USDC order fee, and a one-lot minimum sell.
#[test_only]
module deepbook_predict_orders::enqueue_refusal_tests;

use deepbook_predict::{expiry_market, flow_test_helpers as helpers, test_constants};
use deepbook_predict_orders::{queue, queue_fixture::{Self as fixture, QueueTest}};
use std::unit_test::assert_eq;

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
const FIRST_RECORD: u64 = 0;
const SECOND_RECORD: u64 = 1;
const FOURTH_RECORD: u64 = 3;
/// Cohorts A, B, and C.
const THREE_COHORTS: u64 = 3;

// Small orders: 10 contracts near 0.5 cost about 5.05 USDC all-in.
const SMALL_QUANTITY: u64 = 10_000_000;
const SMALL_MAX_COST: u64 = 10_000_000;
/// Funds five small orders with their fees: 5 * (10_000_000 + 20_000) < 60 USDC.
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
/// Twenty traders * five orders fill the mint capacity.
const FULL_QUEUE_TRADERS: u64 = 20;
/// Address seed for the capacity traders, clear of the named test addresses.
const FIRST_TRADER_SEED: u256 = 0x1000;

// Cutoff on a short-expiry market: expiry 240_000 - max(no-trade window 2_000,
// stall 5_000 + 5_000) = 230_000.
const SHORT_CUTOFF_MS: u64 = 230_000;
/// floor((229_000 + 1_000) / 200) * 200 = 230_000, exactly the cutoff.
const TAU_AT_CUTOFF_PLACED_MS: u64 = 229_000;
/// floor((228_999 + 1_000) / 200) * 200 = 229_800, one tick before the cutoff.
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
/// One unit below the 1 USDC minimum premium.
const BELOW_MIN_PREMIUM: u64 = 999_999;
/// Sell probability floor 0.6, above the ~0.5 at-the-money value.
const HIGH_MIN_PROBABILITY: u64 = 600_000_000;

// Spare cash.
/// ceil(1_000_000_000 * (1 - 0.01)) + 1 for an exact-quantity mint of
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
const ZERO_DELAY_MS: u64 = 0;

// Open records.
/// τ of the record the Open-record scenarios fill.
const FILL_TAU_MS: u64 = 121_000;
/// The fill clock for the Open-record scenarios: one tick after τ 121_000.
const FILL_AT_MS: u64 = 121_200;
/// A record ID no order has used.
const MISSING_RECORD: u64 = 7;

// === Stuck ===

/// Rule 1: the newest uncommitted cohort reaching τ + threshold, with nothing
/// later committed, refuses new orders, and `queue_stuck` says so first.
#[test, expected_failure(abort_code = queue::EQueueStuck)]
fun a_cohort_unpriced_past_the_stuck_threshold_refuses_orders() {
    let mut q = fixture::new();
    let first = enqueue_small(&mut q);
    assert_eq!(q.record(first).timing().tau_ms(), STUCK_TAU_MS);

    q.refresh_oracle_at(STUCK_AT_MS);
    assert!(q.is_stuck());
    enqueue_small(&mut q);
    abort 999
}

/// One millisecond earlier the same cohort is not stuck yet: the order goes in.
#[test]
fun an_order_one_ms_before_the_stuck_threshold_goes_in() {
    let mut q = fixture::new();
    enqueue_small(&mut q);

    q.refresh_oracle_at(JUST_BEFORE_STUCK_MS);
    assert!(!q.is_stuck());
    let second = enqueue_small(&mut q);
    assert_eq!(second, SECOND_RECORD);
    assert_pending_mints(&q, 2);

    q.assert_invariants();
    q.finish();
}

/// Rule 2: two uncommitted cohorts each past the threshold refuse orders even
/// though a later cohort was committed, which rule 1 alone would accept.
#[test, expected_failure(abort_code = queue::EQueueStuck)]
fun two_stale_cohorts_behind_a_committed_one_refuse_orders() {
    let mut q = fixture::new();
    place_three_cohorts_and_commit_the_last(&mut q);

    q.refresh_oracle_at(BOTH_STALE_AT_MS);
    assert!(q.is_stuck());
    enqueue_small(&mut q);
    abort 999
}

/// One missing tick behind a committed cohort never pauses the market.
#[test]
fun one_stale_cohort_behind_a_committed_one_does_not_refuse() {
    let mut q = fixture::new();
    place_three_cohorts_and_commit_the_last(&mut q);

    q.refresh_oracle_at(ONE_STALE_AT_MS);
    assert!(!q.is_stuck());
    let fourth = enqueue_small(&mut q);
    assert_eq!(fourth, FOURTH_RECORD);

    q.assert_invariants();
    q.finish();
}

// === Capacity and the per-account cap ===

/// The 100th waiting mint still fits the default capacity, and each account's
/// fifth order fits the per-account cap.
#[test]
fun the_hundredth_waiting_mint_fits() {
    let (q, account_ids) = fill_mint_capacity(fixture::new());

    assert_pending_mints(&q, MINT_CAPACITY);
    account_ids.do_ref!(|account_id| {
        assert_eq!(q.queue().waiting_orders(*account_id), PER_ACCOUNT_CAP);
    });
    q.assert_invariants();
    q.finish();
}

#[test, expected_failure(abort_code = queue::EQueueFull)]
fun the_hundred_and_first_waiting_mint_aborts() {
    let (q, _) = fill_mint_capacity(fixture::new());
    let (mut q, _) = q.new_trader(trader_address(FULL_QUEUE_TRADERS), SMALL_TRADER_DEPOSIT);
    enqueue_small(&mut q);
    abort 999
}

#[test, expected_failure(abort_code = queue::EAccountOrderCap)]
fun an_accounts_sixth_waiting_order_aborts() {
    let mut q = fixture::new();
    PER_ACCOUNT_CAP.do!(|_| { enqueue_small(&mut q); });
    enqueue_small(&mut q);
    abort 999
}

/// Finishing an order frees its account's slot.
#[test]
fun a_finished_order_frees_its_accounts_slot() {
    let mut q = fixture::new();
    PER_ACCOUNT_CAP.do!(|_| { enqueue_small(&mut q); });
    q.admin_refund(vector[FIRST_RECORD]);
    assert_eq!(q.queue().waiting_orders(q.account_id()), PER_ACCOUNT_CAP - 1);

    enqueue_small(&mut q);
    assert_eq!(q.queue().waiting_orders(q.account_id()), PER_ACCOUNT_CAP);
    q.finish();
}

// === Cutoff ===

#[test, expected_failure(abort_code = queue::EPastCutoff)]
fun an_order_whose_tau_lands_on_the_cutoff_aborts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.set_clock(TAU_AT_CUTOFF_PLACED_MS);
    enqueue_wide(&mut q);
    abort 999
}

#[test]
fun an_order_whose_tau_lands_one_tick_before_the_cutoff_goes_in() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.refresh_oracle_at(TAU_BEFORE_CUTOFF_PLACED_MS);
    let record_id = enqueue_wide(&mut q);

    let timing = q.record(record_id).timing();
    assert_eq!(timing.tau_ms(), TAU_BEFORE_CUTOFF_MS);
    assert_eq!(timing.deadline_ms(), TAU_BEFORE_CUTOFF_DEADLINE_MS);
    assert_eq!(timing.cutoff_ms(), SHORT_CUTOFF_MS);

    q.assert_invariants();
    q.finish();
}

/// The cutoff binds the final τ: a raw τ below the cutoff that the committed
/// cohort pushes onto it is refused.
#[test, expected_failure(abort_code = queue::EPastCutoff)]
fun the_committed_cohort_push_onto_the_cutoff_aborts() {
    let mut q = fixture::new_at(test_constants::short_expiry_ms());
    q.set_timing(
        ZERO_DELAY_MS,
        DEFAULT_STALL_TIMEOUT_MS,
        DEFAULT_STUCK_THRESHOLD_MS,
        DEFAULT_GAP_WAIT_MS,
        NO_PRICE_BUFFER_MS,
        CHANNEL_200MS,
    );
    q.refresh_oracle_at(ZERO_DELAY_PLACED_MS);
    let first = enqueue_wide(&mut q);
    assert_eq!(q.record(first).timing().tau_ms(), ZERO_DELAY_PLACED_MS);
    q.commit(vector[fixture::price_update(ZERO_DELAY_PLACED_MS, fixture::live_price())]);
    let (_, _, _, last_committed_tau_ms) = q.queue().queue_heads();
    assert_eq!(last_committed_tau_ms, ZERO_DELAY_PLACED_MS);
    enqueue_wide(&mut q);
    abort 999
}

// === The mandatory cost cap ===

#[test, expected_failure(abort_code = queue::EMintCostCapRequired)]
fun a_mint_with_a_zero_cost_cap_aborts() {
    let mut q = fixture::new();
    q.enqueue_atm(SMALL_QUANTITY, ZERO_COST_CAP);
    abort 999
}

/// The unlimited value is refused even where the cap is the sizing budget.
#[test, expected_failure(abort_code = queue::EMintCostCapRequired)]
fun a_mint_with_an_unlimited_cost_cap_aborts() {
    let mut q = fixture::new();
    q.enqueue_cost(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        std::u64::max_value!(),
        NO_MIN_QUANTITY,
    );
    abort 999
}

// === The order fee ===

/// A mint needs a balance strictly above the order fee.
#[test, expected_failure(abort_code = queue::EFeeNotCovered)]
fun a_mint_with_a_balance_equal_to_the_fee_aborts() {
    let (mut q, _) = fixture::new().new_trader(test_constants::bob(), ORDER_FEE);
    enqueue_small(&mut q);
    abort 999
}

/// One unit above the fee passes the queue's fee check; the 1-unit budget then
/// fails the minimum premium in Predict's admission dry run.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_mint_one_unit_above_the_fee_reaches_the_dry_run() {
    let (mut q, _) = fixture::new().new_trader(test_constants::bob(), ORDER_FEE + 1);
    enqueue_small(&mut q);
    abort 999
}

/// A sell escrows only the fee, so a balance equal to it is enough.
#[test]
fun a_sell_with_a_balance_equal_to_the_fee_goes_in() {
    let mut q = open_record_market();
    q.withdraw_down_to(ORDER_FEE);

    let record_id = sell(&mut q, FIRST_RECORD, test_constants::mint_quantity());
    assert_eq!(q.balance(), 0);
    assert_eq!(q.record(record_id).funds(), ORDER_FEE);

    q.assert_invariants();
    q.finish();
}

#[test, expected_failure(abort_code = queue::EFeeNotCovered)]
fun a_sell_with_a_balance_below_the_fee_aborts() {
    let mut q = open_record_market();
    q.withdraw_down_to(ORDER_FEE - 1);
    sell(&mut q, FIRST_RECORD, test_constants::mint_quantity());
    abort 999
}

// === Predict's admission dry run ===

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_mint_above_its_probability_cap_at_t0_aborts() {
    let mut q = fixture::new();
    q.enqueue_quantity(
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
    let mut q = fixture::new();
    q.enqueue_atm(test_constants::mint_quantity(), LOW_MAX_COST);
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_budget_below_the_minimum_premium_aborts() {
    let mut q = fixture::new();
    q.enqueue_cost(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        BELOW_MIN_PREMIUM,
        NO_MIN_QUANTITY,
    );
    abort 999
}

#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_sell_below_its_probability_floor_at_t0_aborts() {
    let mut q = open_record_market();
    q.enqueue_sell(FIRST_RECORD, test_constants::mint_quantity(), HIGH_MIN_PROBABILITY, UNUSED);
    abort 999
}

// === Predict's spare-cash check ===

/// A mint whose own cash need equals the market's spare cash goes in, moving no
/// market cash.
#[test]
fun a_mint_needing_exactly_the_spare_cash_goes_in() {
    let mut q = fixture::new_with_cash(QUANTITY_CASH_NEED);
    q.enqueue_atm(test_constants::mint_quantity(), QUANTITY_MAX_COST);

    let (waiting_cash_need, _) = q.ledger();
    assert_eq!(waiting_cash_need, QUANTITY_CASH_NEED);
    assert_eq!(q.market().cash_balance(), QUANTITY_CASH_NEED);
    assert_eq!(q.market().required_cash(), 0);

    q.assert_invariants();
    q.finish();
}

#[test, expected_failure(abort_code = expiry_market::EInsufficientMarketCash)]
fun a_mint_needing_one_unit_more_than_the_spare_cash_aborts() {
    let mut q = fixture::new_with_cash(QUANTITY_CASH_NEED - 1);
    q.enqueue_atm(test_constants::mint_quantity(), QUANTITY_MAX_COST);
    abort 999
}

// === Minimum sell ===

#[test, expected_failure(abort_code = queue::EBelowMinSell)]
fun a_sell_of_nothing_aborts() {
    let mut q = open_record_market();
    sell(&mut q, FIRST_RECORD, NOTHING);
    abort 999
}

#[test, expected_failure(abort_code = queue::EBelowMinSell)]
fun a_sell_below_the_minimum_aborts() {
    let mut q = open_record_market();
    raise_min_sell(&mut q);
    sell(&mut q, FIRST_RECORD, BELOW_RAISED_MIN_SELL);
    abort 999
}

#[test, expected_failure(abort_code = queue::EBelowMinSell)]
fun a_partial_sell_leaving_less_than_the_minimum_aborts() {
    let mut q = open_record_market();
    raise_min_sell(&mut q);
    sell(&mut q, FIRST_RECORD, LEAVES_BELOW_MIN_SELL);
    abort 999
}

#[test]
fun a_partial_sell_leaving_exactly_the_minimum_goes_in() {
    let mut q = open_record_market();
    raise_min_sell(&mut q);
    let record_id = sell(&mut q, FIRST_RECORD, LEAVES_MIN_SELL);
    assert_eq!(q.record(record_id).request().quantity(), LEAVES_MIN_SELL);

    q.assert_invariants();
    q.finish();
}

// === Open-record source ===

/// A missing ID is not an Open record, even in a queue whose first order this
/// would be.
#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun selling_a_missing_record_aborts() {
    let mut q = fixture::new();
    sell(&mut q, MISSING_RECORD, test_constants::mint_quantity());
    abort 999
}

/// A record still waiting for its price holds no position yet.
#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun selling_a_pending_record_aborts() {
    let mut q = fixture::new();
    let pending = enqueue_small(&mut q);
    sell(&mut q, pending, test_constants::mint_quantity());
    abort 999
}

/// A record already sold is Closed and holds no receipt.
#[test, expected_failure(abort_code = queue::ERecordNotOpen)]
fun selling_a_closed_record_aborts() {
    let mut q = open_record_market();
    sell(&mut q, FIRST_RECORD, test_constants::mint_quantity());
    sell(&mut q, FIRST_RECORD, test_constants::mint_quantity());
    abort 999
}

#[test, expected_failure(abort_code = queue::ENotRecordOwner)]
fun selling_another_accounts_open_record_aborts() {
    let q = open_record_market();
    let (mut q, _) = q.new_trader(test_constants::bob(), test_constants::mint_deposit());
    q.refresh_oracle_at(FILL_AT_MS);
    sell(&mut q, FIRST_RECORD, test_constants::mint_quantity());
    abort 999
}

// === Helpers ===

/// Exact-quantity mint of 10 contracts over `(strike_tick, +inf]`.
fun enqueue_small(q: &mut QueueTest): u64 {
    q.enqueue_atm(SMALL_QUANTITY, SMALL_MAX_COST)
}

/// Exact-quantity mint of `mint_quantity` capped at 700 USDC.
fun enqueue_wide(q: &mut QueueTest): u64 {
    q.enqueue_atm(test_constants::mint_quantity(), WIDE_MAX_COST)
}

/// The default market where alice holds Open record 0 of `mint_quantity` over
/// `(strike_tick, +inf]`, filled at FILL_AT_MS, in a fresh transaction with the
/// feeds reseeded there so a sell's dry run can price.
fun open_record_market(): QueueTest {
    let mut q = fixture::new();
    q.enqueue_atm(test_constants::mint_quantity(), QUANTITY_MAX_COST);
    q.commit_at(FILL_TAU_MS, fixture::live_price());
    q.set_clock(FILL_AT_MS);
    assert_eq!(q.resolve(1), 1);
    let mut q = q.next_tx(test_constants::alice());
    q.refresh_oracle_at(FILL_AT_MS);
    q
}

/// Queued sell of `close_quantity` from Open record `record_id`, with no floors.
fun sell(q: &mut QueueTest, record_id: u64, close_quantity: u64): u64 {
    q.enqueue_sell(record_id, close_quantity, UNUSED, UNUSED)
}

/// Raise the minimum sell to one contract, keeping every other limit at its
/// default.
fun raise_min_sell(q: &mut QueueTest) {
    q.set_limits(
        MINT_CAPACITY,
        DEFAULT_SELL_CAPACITY,
        PER_ACCOUNT_CAP,
        RAISED_MIN_SELL,
        DEFAULT_SETTLE_REFUND_BATCH,
        DEFAULT_SETTLE_PAYOUT_BATCH,
    );
}

/// Alice's small mints at 120_000, 120_200, and 120_400 open cohorts at τ
/// 121_000, 121_200, and 121_400; then only the last is committed, at 121_500.
fun place_three_cohorts_and_commit_the_last(q: &mut QueueTest) {
    enqueue_small(q);
    q.set_clock(COHORT_B_PLACED_AT_MS);
    enqueue_small(q);
    q.set_clock(COHORT_C_PLACED_AT_MS);
    enqueue_small(q);
    let (cohorts, _, _) = q.queue().waiting_cohorts();
    assert_eq!(cohorts, THREE_COHORTS);
    q.set_clock(COMMIT_C_AT_MS);
    q.commit(vector[fixture::price_update(COHORT_C_TAU_MS, fixture::live_price())]);
    let (_, _, _, last_committed_tau_ms) = q.queue().queue_heads();
    assert_eq!(last_committed_tau_ms, COHORT_C_TAU_MS);
}

/// Twenty fresh traders each place five small mints at 120_000, filling the
/// default mint capacity. Returns their account IDs.
fun fill_mint_capacity(q: QueueTest): (QueueTest, vector<ID>) {
    let mut q = q;
    let mut account_ids = vector[];
    let mut index = 0;
    while (index < FULL_QUEUE_TRADERS) {
        let (next, _) = q.new_trader(trader_address(index), SMALL_TRADER_DEPOSIT);
        q = next;
        PER_ACCOUNT_CAP.do!(|_| { enqueue_small(&mut q); });
        account_ids.push_back(q.account_id());
        index = index + 1;
    };
    (q, account_ids)
}

fun trader_address(index: u64): address {
    sui::address::from_u256(FIRST_TRADER_SEED + (index as u256))
}

fun assert_pending_mints(q: &QueueTest, expected: u64) {
    let (pending_mints, _) = q.queue().pending_counts();
    assert_eq!(pending_mints, expected);
}
