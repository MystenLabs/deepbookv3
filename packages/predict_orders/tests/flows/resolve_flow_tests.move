// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for `resolve`: fills of each mint kind and of early sells at
/// the committed tick with their cost decomposition, the refund reasons and
/// where each order fee goes, the reason-8 cash check, the `max_orders` walk
/// with its span resume (D8 B1), cohorts committed out of τ order, overdue
/// orders, and the call's gates.
///
/// Timing follows the default policy from the fixture clock 120_000: τ =
/// floor((t₀ + 1_000) / 200) * 200, deadline τ + 5_000. Placements at 120_000,
/// 120_200, 121_000, and 122_000 land on τ 121_000, 121_200, 122_000, and
/// 123_000.
///
/// Fill arithmetic, independent of the contract: the fixture's minimum fee is
/// 0.005 per unit of quantity and its base fee rounds the Bernoulli term to
/// zero, the ramp is 1 this far from expiry, inventory impact is off, and no
/// builder or referrer is set unless a test says so. At the live price the
/// strike is at the money, and every probability in the reference digital's
/// ±21 band, 499_993_669..499_993_711 (1e-9), floors to the same premiums used
/// below.
#[test_only]
module deepbook_predict::resolve_flow_tests;

use deepbook_predict::{
    commit_resolve_test_helpers as h,
    constants,
    flow_test_helpers::{Self as helpers, Fixture, MarketBundle, AccountBundle},
    order,
    order_queue,
    protocol_config,
    queue_test_helpers as queue,
    test_constants
};
use std::unit_test::assert_eq;

const QUANTITY: u64 = 4_000_000;
const MAX_COST: u64 = 3_000_000;
/// floor(p * 4m): 1_999_974.68..1_999_974.84 across the band.
const PREMIUM: u64 = 1_999_974;
/// 0.005 * 4m.
const TRADING_FEE: u64 = 20_000;
/// PREMIUM + TRADING_FEE.
const ALL_IN_COST: u64 = 2_019_974;
/// The policy's default order fee.
const ORDER_FEE: u64 = 20_000;
/// Market cash one 4m at-the-money mint adds: PREMIUM + TRADING_FEE + ORDER_FEE.
const MINT_CASH: u64 = 2_039_974;
/// Premium cap for the exact-amount mint: 4m costs PREMIUM <= 2m, while 4.01m
/// costs floor(p * 4.01m) = 2_004_974 > 2m, so the fill is 4m.
const MAX_PREMIUM: u64 = 2_000_000;
/// A partial sell: floor(p * 2m) = 999_987 (999_987.34..999_987.42 across the
/// band), fee 0.005 * 2m = 10_000, proceeds 989_987.
const HALF: u64 = 2_000_000;
const HALF_REDEEM: u64 = 999_987;
const HALF_FEE: u64 = 10_000;
const HALF_PROCEEDS: u64 = 989_987;
const TAU: u64 = 121_000;
const SECOND_PLACEMENT_MS: u64 = 120_200;
const SECOND_TAU: u64 = 121_200;
const SELL_TAU: u64 = 122_000;
const LAST_SELL_TAU: u64 = 123_000;
const DEADLINE: u64 = 126_000;
const SECOND_DEADLINE: u64 = 126_200;
const MAX_ORDERS: u64 = 100;
/// A 0.6 cap the at-the-money t₀ quote passes.
const MAX_PROBABILITY: u64 = 600_000_000;
/// A 0.4 sell floor the at-the-money t₀ quote passes.
const MIN_SELL_PROBABILITY: u64 = 400_000_000;
/// Committed spots that move the (100, +inf) digital. The fixture surface has
/// total variance a = 1e-9 (sqrt 3.1623e-5; the b term is below 1e-12), so
/// d2 = ln(F / K) / 3.1623e-5 - 1.6e-5:
/// - 100.002: d2 = 0.6324, p = 0.736, inside the 0.01..0.99 band, above 0.6;
/// - 100.01: d2 = 3.162, p = 0.9992, above the 0.99 band;
/// - 99.998: d2 = -0.6325, p = 0.264;
/// - 99.993: d2 = -2.2137, p = 0.0134, just inside the band.
const LIMIT_SPOT: u64 = 100_002_000_000;
const BELOW_FLOOR_SPOT: u64 = 99_998_000_000;
const OUT_OF_BAND_SPOT: u64 = 100_010_000_000;
const LOW_SPOT: u64 = 99_993_000_000;
/// The reason-8 market. Each 100m order needs ceil(0.99 * 100m) + 1 =
/// 99_000_001 of spare cash at placement, which 185m covers. At p = 0.0134 a
/// 100m fill adds about 1.34m premium + 0.5m fee + 0.02m order fee and owes
/// 100m, so the first fill leaves cash near 186.86m against 100m required; the
/// second would need 200m against about 188.73m and is refunded; an 80m third
/// needs 180m against about 188.36m and fills. Every margin is millions of
/// units, far beyond the band's rounding.
const SHORT_CASH: u64 = 185_000_000;
const BIG_QUANTITY: u64 = 100_000_000;
const THIRD_QUANTITY: u64 = 80_000_000;
/// The reason-8 boundary. Three 4m at-the-money mints owe 12m together and
/// each brings MINT_CASH, so the third fill leaves cash at
/// BOUNDARY_CASH + 3 * 2_039_974 = 12_000_000, exactly its required cash. Each
/// placement needs ceil(0.99 * 4m) + 1 = 3_960_001 of spare cash, which both
/// seeds cover, and the first two fills clear by 1_960_026 per order.
const BOUNDARY_CASH: u64 = 5_880_078;
const BOUNDARY_ORDERS: u64 = 3;
/// D8 B1: 60 orders in one cohort walked 15 at a time.
const BATCH_ORDERS: u64 = 60;
const BATCH_SIZE: u64 = 15;
/// Subsidy: the default 20% of the 20_000 subsidy bound, as `commit_flow_tests`.
const RESERVED_SUBSIDY: u64 = 4_000;
/// The trader pays ALL_IN_COST less the subsidy the reservation covers.
const SUBSIDIZED_COST: u64 = 2_015_974;

