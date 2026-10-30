// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The per-trade builder fee through the queue: an order that names a builder
/// code and fee per contract has the fee capped at placement and recorded in
/// its receipt, the fill charges exactly that fee to the code, and nothing of it
/// is left once the order fills or is refunded by the deadline, the admin, or
/// the settlement drain. A sell names its own builder, recorded in the sell's
/// receipt.
///
/// The edges: a zero fee or a zero cap charges nothing, a fee of u64::MAX pays
/// the cap, and a cap change after placement leaves a waiting order's fee alone.
/// A mint's fee counts toward its `max_cost` and toward the $1-per-contract
/// payout bound, both checked at placement. A sell's fee is clamped at the
/// redeem value left after the trading fee, and its `min_proceeds` is checked net
/// of the fee. A plain sell of a builder mint, or of a builder sell's remainder,
/// pays no builder fee and inherits no floor.
///
/// Arithmetic, independent of the contract (the fixture the v4 queue suites
/// use): a 4m at-the-money mint over `(100, +inf]` at the 100e9 live price
/// floors its premium to 1_999_974 across the reference digital's band and pays
/// the 0.005 minimum trading fee, 20_000. A fee of 0.0005 per $1 contract is
/// 4m * 0.0005 = 2_000 on it. A builder fee is floor(quantity * fee / 1e9), with
/// the fee in FLOAT_SCALING of the $1 payout. A close of the position redeems
/// floor(p * quantity), the same 1_999_974 for 4m, less the same minimum trading
/// fee. Settlement scenarios use 100m mints with a 90 USDC budget on the
/// short-expiry market (expiry 240_000).
#[test_only]
module deepbook_predict_orders::builder_fee_flow_tests;

