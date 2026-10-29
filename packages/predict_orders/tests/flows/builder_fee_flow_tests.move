// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The per-trade builder fee through the queue: an order that names a builder
/// code and fee per contract has the fee capped at placement and saved in the
/// queue, the fill charges exactly the saved fee to the code, and every exit
/// removes it: a fill, the deadline and admin refunds, and the settlement
/// drain. A sell names its own builder, saved on the sell's record.
///
/// Arithmetic, independent of the contract (the fixture the v4 queue suites
/// use): a 4m at-the-money mint over `(100, +inf]` at the 100e9 live price
/// floors its premium to 1_999_974 across the reference digital's band and pays
/// the 0.005 minimum trading fee, 20_000. A fee of 0.0005 per $1 contract is
/// 4m * 0.0005 = 2_000 on it. Settlement scenarios use 100m mints with a 90 USDC
/// budget on the short-expiry market (expiry 240_000).
#[test_only]
module deepbook_predict_orders::builder_fee_flow_tests;

use deepbook_predict::test_constants;
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
/// An all-in budget exactly one unit short of the 4m fill with its builder fee,
/// ALL_IN_COST + BUILDER_FEE - 1. Without the fee 4m fits; with it, the fill
/// steps down one 10_000 lot to 3.99m.
const ONE_SHORT_OF_4M_WITH_FEE: u64 = 2_021_973;
const STEPPED_DOWN_QUANTITY: u64 = 3_990_000;
/// The 3.99m fill: premium floor(p * 3.99m) = 1_994_974 across the band, the
/// 0.005 * 3.99m trading fee, and the fee 3.99m * 0.0005.
const STEPPED_DOWN_PREMIUM: u64 = 1_994_974;
const STEPPED_DOWN_TRADING_FEE: u64 = 19_950;
const STEPPED_DOWN_BUILDER_FEE: u64 = 1_995;
const NO_FLOOR: u64 = 0;

#[test]
fun a_builder_mint_saves_its_capped_fee_and_the_fill_charges_and_removes_it() {
    let (mut q, code_id) = fixture::new().new_builder_code(BUILDER_CODE_INDEX);
    q.set_builder_fee_cap(LOW_CAP);

    let record_id = q.enqueue_atm_with_builder(
        QUANTITY,
        MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    // Placement saves the fee capped at the cap, not the fee the order named.
    assert_eq!(q.saved_builder_fee(record_id), LOW_CAP);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.builder_fee(), CAPPED_BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + CAPPED_BUILDER_FEE);
    assert_eq!(q.saved_builder_fee(record_id), 0);
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
    assert_eq!(q.saved_builder_fee(record_id), BUILDER_FEE_PER_CONTRACT);

    // A lower cap applies to the next order only.
    q.set_builder_fee_cap(0);
    q.commit_at(TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + BUILDER_FEE);
    assert_eq!(q.saved_builder_fee(record_id), 0);
    q.assert_invariants();
    q.finish();
}

#[test]
fun the_deadline_and_admin_refunds_remove_the_saved_fee() {
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
    assert_eq!(q.saved_builder_fee(by_admin), 0);
    assert_eq!(q.saved_builder_fee(by_deadline), BUILDER_FEE_PER_CONTRACT);
    q.set_clock(DEADLINE);
    assert_eq!(q.refund(RESOLVE_ALL), 1);

    assert_eq!(q.saved_builder_fee(by_deadline), 0);
    assert_eq!(q.record(by_admin).status(), order_queue::status_refunded());
    assert_eq!(q.record(by_deadline).status(), order_queue::status_refunded());
    assert!(events::fills().is_empty());
    q.assert_invariants();
    q.finish();
}

#[test]
fun the_settlement_drain_removes_the_saved_fee() {
    let q = fixture::new_at(test_constants::short_expiry_ms());
    let (mut q, code_id) = q.new_builder_code(BUILDER_CODE_INDEX);
    let record_id = q.enqueue_atm_with_builder(
        BIG_QUANTITY,
        BIG_MAX_COST,
        code_id,
        BUILDER_FEE_PER_CONTRACT,
    );
    assert_eq!(q.saved_builder_fee(record_id), BUILDER_FEE_PER_CONTRACT);
    q.set_clock(EXPIRY);

    assert_eq!(q.settle_step(), queue::phase_pay());

    assert_eq!(q.saved_builder_fee(record_id), 0);
    assert_eq!(q.record(record_id).status(), order_queue::status_refunded());
    q.assert_invariants();
    q.finish();
}

#[test]
fun a_builder_sell_saves_its_own_fee_and_pays_it_at_the_fill() {
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
    assert_eq!(q.saved_builder_fee(open_id), 0);
    assert_eq!(q.saved_builder_fee(sell_id), BUILDER_FEE_PER_CONTRACT);

    q.commit_at(SELL_TAU, fixture::live_price());
    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fills = events::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.record_id(), sell_id);
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), PREMIUM - TRADING_FEE - BUILDER_FEE);
    assert_eq!(q.saved_builder_fee(sell_id), 0);
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