// === Fills ===

#[test]
fun resolve_fills_an_exact_quantity_mint_at_its_tick() {
    let (fx, market, account, record_id, cash_before) = filled_mint();

    let order = h::record(&market, record_id);
    assert_eq!(order.status(), order_queue::status_open());
    let position = order.position();
    let minted = order::from_order_id(position.order_id());
    assert_eq!(minted.lower_tick(), helpers::strike_tick());
    assert_eq!(minted.higher_tick(), helpers::pos_inf_tick());
    assert_eq!(minted.quantity(), QUANTITY);
    assert_eq!(position.root_id(), position.order_id());
    assert_eq!(position.opened_at_ms(), TAU);
    assert_eq!(order.result().reason(), 0);
    assert_eq!(order.result().result_quantity(), QUANTITY);
    assert_eq!(order.result().result_amount(), PREMIUM + TRADING_FEE);
    assert_eq!(order.result().finished_at_ms(), TAU);

    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_before + PREMIUM + TRADING_FEE + ORDER_FEE,
    );
    // One order over one range: required cash is its full payout.
    assert_eq!(helpers::market(&market).required_cash(), QUANTITY);
    // The fill reused the node placement pinned.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_reports_a_mint_fill_in_queued_order_filled() {
    let (fx, market, account, record_id, cash_before) = filled_mint();
    let position = h::record(&market, record_id).position();

    let fills = h::fills();
    assert_eq!(fills.length(), 1);
    let fill = fills[0];
    assert_eq!(fill.market_cash(), cash_before + MINT_CASH);
    assert_eq!(fill.required_cash(), QUANTITY);
    assert_eq!(fill.waiting_cash_need(), 0);
    assert_eq!(fill.expiry_market_id(), helpers::market(&market).id());
    assert_eq!(fill.record_id(), record_id);
    assert_eq!(fill.account_id(), helpers::account_id_bundle(&account));
    assert_eq!(fill.kind(), order_queue::kind_exact_quantity());
    assert_eq!(fill.quantity(), QUANTITY);
    assert_eq!(fill.amount(), ALL_IN_COST);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(fill.builder_fee(), 0);
    assert_eq!(fill.referral_fee(), 0);
    assert_eq!(fill.order_fee(), ORDER_FEE);
    assert_eq!(fill.subsidy_used(), 0);
    assert_eq!(fill.inventory_impact(), 0);
    assert_eq!(fill.tau_ms(), TAU);
    assert_eq!(fill.tick_ms(), TAU);
    assert_eq!(fill.position_order_id(), position.order_id());
    assert_eq!(fill.position_root_id(), position.order_id());
    assert_eq!(fill.position_opened_at_ms(), TAU);
    assert_eq!(fill.sender(), test_constants::alice());
    assert_eq!(fill.onchain_timestamp_ms(), TAU);
    h::finish(fx, market, account);
}

