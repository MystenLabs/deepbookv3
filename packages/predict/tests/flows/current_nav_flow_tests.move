// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Differential coverage for the exact single-expiry live NAV reader
/// (`expiry_market::current_nav`). Every test builds protocol state through the
/// production mint flow, then asserts `current_nav` exactly equals an INDEPENDENT
/// per-order reference (`reference_nav`): `free_cash - Σ (knocked-out ? 0 :
/// max(0, qty·P - floor))`, computed straight from each order's atoms and
/// `pricing::range_price` (a knocked-out leveraged order is marked at its
/// liquidated worth, RP-17). The
/// reference reuses NONE of `walk_linear` / `correction_value` /
/// `marked_live_liability` / `current_nav` / `expiry_cash::free_cash`, so it is a
/// genuine oracle (unit-tests rule 1): it sums per order, while the contract
/// decomposes into a boundary-aggregated linear walk minus a leveraged-book
/// correction walk.
///
/// ## How far the two may legitimately differ
///
/// The contract and the reference compute the same function; they differ only in
/// WHERE integer truncation lands. Three of the four candidate divergence sites
/// contribute exactly zero:
///
/// - The knock-out predicates are equivalent, not merely similar. The contract
///   tests `ceil(rv*ltv/S) <= F` and the reference `rv <= floor(F*S/ltv)`; since
///   `F` and `rv` are integers, both reduce to `rv * ltv <= F * S`.
/// - The floor cap agrees exactly: `clamp_upper` is `min(rv, F)`, so the contract's
///   per-order net `rv - cap` is `0` when knocked out and `max(0, rv - F)`
///   otherwise — the reference's contribution verbatim.
/// - The range price feeding the correction agrees bit-for-bit: `cached_range_price`
///   then `mul_exact` floors `(P(l) - P(h)) * q / S` once, exactly as the
///   reference's `mul_down` does.
///
/// All divergence therefore sits in the linear term, where the reference floors
/// once per ORDER and the contract's boundary walk floors once per NODE. The
/// pre-truncation identity is exact
/// (`Σ_o q(P(l)-P(h))/S == base_q + Σ_t n_t P(t)/S`), each node's signed
/// `mul_scaled` errs within one raw unit, each order's `mul_down` errs within one
/// raw unit downward, and nodes with zero net quantity contribute nothing
/// (`mul_exact` absorbs them). Hence
///
///   `|current_nav - reference_nav| <= N + M` raw units,
///
/// with `N` the distinct finite boundary ticks and `M` the open orders — both
/// structural counts, independent of prices, quantities, floors, and leverage.
///
/// A `(-inf, h]` order biases that difference upward by construction: the contract
/// computes `q - floor(P(h)q/S)` where the reference computes `q - ceil(P(h)q/S)`.
///
/// The fixtures in this module are all engineered to sit at `N + M = 0` slack:
/// every finite boundary is anchored at `strike_tick` (whose raw strike == the
/// seeded forward, so `UP(strike) = Φ(0) = 0.5` exactly with the SVI wing rounded
/// to zero) with even quantities, making every product integral. They therefore
/// keep the strictly stronger `assert_eq`. Fixtures that price a real multi-tick
/// smile cannot be dust-free and assert within the bound instead.
#[test_only]
module deepbook_predict::current_nav_flow_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    order,
    pricing::{Self, Pricer},
    range_codec,
    test_constants
};
use fixed_math::{approx::Approx, math::{Self, float_scaling as float}};
use std::unit_test::assert_eq;