use deepbook_predict::{expiry_market, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue,
    queue_event_views as events,
    queue_fixture as fixture
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
/// The premium floor(p * 4m) = 1_999_974 plus the 0.005 * 4m trading fee.
const ALL_IN_COST: u64 = 2_019_974;
const PREMIUM: u64 = 1_999_974;
const TRADING_FEE: u64 = 20_000;
/// A builder fee of 0.0005 per $1 contract, in FLOAT_SCALING, and that fee on
/// 4m: 4m * 0.0005.
const BUILDER_FEE_PER_CONTRACT: u64 = 500_000;
const BUILDER_FEE: u64 = 2_000;
/// A builder fee cap of 0.0003 per contract, and the capped fee on 4m:
/// 4m * 0.0003.
const LOW_CAP: u64 = 300_000;
const CAPPED_BUILDER_FEE: u64 = 1_200;
const BUILDER_CODE_INDEX: u64 = 0;
const TAU: u64 = 121_000;
const SELL_TAU: u64 = 122_000;
const DEADLINE: u64 = 126_000;
const RESOLVE_ALL: u64 = 10;
/// The settlement scenarios' 100m order with a 90 USDC budget, and the market's
/// expiry.
const BIG_QUANTITY: u64 = 100_000_000;
const BIG_MAX_COST: u64 = 90_000_000;
const EXPIRY: u64 = 240_000;
/// An all-in budget of exactly the 4m fill with its builder fee,
/// ALL_IN_COST + BUILDER_FEE.
const ALL_IN_COST_WITH_FEE: u64 = 2_021_974;
/// An all-in budget exactly one unit short of the 4m fill with its builder fee,
/// ALL_IN_COST + BUILDER_FEE - 1. Without the fee 4m fits; with it, a 4m mint is
/// refused, and an all-in-cost fill steps down one 10_000 lot to 3.99m.
const ONE_SHORT_OF_4M_WITH_FEE: u64 = 2_021_973;
const STEPPED_DOWN_QUANTITY: u64 = 3_990_000;
/// The 3.99m fill: premium floor(p * 3.99m) = 1_994_974 across the band, the
/// 0.005 * 3.99m trading fee, and the fee 3.99m * 0.0005.
const STEPPED_DOWN_PREMIUM: u64 = 1_994_974;
const STEPPED_DOWN_TRADING_FEE: u64 = 19_950;
const STEPPED_DOWN_BUILDER_FEE: u64 = 1_995;
const NO_FLOOR: u64 = 0;
/// A zero fee per contract, and a zero cap, which stops builder fees.
const ZERO_FEE: u64 = 0;
/// Predict's default builder fee cap, 5c per $1 contract (the package-only
/// `config_constants::default_builder_fee_cap`), and that fee on 4m: 4m * 0.05.
const DEFAULT_CAP: u64 = 50_000_000;
const DEFAULT_CAP_BUILDER_FEE: u64 = 200_000;
/// The highest cap, a contract's whole $1 payout in FLOAT_SCALING.
const MAX_CAP: u64 = 1_000_000_000;
/// The largest fee per contract an order can name, u64::MAX.
const MAX_FEE: u64 = 18_446_744_073_709_551_615;
/// The fee per contract that brings the 4m fill to exactly its 4_000_000 payout:
/// floor(4m * 495_006_500 / 1e9) = 1_980_026, and 2_019_974 + 1_980_026 =
/// 4_000_000.
const PAYOUT_FEE: u64 = 495_006_500;
const PAYOUT_BUILDER_FEE: u64 = 1_980_026;
/// The smallest fee per contract that takes the 4m fill one unit past its
/// payout: floor(4m * 495_006_750 / 1e9) = 1_980_027, an all-in cost of
/// 4_000_001. 495_006_749 still floors to 1_980_026.
const PAST_PAYOUT_FEE: u64 = 495_006_750;
/// The premium cap that sizes a premium-budget mint to 4m: 4m costs
/// PREMIUM <= 2m, while 4.01m costs floor(p * 4.01m) = 2_004_974 > 2m.
const MAX_PREMIUM: u64 = 2_000_000;
/// A 5 USDC all-in cap for a premium-budget mint, whose budget is not capped at
/// its quantity: it covers the 4_000_001 one unit past the 4m fill's payout, so
/// only the payout bound can refuse that fill.
const ABOVE_PAYOUT_MAX_COST: u64 = 5_000_000;
/// A 4m sell's proceeds net of the 2_000 builder fee: the redeem value
/// 1_999_974 less the 20_000 trading fee and the builder fee.
const BUILDER_SELL_PROCEEDS: u64 = 1_977_974;
const ONE_ABOVE_BUILDER_SELL_PROCEEDS: u64 = 1_977_975;
/// A sell that pays out nothing: the builder fee took the whole redeem value
/// left after the trading fee.
const NO_PROCEEDS: u64 = 0;
/// Half the 4m position: it redeems floor(p * 2m) = 999_987 across the band,
/// with the trading fee 0.005 * 2m = 10_000 and the builder fee
/// 2m * 0.0005 = 1_000. Proceeds are 999_987 - 10_000 = 989_987 without a
/// builder and 989_987 - 1_000 = 988_987 with one.
const HALF: u64 = 2_000_000;
const HALF_TRADING_FEE: u64 = 10_000;
const HALF_BUILDER_FEE: u64 = 1_000;
const HALF_PROCEEDS: u64 = 989_987;
const HALF_BUILDER_PROCEEDS: u64 = 988_987;
/// A sell placed at 122_000 lands on floor(123_000 / 200) * 200.
const LAST_SELL_TAU: u64 = 123_000;
/// The first record a queue hands out, and the next one, which no order holds
/// after one placement.
const FIRST_RECORD: u64 = 0;
const NEXT_RECORD: u64 = 1;

#[test]
fun a_builder_mint_records_its_capped_fee_and_the_fill_charges_it() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(LOW_CAP);

    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    // Placement records the fee capped at the cap, not the fee the order named.
    assert_eq!(q.builder_fee_of(record_id), LOW_CAP);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), CAPPED_BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + CAPPED_BUILDER_FEE);
    assert_eq!(q.builder_fee_of(record_id), 0);
    assert_eq!(q.record(record_id).status(), order_queue::status_open());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

#[test]
fun a_queued_order_keeps_its_fee_when_the_cap_drops() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.builder_fee_of(record_id), BUILDER_FEE_PER_CONTRACT);

    // A lower cap applies to the next order only.
    q.set_builder_fee_cap(0);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + BUILDER_FEE);
    assert_eq!(q.builder_fee_of(record_id), 0);
    q.assert_invariants();
    q.finish();
}

#[test]
fun the_deadline_and_admin_refunds_leave_no_builder_fee() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let by_deadline = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    // A shared code returned in one transaction is taken again in the next.
    let trader = q.trader();
    let mut q = q.as_trader(trader);
    let by_admin = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );

    q.admin_refund(vector[by_admin]);
    assert_eq!(q.builder_fee_of(by_admin), 0);
    assert_eq!(q.builder_fee_of(by_deadline), BUILDER_FEE_PER_CONTRACT);
    q.set_clock(DEADLINE);
    assert_eq!(q.refund(RESOLVE_ALL), 1);

    assert_eq!(q.builder_fee_of(by_deadline), 0);
    assert_eq!(q.record(by_admin).status(), order_queue::status_refunded());
    assert_eq!(q.record(by_deadline).status(), order_queue::status_refunded());
    assert!(events::fills().is_empty());
    q.assert_invariants();
    q.finish();
}

