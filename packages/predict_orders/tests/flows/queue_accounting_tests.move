// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Accounting of queued orders on Predict's real primitives: where every unit
/// of a record's escrow goes on a fill or a refund. The fee subsidy is reserved
/// at commit into the record and either used, returned at the fill, or returned
/// with a refund, so the incentives are conserved; builder and referral fees
/// leave the market; the inventory-impact charge lands in its reserve; a fill
/// releases the order's cash need and keeps its pinned node, a refund releases
/// both; and the market stays cash-backed throughout.
///
/// Recipient payouts (unused budget, builder and referral fees) go to address
/// balances, which a Move unit test cannot read, so each test pins them through
/// the identity `escrow in = market cash gained + incentives returned + sent
/// out`, with the sent-out amounts from the fill event checked against
/// hand-derived values.
///
/// Arithmetic, independent of the contract (the fixture the v4 queue suites
/// used): a 4m at-the-money mint over `(100, +inf]` at the 100e9 live price
/// floors its premium to 1_999_974 across the reference digital's band; the
/// minimum fee is 0.005 per unit, so the trading fee is 20_000; the default
/// subsidy rate is 20% and the default referral rate 10%.
#[test_only]
module deepbook_predict_orders::queue_accounting_tests;

use deepbook_predict::{flow_test_helpers as helpers, test_constants};
use deepbook_predict_orders::{
    order_queue,
    queue_event_views as events,
    queue_fixture::{Self as fixture, QueueTest}
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
const ORDER_FEE: u64 = 20_000;
/// 0.005 * 4m.
const TRADING_FEE: u64 = 20_000;
/// The premium floor(p * 4m) = 1_999_974 + TRADING_FEE.
const ALL_IN_COST: u64 = 2_019_974;
/// Market cash one unsubsidized, unreferred 4m fill adds: the premium 1_999_974
/// + TRADING_FEE + ORDER_FEE.
const MINT_CASH: u64 = 2_039_974;
/// 20% of the 20_000 subsidy bound.
const RESERVED_SUBSIDY: u64 = 4_000;
/// ALL_IN_COST - RESERVED_SUBSIDY: the trader pays the fee less the subsidy.
const SUBSIDIZED_COST: u64 = 2_015_974;
/// min(0.1 * 20_000, 0.005 * 4m).
const BUILDER_FEE: u64 = 2_000;
/// 10% of the trader-paid 20_000 fee.
const REFERRAL_FEE: u64 = 2_000;
/// 10% of the trader-paid 20_000 - 4_000 = 16_000 once the subsidy covers 4_000.
const SUBSIDIZED_REFERRAL_FEE: u64 = 1_600;
const BUILDER_CODE_INDEX: u64 = 0;
/// 10 USDC of incentives.
const INCENTIVES: u64 = 10_000_000;
const TAU: u64 = 121_000;
const RESOLVE_ALL: u64 = 10;
/// A 0.6 cap the at-the-money t₀ quote passes.
const MAX_PROBABILITY: u64 = 600_000_000;
/// A committed spot that moves the digital to about 0.736 (see
/// `resolve_flow_tests`): above the 0.6 cap, and a premium-budget mint buys
/// fewer contracts there than at t₀.
const LIMIT_SPOT: u64 = 100_002_000_000;
/// The premium-budget mint's 2 USDC premium cap: 4m at t₀.
const MAX_PREMIUM: u64 = 2_000_000;
// Inventory impact, the Predict impact suite's terms.
const IMPACT_MAX_RATE: u64 = 200_000_000;
const IMPACT_SCALE: u64 = 10_000_000_000;
const IMPACT_QUANTITY: u64 = 1_000_000_000;
const IMPACT_MAX_COST: u64 = 700_000_000;

// === The fee subsidy ===

/// The whole reservation is used: the trader pays the fee less the subsidy, the
/// market gains the whole fee, and the incentives fall by exactly the
/// reservation, once.
#[test]
fun a_subsidized_fill_uses_its_reservation_once() {
    let mut q = fixture::new();
    q.fund_incentives(INCENTIVES);
    let incentives_before = q.market().fee_incentive_balance();
    let record_id = q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    // Commit moved the reservation from the incentives into the record.
    assert_eq!(q.market().fee_incentive_balance(), incentives_before - RESERVED_SUBSIDY);
    assert_eq!(q.record(record_id).funds(), MAX_COST + ORDER_FEE + RESERVED_SUBSIDY);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.subsidy_used(), RESERVED_SUBSIDY);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.amount(), SUBSIDIZED_COST);
    // The market gains the whole fee: the trader's part and the subsidy.
    assert_eq!(q.market().cash_balance(), cash_before + MINT_CASH);
    assert_eq!(q.market().fee_incentive_balance(), incentives_before - RESERVED_SUBSIDY);
    // Escrow in = 3_000_000 + 20_000 + 4_000 = 3_024_000 = MINT_CASH 2_039_974
    // + the unused budget 3_000_000 - 2_015_974 = 984_026 sent to the trader.
    assert_eq!(q.record(record_id).funds(), 0);
    assert_fill_ledger(&q);
    q.assert_backed();
    q.finish();
}