/// 1x ATM up range, quantity 2e9: priced 0.5 -> 1e9 liability.
const ONE_X_QUANTITY: u64 = 2_000_000_000;
/// Leveraged up range, quantity 2e9, 2x: net_premium 5e8, floor_shares 5e8.
const LEVERAGED_QUANTITY: u64 = 2_000_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Second same-strike up order, quantity 4e9.
const SECOND_SAME_STRIKE_QUANTITY: u64 = 4_000_000_000;
/// Deep-OTM forward (well below the 100e9 grid) so the minted up range prices to
/// ~0, driving the leveraged order underwater (value <= floor).
const UNDERWATER_FORWARD: u64 = 10_000_000_000;
const NON_MONOTONE_A_MAGNITUDE: u64 = 1;
const NON_MONOTONE_LOWER_TICK: u64 = 90;
const NON_MONOTONE_HIGHER_TICK: u64 = 100;
/// High base variance (0.1) so prices are smooth, plus a forward below the 100e9
/// strike that lands the 2x `LEVERAGED_QUANTITY` UP range in the knock-out band
/// `(floor, floor / liquidation_ltv]` — worth more than its 5e8 floor but at or
/// below the ~5.88e8 liquidation threshold (`up_price ≈ 0.27` → range ≈ 5.4e8).
const KNOCKOUT_BAND_A: u64 = 100_000_000;
const KNOCKOUT_BAND_FORWARD: u64 = 86_600_000_000;

#[test]
fun empty_live_market_values_at_free_cash() {
    let (mut fx, expiry_id, _trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);

    // No orders: NAV is exactly the seeded free cash (no fees yet -> rebate 0).
    let nav = fx.current_nav_bundle(&market);
    assert_eq!(nav, test_constants::default_seeded_expiry_cash());
    check_nav(&fx, &market, vector[]);
    let pricer = fx.load_pricer_bundle(&market);
    let approximate = helpers::market(&market).current_nav_approx(&pricer);
    assert_eq!(approximate.magnitude(), nav);
    assert_eq!(approximate.error(), 0);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_one_x_up_order() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    check_nav(&fx, &market, vector[id]);
    check_single_order_nav_enclosure(&fx, &market, id);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_one_x_down_order_anchored_at_neg_inf() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // The (-inf, strike] range exercises the `tree.base` (P(-inf) = 1) anchor.
    check_nav(&fx, &market, vector[id]);
    check_single_order_nav_enclosure(&fx, &market, id);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun two_one_x_orders_same_strike_collapse_to_one_node() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id1 = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let id2 = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        SECOND_SAME_STRIKE_QUANTITY,
        test_constants::leverage_one_x(),
    );

    // Both up orders share the strike start boundary -> one tree node priced
    // once at P(strike); the aggregate quantity equals the per-order sum.
    check_nav(&fx, &market, vector[id1, id2]);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_leveraged_order_above_floor() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // value = mul_down(0.5, 2e9) = 1e9 > floor = mul_down(floor_shares 5e8, 1.0) = 5e8, so the
    // correction min() picks the floor and the order's net liability is 5e8.
    check_nav(&fx, &market, vector[id]);
    check_single_order_nav_enclosure(&fx, &market, id);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun single_leveraged_order_underwater_nets_to_zero() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // Drop the forward far below the grid so the up range prices to ~0: value <=
    // floor, the order's limited-recourse floor zeroes its net liability with NO
    // liquidation pass, and NAV returns to free cash.
    fx.prepare_live_oracle_bundle(&mut market, UNDERWATER_FORWARD);

    let expiry_market = helpers::market(&market);
    let nav = fx.current_nav_bundle(&market);
    assert_eq!(nav, expiry_market.cash_balance().saturating_sub(expiry_market.rebate_reserve()));
    check_nav(&fx, &market, vector[id]);
    check_single_order_nav_enclosure(&fx, &market, id);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun knocked_out_leveraged_order_marks_at_liquidated_value() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let id = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // Reprice onto a smooth high-variance surface at a forward below the strike so
    // the leveraged UP range lands in the knock-out band (floor, floor / ltv]:
    // worth more than its floor but at or below the liquidation threshold. m = 0
    // keeps the SVI wing term safely positive.
    fx.seed_bs_surface_with_svi_bundle(
        &mut market,
        test_constants::default_live_price(),
        KNOCKOUT_BAND_FORWARD,
        KNOCKOUT_BAND_A,
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        0,
        false,
        test_constants::live_source_timestamp_ms() + 1,
    );

    // Precondition: the order really is in the band, or the test is vacuous.
    let pricer = fx.load_pricer_bundle(&market);
    let expiry_market = helpers::market(&market);
    let decoded = order::from_order_id(id);
    let range_value = math::mul_down(
        pricer.range_price(
            range_codec::strike_from_tick(decoded.lower_tick(), expiry_market.tick_size()),
            range_codec::strike_from_tick(decoded.higher_tick(), expiry_market.tick_size()),
        ),
        decoded.quantity(),
    );
    let floor = decoded.floor_shares();
    assert!(range_value > floor, 0);
    assert!(range_value <= math::div_down(floor, expiry_market.liquidation_ltv()), 1);

    // The knocked-out order is credited its full range value (zero live liability),
    // so NAV rises to the knock-out-aware reference — above the old floor-capped
    // mark. `check_nav` asserts `current_nav` equals that independent reference.
    check_nav(&fx, &market, vector[id]);
    check_single_order_nav_enclosure(&fx, &market, id);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun mixed_one_x_and_leveraged_book() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let up = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let down = fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        helpers::strike_tick(),
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    let leveraged = fx.mint_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        LEVERAGED_QUANTITY,
        LEVERAGE_TWO_X,
    );

    // strike now carries start quantity (1x up + leveraged up) and end quantity
    // (1x down); only the leveraged order is in the correction book.
    check_nav(&fx, &market, vector[up, down, leveraged]);

    helpers::return_account_bundle(account);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::ENonMonotonePriceMemo)]