#[test]
fun the_settlement_drain_leaves_no_builder_fee() {
    let q = fixture::new_at(test_constants::short_expiry_ms());
    let (mut q, code_id) = q.new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(
        BIG_QUANTITY,
        BIG_MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.builder_fee_of(record_id), BUILDER_FEE_PER_CONTRACT);
    q.set_clock(EXPIRY);

    assert_eq!(q.settle_step(), queue::phase_pay());

    assert_eq!(q.builder_fee_of(record_id), 0);
    assert_eq!(q.record(record_id).status(), order_queue::status_refunded());
    q.assert_invariants();
    q.finish();
}

#[test]
fun a_builder_sell_records_its_own_fee_and_pays_it_at_the_fill() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    // A plain mint, then a sell of it that names the builder.
    let open_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell_with_builder(
        open_id,
        QUANTITY,
        NO_FLOOR,
        NO_FLOOR,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.builder_fee_of(open_id), 0);
    assert_eq!(q.builder_fee_of(sell_id), BUILDER_FEE_PER_CONTRACT);

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), PREMIUM - TRADING_FEE - BUILDER_FEE);
    assert_eq!(q.builder_fee_of(sell_id), 0);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

#[test]
fun an_exact_cost_fill_sizes_its_builder_fee_inside_the_budget() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_cost_with_builder(
        ONE_SHORT_OF_4M_WITH_FEE,
        0,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.quantity(), STEPPED_DOWN_QUANTITY);
    assert_eq!(fill.builder_fee(), STEPPED_DOWN_BUILDER_FEE);
    assert_eq!(
        fill.amount(),
        STEPPED_DOWN_PREMIUM + STEPPED_DOWN_TRADING_FEE + STEPPED_DOWN_BUILDER_FEE,
    );
    q.assert_invariants();
    q.finish();
}

/// A builder named at a zero fee records zero, and the trader pays exactly the
/// plain all-in cost.
#[test]
fun a_zero_builder_fee_charges_nothing_at_the_fill() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(QUANTITY, MAX_COST, code_id, ZERO_FEE);
    assert_eq!(q.builder_fee_of(record_id), 0);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), ALL_IN_COST);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A zero cap stops builder fees: an order that names a nonzero fee records zero
/// and pays none.
#[test]
fun a_zero_cap_records_and_charges_no_builder_fee() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(ZERO_FEE);
    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.builder_fee_of(record_id), 0);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), ALL_IN_COST);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// The largest fee an order can name is charged at the default cap, neither
/// refused nor overflowed.
#[test]
fun a_u64_max_fee_is_recorded_and_charged_at_the_default_cap() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(QUANTITY, MAX_COST, code_id, MAX_FEE);
    assert_eq!(q.builder_fee_of(record_id), DEFAULT_CAP);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), DEFAULT_CAP_BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + DEFAULT_CAP_BUILDER_FEE);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

#[test]
fun a_queued_order_keeps_its_fee_when_the_cap_rises() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(LOW_CAP);
    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.builder_fee_of(record_id), LOW_CAP);

    // A higher cap applies to the next order only, not the fee already capped.
    q.set_builder_fee_cap(DEFAULT_CAP);
    assert_eq!(q.builder_fee_of(record_id), LOW_CAP);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.builder_fee(), CAPPED_BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + CAPPED_BUILDER_FEE);
    q.assert_invariants();
    q.finish();
}

/// The builder fee counts toward `max_cost`: a cap of exactly the all-in cost
/// with the fee fills and spends all of it.
#[test]
fun a_builder_mint_capped_at_exactly_its_cost_with_the_fee_fills() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        ALL_IN_COST_WITH_FEE,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST_WITH_FEE);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// One unit less and placement refuses the order: its t₀ dry run costs
/// ALL_IN_COST_WITH_FEE against a budget of min(max_cost, quantity) one short.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_builder_mint_capped_one_unit_short_of_its_cost_with_the_fee_is_refused() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.enqueue_atm_with_builder(
        QUANTITY,
        ONE_SHORT_OF_4M_WITH_FEE,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    abort 999
}