#[test]
fun resolve_clears_the_queue_counters_after_the_last_fill() {
    let (fx, market, account, _, _) = filled_mint();

    let (resolve_head, next_id, _, _) = helpers::market(&market).queue_heads();
    assert_eq!(resolve_head, next_id);
    let (cohorts, _, _) = helpers::market(&market).waiting_cohorts();
    assert_eq!(cohorts, 0);
    let (pending_mints, pending_sells) = helpers::market(&market).pending_counts();
    assert_eq!(pending_mints, 0);
    assert_eq!(pending_sells, 0);
    assert_eq!(helpers::market(&market).waiting_orders(helpers::account_id_bundle(&account)), 0);
    assert_eq!(helpers::market(&market).waiting_cash_need(), 0);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

#[test]
fun resolve_fills_budget_mints_at_their_tick() {
    let (mut fx, mut market, mut account) = queue_market();
    let amount_id = queue::enqueue_exact_amount(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        MAX_PREMIUM,
        QUANTITY,
        MAX_COST,
    );
    // The all-in budget buys 4m exactly: 4.01m would cost 2_004_974 + 20_050.
    let cost_id = queue::enqueue_exact_cost(
        &mut fx,
        &mut market,
        &mut account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        ALL_IN_COST,
        QUANTITY,
    );
    let cash_before = helpers::market(&market).cash_balance();
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 2);

    vector[amount_id, cost_id].do!(|record_id| {
        let order = h::record(&market, record_id);
        assert_eq!(order.status(), order_queue::status_open());
        assert_eq!(order::from_order_id(order.position().order_id()).quantity(), QUANTITY);
        assert_eq!(order.result().result_quantity(), QUANTITY);
        assert_eq!(order.result().result_amount(), ALL_IN_COST);
    });
    let fills = h::fills();
    assert_eq!(fills.length(), 2);
    assert_eq!(fills[0].kind(), order_queue::kind_exact_amount());
    assert_eq!(fills[1].kind(), order_queue::kind_exact_cost());
    assert_eq!(fills[1].trading_fee(), TRADING_FEE);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + 2 * MINT_CASH);
    assert_eq!(helpers::market(&market).required_cash(), 2 * QUANTITY);
    queue::assert_queue_invariants(helpers::market(&market));
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_closes_part_of_a_queued_sell_position() {
    let (fx, market, account, minted_order_id, cash_after_mint, partial_id) = partial_sell();

    let partial = h::record(&market, partial_id);
    assert_eq!(partial.status(), order_queue::status_open());
    let remainder = partial.position();
    assert_eq!(order::from_order_id(remainder.order_id()).quantity(), HALF);
    assert_eq!(remainder.root_id(), minted_order_id);
    // The open time carries over from the mint's tick.
    assert_eq!(remainder.opened_at_ms(), TAU);
    assert_eq!(partial.result().result_quantity(), HALF);
    assert_eq!(partial.result().result_amount(), HALF_PROCEEDS);
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_after_mint - HALF_REDEEM + HALF_FEE + ORDER_FEE,
    );
    assert_eq!(helpers::market(&market).required_cash(), HALF);
    let fills = h::fills();
    let fill = fills[fills.length() - 1];
    assert_eq!(fill.kind(), order_queue::kind_redeem_open());
    assert_eq!(fill.quantity(), HALF);
    assert_eq!(fill.amount(), HALF_PROCEEDS);
    assert_eq!(fill.trading_fee(), HALF_FEE);
    assert_eq!(fill.order_fee(), ORDER_FEE);
    assert_eq!(fill.position_order_id(), remainder.order_id());
    assert_eq!(fill.position_root_id(), minted_order_id);
    queue::assert_queue_invariants(helpers::market(&market));
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_closes_the_rest_of_a_queued_sell_position() {
    let (mut fx, mut market, mut account, _, cash_after_mint, partial_id) = partial_sell();
    let full_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        partial_id,
        HALF,
        0,
        0,
    );
    commit_at(&mut fx, &mut market, LAST_SELL_TAU, test_constants::default_live_price());

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);

    let full = h::record(&market, full_id);
    assert_eq!(full.status(), order_queue::status_closed());
    assert_eq!(full.position().order_id(), 0);
    assert_eq!(full.result().result_amount(), HALF_PROCEEDS);
    assert_eq!(h::record(&market, partial_id).status(), order_queue::status_closed());
    assert_eq!(
        helpers::market(&market).cash_balance(),
        cash_after_mint - 2 * (HALF_REDEEM - HALF_FEE - ORDER_FEE),
    );
    assert_eq!(helpers::market(&market).required_cash(), 0);
    queue::assert_queue_invariants(helpers::market(&market));
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_charges_the_reserved_subsidy() {
    let (mut fx, mut market, mut account) = queue_market();
    fx.sponsor_fee_incentives_bundle(&mut market, test_constants::usdc_unit() * 10);
    fx.rebalance_expiry_cash_bundle(&mut market);
    let record_id = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    let incentives_after_commit = helpers::market(&market).fee_incentive_balance();
    let cash_before = helpers::market(&market).cash_balance();

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);

    // min(0.2 * 20_000, 4_000 reserved) = 4_000 used, so none goes back.
    let fills = h::fills();
    let fill = fills[0];
    assert_eq!(fill.subsidy_used(), RESERVED_SUBSIDY);
    assert_eq!(fill.amount(), SUBSIDIZED_COST);
    assert_eq!(fill.trading_fee(), TRADING_FEE);
    assert_eq!(h::record(&market, record_id).result().result_amount(), SUBSIDIZED_COST);
    // The subsidy lands in market cash beside the trader's share of the fee.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + MINT_CASH);
    assert_eq!(helpers::market(&market).fee_incentive_balance(), incentives_after_commit);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