/// A premium-budget mint sized at t₀ to 4m reserves 20% of that fee, then buys
/// fewer contracts at a higher price and pays a smaller fee. The unused part of
/// the reservation goes back to the incentives at the fill.
#[test]
fun a_partly_used_reservation_returns_the_rest_at_the_fill() {
    let mut q = fixture::new();
    q.fund_incentives(INCENTIVES);
    let record_id = q.enqueue_amount(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MAX_PREMIUM,
        0,
        MAX_COST,
    );
    q.commit_at(TAU, LIMIT_SPOT);
    assert_eq!(q.record(record_id).escrow().subsidy_reserved(), RESERVED_SUBSIDY);
    let incentives_after_commit = q.market().fee_incentive_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    let used = fill.subsidy_used();
    assert!(used > 0 && used < RESERVED_SUBSIDY);
    assert!(fill.quantity() < QUANTITY);
    // Conservation: the reservation is either used or back in the incentives.
    assert_eq!(
        q.market().fee_incentive_balance(),
        incentives_after_commit + (RESERVED_SUBSIDY - used),
    );
    assert_eq!(q.record(record_id).funds(), 0);
    assert_fill_ledger(&q);
    q.assert_backed();
    q.finish();
}

/// A reason-1 refund keeps the order fee in market cash and returns the
/// budget to the trader and the whole reservation to the incentives; Predict
/// releases the cash need and prunes the unpinned node.
#[test]
fun a_limits_refund_returns_the_reservation_and_keeps_the_fee() {
    let mut q = fixture::new();
    q.fund_incentives(INCENTIVES);
    let incentives_before = q.market().fee_incentive_balance();
    let record_id = q.enqueue_quantity(
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        MAX_COST,
        MAX_PROBABILITY,
    );
    q.commit_at(TAU, LIMIT_SPOT);
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    assert_eq!(q.record(record_id).result().reason(), order_queue::reason_limits());
    assert_eq!(q.market().fee_incentive_balance(), incentives_before);
    assert_eq!(q.market().cash_balance(), cash_before + ORDER_FEE);
    let refund = events::refunds()[0];
    assert_eq!(refund.refund_subsidy_returned(), RESERVED_SUBSIDY);
    assert_eq!(refund.refund_escrow_returned(), MAX_COST);
    assert_eq!(refund.refund_order_fee_returned(), 0);
    // Escrow in = 3_000_000 + 20_000 + 4_000: 20_000 kept, 4_000 returned to the
    // incentives, 3_000_000 to the trader.
    assert_eq!(q.record(record_id).funds(), 0);
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(nodes, 0);
    q.assert_backed();
    q.finish();
}

// === Builder and referral fees ===