/// The same `max_cost` admits and fills the same mint without a builder, so
/// the fee is what that cap refused.
#[test]
fun the_cap_a_builder_mint_misses_admits_it_without_the_builder() {
    let mut q = fixture::new();
    let record_id = q.enqueue_atm(QUANTITY, ONE_SHORT_OF_4M_WITH_FEE);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), ALL_IN_COST);
    q.assert_invariants();
    q.finish();
}

/// The builder fee counts toward the $1-per-contract payout bound: at the
/// highest cap, a fee that brings the 4m fill to exactly its 4_000_000 payout
/// fills.
#[test]
fun a_builder_mint_costing_exactly_its_payout_fills() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(MAX_CAP);
    let record_id = q.enqueue_atm_with_builder(QUANTITY, QUANTITY, code_id, PAYOUT_FEE);
    assert_eq!(q.builder_fee_of(record_id), PAYOUT_FEE);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), PAYOUT_BUILDER_FEE);
    assert_eq!(fill.amount(), QUANTITY);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// One unit past the payout is refused at placement. An exact-quantity budget is
/// min(max_cost, quantity), here the payout itself, so the cost cap refuses the
/// same order; the premium-budget pair below separates the two bounds.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_builder_mint_costing_one_unit_above_its_payout_is_refused() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(MAX_CAP);
    q.enqueue_atm_with_builder(QUANTITY, QUANTITY, code_id, PAST_PAYOUT_FEE);
    abort 999
}

/// A premium-budget mint's budget is not capped at its quantity: with a 5 USDC
/// budget, the 4m fill at exactly its payout fills and returns the rest.
#[test]
fun a_premium_budget_builder_mint_costing_exactly_its_payout_fills_inside_a_larger_budget() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(MAX_CAP);
    let record_id = q.enqueue_amount_with_builder(
        MAX_PREMIUM,
        QUANTITY,
        ABOVE_PAYOUT_MAX_COST,
        code_id,
        PAYOUT_FEE,
    );
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.kind(), order_queue::kind_exact_amount());
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.builder_fee(), PAYOUT_BUILDER_FEE);
    assert_eq!(fill.amount(), QUANTITY);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// One unit past the payout is refused by the payout bound alone: the
/// 4_000_001 all-in cost is inside the 5 USDC budget.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_premium_budget_builder_mint_one_unit_above_its_payout_is_refused_inside_its_budget() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(MAX_CAP);
    q.enqueue_amount_with_builder(
        MAX_PREMIUM,
        QUANTITY,
        ABOVE_PAYOUT_MAX_COST,
        code_id,
        PAST_PAYOUT_FEE,
    );
    abort 999
}

/// A premium-budget builder mint sizes to 4m from its premium cap alone and
/// charges the fee on that quantity, inside `max_cost`: a cap of exactly the
/// all-in cost with the fee fills.
#[test]
fun a_premium_budget_builder_mint_charges_its_fee_on_the_filled_quantity_within_max_cost() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_amount_with_builder(
        MAX_PREMIUM,
        QUANTITY,
        ALL_IN_COST_WITH_FEE,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.kind(), order_queue::kind_exact_amount());
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST_WITH_FEE);
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A premium-budget mint is sized by its premium, not its budget, so a cap one
/// unit short of the cost with the fee refuses it instead of shrinking it.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_premium_budget_builder_mint_capped_one_unit_short_of_its_cost_with_the_fee_is_refused() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.enqueue_amount_with_builder(
        MAX_PREMIUM,
        QUANTITY,
        ONE_SHORT_OF_4M_WITH_FEE,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    abort 999
}

/// A plain sell of a builder mint pays no builder fee and keeps its full
/// proceeds. The mint's receipt kept its 5c fee in the field a sell reads its
/// floor from, and 50_000_000 is far above the 1_979_974 proceeds, so the sell
/// filling with no floor also shows that fee never became the sell's floor.
#[test]
fun a_plain_sell_of_a_builder_mint_pays_no_builder_fee_and_inherits_no_floor() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let open_id = q.enqueue_atm_with_builder(QUANTITY, MAX_COST, code_id, DEFAULT_CAP);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    let mint = events::fills()[0];
    assert_eq!(mint.builder_fee(), DEFAULT_CAP_BUILDER_FEE);
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell(open_id, QUANTITY, NO_FLOOR, NO_FLOOR);
    assert_eq!(q.builder_fee_of(sell_id), 0);

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), PREMIUM - TRADING_FEE);
    assert_eq!(q.record(sell_id).status(), order_queue::status_closed());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A builder sell's `min_proceeds` is checked net of its builder fee: a floor