// === Refunds ===

#[test]
fun resolve_refunds_limit_and_admission_misses_keeping_the_fee() {
    let (mut fx, mut market, mut account) = queue_market();
    let limit_id = place_with_max_probability(&mut fx, &mut market, &mut account, MAX_PROBABILITY);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let band_id = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    let cash_before = helpers::market(&market).cash_balance();
    fx.set_clock_for_testing(SECOND_TAU);
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(TAU, LIMIT_SPOT), h::price_tick(SECOND_TAU, OUT_OF_BAND_SPOT)],
    );

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 2);

    let limit = h::record(&market, limit_id);
    assert_eq!(limit.status(), order_queue::status_refunded());
    assert_eq!(limit.result().reason(), order_queue::reason_limits());
    let band = h::record(&market, band_id);
    assert_eq!(band.status(), order_queue::status_refunded());
    assert_eq!(band.result().reason(), order_queue::reason_admission());
    // Both reasons keep the order fee in market cash.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + 2 * ORDER_FEE);
    let refunds = h::refunds();
    assert_eq!(refunds.length(), 2);
    refunds.do_ref!(|refund| {
        assert_eq!(refund.refund_escrow_returned(), MAX_COST);
        assert_eq!(refund.refund_order_fee_returned(), 0);
        assert_eq!(refund.refund_sender(), test_constants::alice());
    });
    assert_eq!(refunds[0].refund_reason(), order_queue::reason_limits());
    assert_eq!(refunds[1].refund_reason(), order_queue::reason_admission());
    // Both pins are gone, so the empty boundary node is pruned.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 0);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

#[test]
fun resolve_refunds_a_sell_below_its_floor_and_returns_the_position() {
    let (mut fx, mut market, mut account) = queue_market();
    let mint_id = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    queue::resolve(&mut fx, &mut market, MAX_ORDERS);
    let minted_order_id = h::record(&market, mint_id).position().order_id();
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), TAU);
    let sell_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        mint_id,
        QUANTITY,
        MIN_SELL_PROBABILITY,
        0,
    );
    let cash_before = helpers::market(&market).cash_balance();
    commit_at(&mut fx, &mut market, SELL_TAU, BELOW_FLOOR_SPOT);

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);

    let sell = h::record(&market, sell_id);
    assert_eq!(sell.status(), order_queue::status_open());
    assert_eq!(sell.result().reason(), order_queue::reason_limits());
    assert_eq!(sell.position().order_id(), minted_order_id);
    assert_eq!(helpers::market(&market).cash_balance(), cash_before + ORDER_FEE);
    assert_eq!(helpers::market(&market).required_cash(), QUANTITY);
    let refunds = h::refunds();
    let refund = refunds[0];
    assert!(refund.refund_position_returned());
    assert_eq!(refund.refund_kind(), order_queue::kind_redeem_open());
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