fun current_nav_rejects_non_monotone_active_book_surface() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // First create a normal order with live boundaries at ticks 90 and 100. Then
    // replace the oracle surface with a synthetic bad surface where the higher
    // strike has a higher UP price than the lower strike. NAV should reject that
    // instead of using a price order that can overstate pool value.
    fx.mint_bundle(
        &mut market,
        &mut account,
        NON_MONOTONE_LOWER_TICK,
        NON_MONOTONE_HIGHER_TICK,
        ONE_X_QUANTITY,
        test_constants::leverage_one_x(),
    );
    // These SVI values are intentionally extreme: tiny positive `a`, max `b`,
    // min `sigma`, and `rho = -1`. Together they make the model report a higher
    // chance of finishing above tick 100 than above tick 90, which is impossible
    // for a valid UP price curve.
    fx.seed_bs_surface_with_svi_bundle(
        &mut market,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NON_MONOTONE_A_MAGNITUDE,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        float!(),
        true,
        0,
        false,
        test_constants::live_source_timestamp_ms() + 1,
    );

    fx.current_nav_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === Helpers ===

/// Assert `current_nav` equals the independent per-order reference and the market
/// stays solvent (S1 backing). The contract builds its own pricer internally; we
/// build an identical one (the oracle is frozen within the tx) for the reference.
///
/// Exact equality, not the module doc's `N + M` bound: every fixture here is
/// dust-free by construction, so any difference at all is a real defect.
fun check_nav(fx: &helpers::Fixture, market: &helpers::MarketBundle, order_ids: vector<u256>) {
    let pricer = fx.load_pricer_bundle(market);
    let nav = fx.current_nav_bundle(market);
    let expiry_market = helpers::market(market);
    assert_eq!(nav, reference_nav(expiry_market, &pricer, &order_ids));
    helpers::assert_market_backed(expiry_market);
}