/// of exactly the net proceeds fills at it.
#[test]
fun a_builder_sell_with_its_floor_at_its_net_proceeds_fills() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let open_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell_with_builder(
        open_id,
        QUANTITY,
        NO_FLOOR,
        BUILDER_SELL_PROCEEDS,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), BUILDER_SELL_PROCEEDS);
    assert_eq!(q.record(sell_id).status(), order_queue::status_closed());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// One unit above the net proceeds is refused at placement: the t₀ dry run
/// prices the close at the clock to the same proceeds the fill would pay at τ,
/// while a refund at the fill would need the price to move between the two.
#[test, expected_failure(abort_code = expiry_market::EOrderFailsLimits)]
fun a_builder_sell_with_its_floor_one_unit_above_its_net_proceeds_is_refused() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let open_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    q.enqueue_sell_with_builder(
        open_id,
        QUANTITY,
        NO_FLOOR,
        ONE_ABOVE_BUILDER_SELL_PROCEEDS,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    abort 999
}

/// A sell's builder fee is clamped at the redeem value left after the trading
/// fee: at the highest cap a fee of the whole $1 payout would be 4m on a 4m
/// close, so it takes the 1_979_974 left and the sell fills with no proceeds.
#[test]
fun a_builder_sell_fee_is_clamped_at_the_redeem_value_after_the_trading_fee() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(MAX_CAP);
    let open_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let sell_id = q.enqueue_sell_with_builder(
        open_id,
        QUANTITY,
        NO_FLOOR,
        NO_FLOOR,
        code_id,
        MAX_CAP,
    );
    assert_eq!(q.builder_fee_of(sell_id), MAX_CAP);

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), PREMIUM - TRADING_FEE);
    assert_eq!(fill.amount(), NO_PROCEEDS);
    assert_eq!(q.record(sell_id).status(), order_queue::status_closed());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A builder sell of half the position leaves an Open remainder, and a later
/// plain sell of that remainder pays no builder fee.
#[test]
fun a_plain_sell_of_a_builder_sells_remainder_pays_no_builder_fee() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    let open_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);
    q.refresh_oracle_at(TAU);
    let partial_id = q.enqueue_sell_with_builder(
        open_id,
        HALF,
        NO_FLOOR,
        NO_FLOOR,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let partial = fills[fills.length() - 1];
    assert_eq!(partial.record_id(), partial_id);
    assert_eq!(partial.trading_fee(), HALF_TRADING_FEE);
    assert_eq!(partial.builder_fee(), HALF_BUILDER_FEE);
    assert_eq!(partial.amount(), HALF_BUILDER_PROCEEDS);
    assert_eq!(q.record(partial_id).status(), order_queue::status_open());
    assert_eq!(q.builder_fee_of(partial_id), 0);

    q.refresh_oracle_at(SELL_TAU);
    let rest_id = q.enqueue_sell(partial_id, HALF, NO_FLOOR, NO_FLOOR);
    assert_eq!(q.builder_fee_of(rest_id), 0);
    q.commit_at(LAST_SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let rest = fills[fills.length() - 1];
    assert_eq!(rest.record_id(), rest_id);
    assert_eq!(rest.trading_fee(), HALF_TRADING_FEE);
    assert_eq!(rest.builder_fee(), 0);
    assert_eq!(rest.amount(), HALF_PROCEEDS);
    assert_eq!(q.record(rest_id).status(), order_queue::status_closed());
    q.assert_invariants();
    q.assert_backed();
    q.finish();
}

/// A code linked to the account is not a trade's builder: a plain mint from
/// that account pays no builder fee.
#[test]
fun a_code_linked_to_the_account_charges_nothing_on_a_plain_mint() {
    let (mut q, _) = fixture::new().link_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    assert_eq!(q.builder_fee_of(record_id), 0);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.amount(), ALL_IN_COST);
    q.assert_invariants();
    q.finish();
}

/// `builder_fee_of` reads zero, without aborting, for a record ID no order
/// holds and for a waiting order that names no builder.
#[test]
fun builder_fee_of_is_zero_for_a_missing_record_and_a_plain_order() {
    let mut q = fixture::new();
    assert_eq!(q.builder_fee_of(FIRST_RECORD), 0);

    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    assert_eq!(record_id, FIRST_RECORD);
    assert_eq!(q.record(record_id).status(), order_queue::status_pending());
    assert_eq!(q.builder_fee_of(record_id), 0);
    assert_eq!(q.builder_fee_of(NEXT_RECORD), 0);
    q.finish();
}