#[test]
fun resolve_refunds_a_cash_short_mint_with_reason_8_and_fills_the_next() {
    let (mut fx, expiry_id, trader) = h::setup_queue_market_with_cash(SHORT_CASH);
    let (mut market, mut account) = h::enter(&mut fx, expiry_id, &trader);
    let first = place(&mut fx, &mut market, &mut account, BIG_QUANTITY, BIG_QUANTITY);
    let short = place(&mut fx, &mut market, &mut account, BIG_QUANTITY, BIG_QUANTITY);
    let third = place(&mut fx, &mut market, &mut account, THIRD_QUANTITY, THIRD_QUANTITY);
    commit_at(&mut fx, &mut market, TAU, LOW_SPOT);

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 3);

    assert_eq!(h::record(&market, first).status(), order_queue::status_open());
    let refunded = h::record(&market, short);
    assert_eq!(refunded.status(), order_queue::status_refunded());
    assert_eq!(refunded.result().reason(), order_queue::reason_no_cash());
    assert_eq!(h::record(&market, third).status(), order_queue::status_open());
    let refunds = h::refunds();
    let refund = refunds[0];
    assert_eq!(refund.refund_record_id(), short);
    assert_eq!(refund.refund_reason(), order_queue::reason_no_cash());
    // Reason 8 returns the whole escrow, order fee included.
    assert_eq!(refund.refund_escrow_returned(), BIG_QUANTITY);
    assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE);
    let fills = h::fills();
    assert_eq!(fills.length(), 2);
    assert_eq!(fills[0].record_id(), first);
    assert_eq!(fills[1].record_id(), third);
    assert_eq!(helpers::market(&market).required_cash(), BIG_QUANTITY + THIRD_QUANTITY);
    queue::assert_queue_invariants(helpers::market(&market));
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_fills_when_cash_after_equals_required_cash() {
    let (mut fx, mut market, mut account) = boundary_market(BOUNDARY_CASH);
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), BOUNDARY_ORDERS);

    BOUNDARY_ORDERS.do!(|record_id| {
        assert_eq!(h::record(&market, record_id).status(), order_queue::status_open());
    });
    assert_eq!(helpers::market(&market).cash_balance(), BOUNDARY_ORDERS * QUANTITY);
    assert_eq!(helpers::market(&market).required_cash(), BOUNDARY_ORDERS * QUANTITY);
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_refunds_with_reason_8_one_unit_short_of_required_cash() {
    let (mut fx, mut market, mut account) = boundary_market(BOUNDARY_CASH - 1);
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), BOUNDARY_ORDERS);

    let last = h::record(&market, BOUNDARY_ORDERS - 1);
    assert_eq!(last.status(), order_queue::status_refunded());
    assert_eq!(last.result().reason(), order_queue::reason_no_cash());
    assert_eq!(
        helpers::market(&market).cash_balance(),
        BOUNDARY_CASH - 1 + (BOUNDARY_ORDERS - 1) * MINT_CASH,
    );
    assert_eq!(helpers::market(&market).required_cash(), (BOUNDARY_ORDERS - 1) * QUANTITY);
    helpers::assert_market_backed_bundle(&market);
    h::finish(fx, market, account);
}