#[test]
fun a_builder_fee_is_charged_to_the_trader_and_leaves_the_market() {
    let (mut q, _) = fixture::new().link_builder_code(BUILDER_CODE_INDEX);
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.builder_fee(), BUILDER_FEE);
    assert_eq!(fill.amount(), ALL_IN_COST + BUILDER_FEE);
    assert_eq!(fill.referral_fee(), 0);
    // The builder fee leaves with the escrow: market cash gains only the
    // premium, the trading fee, and the order fee.
    assert_eq!(q.market().cash_balance(), cash_before + MINT_CASH);
    assert_fill_ledger(&q);
    q.assert_backed();
    q.finish();
}

#[test]
fun a_referral_fee_comes_out_of_the_trading_fee_and_leaves_the_market() {
    let (mut q, _) = fixture::new_referred();
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.referral_fee(), REFERRAL_FEE);
    // The trader's cost is unchanged; the referral comes out of the fee.
    assert_eq!(fill.amount(), ALL_IN_COST);
    assert_eq!(q.market().cash_balance(), cash_before + MINT_CASH - REFERRAL_FEE);
    assert_fill_ledger(&q);
    q.assert_backed();
    q.finish();
}

/// The referral is computed on the trader-paid part of the fee, so the subsidy
/// shrinks it.
#[test]
fun a_subsidized_referral_is_computed_on_the_trader_paid_fee() {
    let (mut q, _) = fixture::new_referred();
    q.fund_incentives(INCENTIVES);
    q.enqueue_atm(QUANTITY, MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let cash_before = q.market().cash_balance();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    assert_eq!(fill.subsidy_used(), RESERVED_SUBSIDY);
    assert_eq!(fill.referral_fee(), SUBSIDIZED_REFERRAL_FEE);
    assert_eq!(fill.amount(), SUBSIDIZED_COST);
    assert_eq!(q.market().cash_balance(), cash_before + MINT_CASH - SUBSIDIZED_REFERRAL_FEE);
    q.assert_backed();
    q.finish();
}

// === Inventory impact ===

/// With inventory impact on, a queued fill's impact charge lands in the
/// market's impact reserve, inside market cash, and the trader pays it.
#[test]
fun an_impact_charge_lands_in_the_reserve() {
    let mut q = impact_queue();
    let record_id = q.enqueue_atm(IMPACT_QUANTITY, IMPACT_MAX_COST);
    q.commit_at(TAU, fixture::live_price());
    let cash_before = q.market().cash_balance();
    let reserve_before = q.market().inventory_impact_reserve();

    assert_eq!(q.resolve(RESOLVE_ALL), 1);

    let fill = events::fills()[0];
    let impact = fill.inventory_impact();
    assert!(impact > 0);
    assert_eq!(q.market().inventory_impact_reserve(), reserve_before + impact);
    // The all-in cost carries the impact charge, and with no builder, referral,
    // or subsidy the market gains all of it plus the order fee.
    assert_eq!(q.market().cash_balance(), cash_before + fill.amount() + ORDER_FEE);
    assert_eq!(q.record(record_id).result().result_amount(), fill.amount());
    assert_fill_ledger(&q);
    q.assert_backed();
    q.finish();
}

// === Helpers ===

/// After a fill: no waiting cash need and the filled boundary node kept.
fun assert_fill_ledger(q: &QueueTest) {
    let (waiting_cash_need, nodes) = q.ledger();
    assert_eq!(waiting_cash_need, 0);
    assert_eq!(nodes, 1);
    q.assert_invariants();
}

/// The default live market created with inventory impact on, in the queue
/// fixture.
fun impact_queue(): QueueTest {
    let mut fx = helpers::setup_market_default();
    fx.set_template_inventory_impact_max_rate(IMPACT_MAX_RATE);
    fx.set_default_cadence_allocation(IMPACT_SCALE, test_constants::default_initial_expiry_cash());
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let trader = fx.create_funded_manager(test_constants::mint_deposit());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, fixture::live_price());
    fx.seed_market_cash(
        helpers::market_mut(&mut market),
        test_constants::default_seeded_expiry_cash(),
    );
    helpers::return_market_bundle(market);
    fixture::from_fixture(fx, expiry_id, trader)
}