/// Compose the certified range-price ball through one order's quantity, fixed
/// correction branch, liability clamp, and cash subtraction. Pricing correctness
/// is covered independently; this checks that the NAV layer encloses both outward
/// price endpoints without changing its scalar center.
fun check_single_order_nav_enclosure(
    fx: &helpers::Fixture,
    market: &helpers::MarketBundle,
    order_id: u256,
) {
    let pricer = fx.load_pricer_bundle(market);
    let expiry_market = helpers::market(market);
    let decoded = order::from_order_id(order_id);

    // Read the certified boundary price the way NAV itself does: price each finite
    // boundary into a memo in ascending order, then read the range back out of it.
    let tick_size = expiry_market.tick_size();
    let mut memo = pricing::new_price_memo();
    vector[decoded.lower_tick(), decoded.higher_tick()].do!(|tick| {
        if (tick != constants::neg_inf!() && tick != constants::pos_inf_tick!()) {
            memo.price_and_cache(&pricer, tick, tick_size);
        };
    });
    let price = memo.cached_range_price(decoded.lower_tick(), decoded.higher_tick());
    let price_low = price.magnitude().saturating_sub(price.error());
    let price_high = price.magnitude().saturating_add(price.error()).min(float!());

    let canonical_gross = math::mul_down(price.magnitude(), decoded.quantity());
    let knocked_out =
        decoded.floor_shares() > 0
            && canonical_gross
                <= math::div_down(decoded.floor_shares(), expiry_market.liquidation_ltv());
    let (liability_low, liability_high) = if (knocked_out) {
        (0, 0)
    } else {
        let gross_low = math::mul_down(price_low, decoded.quantity());
        let gross_high = math::mul_up(price_high, decoded.quantity());
        (
            gross_low.saturating_sub(decoded.floor_shares()),
            gross_high.saturating_sub(decoded.floor_shares()),
        )
    };

    let free_cash = expiry_market.cash_balance().saturating_sub(expiry_market.rebate_reserve());
    let nav_low = free_cash.saturating_sub(liability_high);
    let nav_high = free_cash.saturating_sub(liability_low);
    let approximate = expiry_market.current_nav_approx(&pricer);
    assert_eq!(approximate.magnitude(), expiry_market.current_nav(&pricer));
    assert_contains(&approximate, nav_low);
    assert_contains(&approximate, nav_high);
}

fun assert_contains(ball: &Approx, candidate: u64) {
    assert!(!ball.is_negative());
    assert!(ball.magnitude().diff(candidate) <= ball.error());
}

/// Independent NAV oracle (unit-tests rule 1): `free_cash - Σ contribution` per
/// open order, using only order atoms and `pricing::range_price`. A knocked-out
/// leveraged order (live gross at or below `floor / liquidation_ltv`) contributes
/// zero — it will be liquidated by the sweep and owes nothing above its reserved
/// floor, mirroring the flush's read-only correction (RP-17); every other order
/// contributes `max(0, qty·P - floor)`. The order's ticks are converted to raw
/// strikes through the same `range_codec` boundary the contract uses (the codec
/// is the pricing boundary, not the NAV math under test).
fun reference_nav(market: &ExpiryMarket, pricer: &Pricer, order_ids: &vector<u256>): u64 {
    let mut liability = 0;
    order_ids.do_ref!(|id| {
        let decoded = order::from_order_id(*id);
        let lower = range_codec::strike_from_tick(decoded.lower_tick(), market.tick_size());
        let higher = range_codec::strike_from_tick(decoded.higher_tick(), market.tick_size());
        let range_value = math::mul_down(pricer.range_price(lower, higher), decoded.quantity());
        // The economic threshold as stated: gross at or below `floor / ltv`. Kept in
        // this form (not the contract's `ceil(rv * ltv / S) <= F`) so the oracle stays
        // an independent expression, and evaluated in u128 because a large floor
        // overflows `math::div_down`'s u64 return.
        let knocked_out =
            decoded.floor_shares() > 0
                && (range_value as u128)
                <= (decoded.floor_shares() as u128) * (float!() as u128)
                    / (market.liquidation_ltv() as u128);
        let contribution = if (knocked_out) {
            0
        } else {
            range_value.saturating_sub(decoded.floor_shares())
        };
        liability = liability + contribution;
    });
    let free_cash = market.cash_balance().saturating_sub(market.rebate_reserve());
    free_cash.saturating_sub(liability)
}