#[test]
fun resolve_refunds_overdue_orders_with_reason_5_returning_the_fee() {
    let (mut fx, mut market, mut account) = queue_market();
    let committed = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let waiting = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    let cash_before = helpers::market(&market).cash_balance();

    // At the first deadline the committed order is refunded, never filled; the
    // second cohort is not yet due and, uncommitted, is not walked.
    fx.set_clock_for_testing(DEADLINE);
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);
    assert_eq!(h::record(&market, committed).result().reason(), order_queue::reason_deadline());
    assert_eq!(h::record(&market, waiting).status(), order_queue::status_pending());

    // At its own deadline the uncommitted order is refunded too.
    fx.set_clock_for_testing(SECOND_DEADLINE);
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);
    let refunded = h::record(&market, waiting);
    assert_eq!(refunded.status(), order_queue::status_refunded());
    assert_eq!(refunded.result().reason(), order_queue::reason_deadline());

    // Reason 5 returns the order fee, so market cash never moved.
    assert_eq!(helpers::market(&market).cash_balance(), cash_before);
    h::refunds().do!(|refund| assert_eq!(refund.refund_order_fee_returned(), ORDER_FEE));
    let (cohorts, _, _) = helpers::market(&market).waiting_cohorts();
    assert_eq!(cohorts, 0);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

// === The walk ===

#[test]
fun resolve_sixty_orders_with_max_orders_fifteen_finish_in_four_calls() {
    let (mut fx, mut market, mut account) = queue_market();
    let (admin_cap, clock, _) = fx.admin_parts();
    // Let one account hold the whole cohort.
    helpers::config_mut(&mut market).set_delayed_execution_limits(
        admin_cap,
        100,
        100,
        BATCH_ORDERS,
        constants::position_lot_size!(),
        450,
        900,
        clock,
    );
    BATCH_ORDERS.do!(|_| { place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST); });
    let (cohorts, _, _) = helpers::market(&market).waiting_cohorts();
    assert_eq!(cohorts, 1);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());

    let mut call = 1;
    while (call <= BATCH_ORDERS / BATCH_SIZE) {
        assert_eq!(queue::resolve(&mut fx, &mut market, BATCH_SIZE), BATCH_SIZE);
        // Each call resumes where the last stopped instead of re-walking.
        let (resolve_head, _, _, _) = helpers::market(&market).queue_heads();
        assert_eq!(resolve_head, call * BATCH_SIZE);
        call = call + 1;
    };
    assert_eq!(queue::resolve(&mut fx, &mut market, BATCH_SIZE), 0);
    BATCH_ORDERS.do!(|record_id| {
        assert_eq!(h::record(&market, record_id).status(), order_queue::status_open());
    });
    let (cohorts, _, _) = helpers::market(&market).waiting_cohorts();
    assert_eq!(cohorts, 0);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

#[test]
fun resolve_counts_finished_records_against_max_orders() {
    let (mut fx, mut market, mut account) = queue_market();
    let refunded = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    let second = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    let third = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    queue::admin_refund(&mut fx, &mut market, vector[refunded]);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());

    // The finished first record still uses up the one visit.
    assert_eq!(queue::resolve(&mut fx, &mut market, 1), 0);
    assert_eq!(h::record(&market, second).status(), order_queue::status_committed());
    // The span resumes past it, so each later call reaches a new order.
    assert_eq!(queue::resolve(&mut fx, &mut market, 1), 1);
    assert_eq!(h::record(&market, second).status(), order_queue::status_open());
    assert_eq!(queue::resolve(&mut fx, &mut market, 1), 1);
    assert_eq!(h::record(&market, third).status(), order_queue::status_open());
    h::finish(fx, market, account);
}

#[test]
fun resolve_skips_uncommitted_cohorts_without_visiting_them() {
    let (mut fx, mut market, mut account) = queue_market();
    let early = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    fx.set_clock_for_testing(SECOND_PLACEMENT_MS);
    let late = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    // Only the later cohort has its price.
    commit_at(&mut fx, &mut market, SECOND_TAU, test_constants::default_live_price());

    // One visit is enough because the waiting earlier cohort costs none.
    assert_eq!(queue::resolve(&mut fx, &mut market, 1), 1);
    assert_eq!(h::record(&market, late).status(), order_queue::status_open());
    assert_eq!(h::record(&market, early).status(), order_queue::status_pending());

    // The earlier cohort still fills at its own τ once its price lands.
    queue::commit_decoded(
        &mut fx,
        &mut market,
        vector[h::price_tick(TAU, test_constants::default_live_price())],
    );
    assert_eq!(queue::resolve(&mut fx, &mut market, 1), 1);
    let filled = h::record(&market, early);
    assert_eq!(filled.status(), order_queue::status_open());
    assert_eq!(filled.position().opened_at_ms(), TAU);
    queue::assert_queue_invariants(helpers::market(&market));
    h::finish(fx, market, account);
}

#[test]
fun resolve_returns_zero_before_any_commit() {
    let (mut fx, mut market, mut account) = queue_market();
    let record_id = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    fx.set_clock_for_testing(TAU);

    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 0);
    assert_eq!(h::record(&market, record_id).status(), order_queue::status_pending());
    h::finish(fx, market, account);
}

// === Gates ===

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun resolve_while_frozen_aborts() {
    let (mut fx, mut market, mut account) = queue_market();
    place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    fx.set_frozen_bundle(&mut market, true);
    queue::resolve(&mut fx, &mut market, MAX_ORDERS);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPolicyNotInitialized)]
fun resolve_before_the_policy_exists_aborts() {
    let (mut fx, expiry_id, _) = helpers::setup_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let mut market = fx.take_market_bundle(expiry_id);
    queue::resolve(&mut fx, &mut market, MAX_ORDERS);
    abort 999
}

// === Helpers ===

fun queue_market(): (Fixture, MarketBundle, AccountBundle) {
    let (mut fx, expiry_id, trader) = queue::setup_queue_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let (market, account) = h::enter(&mut fx, expiry_id, &trader);
    (fx, market, account)
}

/// The default queue market after one 4m mint filled at τ. Returns the record
/// ID and the market cash before the fill.
fun filled_mint(): (Fixture, MarketBundle, AccountBundle, u64, u64) {
    let (mut fx, mut market, mut account) = queue_market();
    let record_id = place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST);
    // Placement pinned the finite boundary node.
    assert_eq!(helpers::market(&market).payout_tree_node_count(), 1);
    let cash_before = helpers::market(&market).cash_balance();
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);
    (fx, market, account, record_id, cash_before)
}

/// `filled_mint`, then half of its Open record sold through the queue at
/// SELL_TAU. Returns the minted order ID, the market cash after the mint, and
/// the sell's record ID.
fun partial_sell(): (Fixture, MarketBundle, AccountBundle, u256, u64, u64) {
    let (mut fx, mut market, mut account, mint_id, _) = filled_mint();
    let minted_order_id = h::record(&market, mint_id).position().order_id();
    let cash_after_mint = helpers::market(&market).cash_balance();
    // Fresh feeds at τ, so the sell's placement passes the freshness checks.
    fx.advance_live_oracle_bundle_to(&mut market, test_constants::default_live_price(), TAU);
    let partial_id = queue::enqueue_redeem_open(
        &mut fx,
        &mut market,
        &mut account,
        mint_id,
        HALF,
        0,
        0,
    );
    commit_at(&mut fx, &mut market, SELL_TAU, test_constants::default_live_price());
    assert_eq!(queue::resolve(&mut fx, &mut market, MAX_ORDERS), 1);
    (fx, market, account, minted_order_id, cash_after_mint, partial_id)
}

/// A market holding exactly `cash` with BOUNDARY_ORDERS 4m mints committed at
/// the live price, ready to resolve.
fun boundary_market(cash: u64): (Fixture, MarketBundle, AccountBundle) {
    let (mut fx, expiry_id, trader) = h::setup_queue_market_with_cash(cash);
    let (mut market, mut account) = h::enter(&mut fx, expiry_id, &trader);
    BOUNDARY_ORDERS.do!(|_| { place(&mut fx, &mut market, &mut account, QUANTITY, MAX_COST); });
    commit_at(&mut fx, &mut market, TAU, test_constants::default_live_price());
    (fx, market, account)
}

/// An exact-quantity mint over `(strike, +inf]` with no probability cap.
fun place(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    quantity: u64,
    max_cost: u64,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        quantity,
        max_cost,
        std::u64::max_value!(),
    )
}

fun place_with_max_probability(
    fx: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    max_probability: u64,
): u64 {
    queue::enqueue_exact_quantity(
        fx,
        market,
        account,
        helpers::strike_tick(),
        helpers::pos_inf_tick(),
        QUANTITY,
        MAX_COST,
        max_probability,
    )
}

/// Move the clock to `tau_ms` and commit that cohort at `spot`.
fun commit_at(fx: &mut Fixture, market: &mut MarketBundle, tau_ms: u64, spot: u64) {
    fx.set_clock_for_testing(tau_ms);
    queue::commit_decoded(fx, market, vector[h::price_tick(tau_ms, spot)]);
}
