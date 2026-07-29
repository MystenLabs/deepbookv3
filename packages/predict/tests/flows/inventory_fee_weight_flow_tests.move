// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the inventory fee weight, driven through the production
/// mint and redeem entrypoints.
///
/// The load-bearing property is the separation: inventory moves the FEE and
/// never the mid, so `entry_probability` stays the oracle's fair mark through
/// every trade and a complementary pair of ranges still costs exactly its payout
/// before fees. The weight arithmetic itself is unit-tested in
/// `config/inventory_fee_weight_tests`.
#[test_only]
module deepbook_predict::inventory_fee_weight_flow_tests;

use deepbook_predict::{
    constants,
    expiry_market::MintQuote,
    flow_test_helpers as helpers,
    test_constants
};
use fixed_math::math::float_scaling as float;
use std::unit_test::assert_eq;

/// 30% maximum fee swing in either direction.
const SENSITIVITY_THIRTY_PERCENT: u64 = 300_000_000;
/// Fraction of the expiry's allocated capital at which the weight saturates.
/// Against the fixture's 250_000e6 allocation this is 2_000e6 base units, or
/// 200_000 lots — so one `MINT_QUANTITY` is exactly half the depth and swings
/// the fee by half its maximum, well clear of integer rounding.
const CAPITAL_FRACTION: u64 = 8_000_000;

/// 1e9 base units at the 10_000-unit lot size = 100_000 lots.
const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_LOTS: u64 = 100_000;
const HALF_MINT_QUANTITY: u64 = 500_000_000;
const HALF_MINT_LOTS: u64 = 50_000;

/// Finite mint boundaries must sit on the coarse admission grid, which is
/// `default_admission_tick_size / default_tick_size = 10` fine ticks apart.
const ADMISSION_TICK_MULTIPLE: u64 = 10;

/// The unweighted fee for `MINT_QUANTITY`. The fixture sets `base_fee` to 1, so
/// the Bernoulli term rounds to zero and the rate is pinned at the `min_fee`
/// floor of 5_000_000: `5_000_000 · 1e9 / 1e9` per unit over 1e9 units.
const UNWEIGHTED_FEE: u64 = 5_000_000;
/// `MINT_QUANTITY` is half the 200_000-lot depth, so a trade that lands the book
/// there carries loading 0.5 and weight `1 + 0.3·0.5` = 1.15.
const FEE_AT_HALF_DEPTH_DEEPENING: u64 = 5_750_000;
/// Loading 1.0 (book at full depth): `1 + 0.3·1.0` = 1.30.
const FEE_AT_FULL_DEPTH_DEEPENING: u64 = 6_500_000;
/// Loading 0.5 on the offsetting side: `1 - 0.3·0.5` = 0.85.
const FEE_AT_HALF_DEPTH_OFFSETTING: u64 = 4_250_000;

fun one_x(): u64 { test_constants::leverage_one_x() }

/// 2x, so the order carries a floor and can be knocked out at all.
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Spot far below the strike, so an UP binary is worthless and liquidatable.
const DROPPED_SPOT: u64 = 50_000_000_000;
/// Clock at liquidation, past the fixture's `now_ms` so the mint and the
/// knockout do not share a timestamp.
const LIQUIDATION_CLOCK_MS: u64 = 121_000;
/// Source timestamp of the dropped observation: before the clock reads it, and
/// inside the freshness window.
const DROP_SOURCE_TS: u64 = 120_500;

fun strike(): u64 { helpers::strike_tick() }

fun setup(): (helpers::Fixture, helpers::MarketBundle, helpers::AccountBundle) {
    let (mut fx, expiry_id, trader) = helpers::setup_everything_with_fee_weight(
        SENSITIVITY_THIRTY_PERCENT,
        CAPITAL_FRACTION,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let market = fx.take_market_bundle(expiry_id);
    let account = fx.take_account_bundle(&trader);
    (fx, market, account)
}

fun cleanup(fx: helpers::Fixture, market: helpers::MarketBundle, account: helpers::AccountBundle) {
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

/// Quote a `(K, +inf]` UP binary without touching the book.
fun quote_up(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): MintQuote {
    fx.quote_mint_bundle(market, strike(), constants::pos_inf_tick!(), quantity, one_x())
}

/// Quote the complementary `(-inf, K]` DOWN binary.
fun quote_down(
    fx: &mut helpers::Fixture,
    market: &helpers::MarketBundle,
    quantity: u64,
): MintQuote {
    fx.quote_mint_bundle(market, constants::neg_inf!(), strike(), quantity, one_x())
}

fun mint_up(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
    quantity: u64,
): u256 {
    fx.mint_bundle(market, account, strike(), constants::pos_inf_tick!(), quantity, one_x())
}

// === The mid is untouched ===

/// The headline property. However lopsided the book gets, the quoted
/// probability stays the oracle's fair mark — so NAV, the LP flush mark, and
/// mint admission all continue to read exactly what they read before, and only
/// the fee line moves.
#[test]
fun inventory_moves_the_fee_and_never_the_probability() {
    let (mut fx, mut market, mut account) = setup();

    // Even on an empty book this quote is already weighted: it is priced against
    // the position it would itself create, which is half the depth.
    let first = quote_up(&mut fx, &market, MINT_QUANTITY);
    let probability = first.entry_probability();
    assert_eq!(first.trading_fee(), FEE_AT_HALF_DEPTH_DEEPENING);

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);

    // The same order now lands the book at full depth: dearer fee, same mid.
    let second = quote_up(&mut fx, &market, MINT_QUANTITY);
    assert_eq!(second.entry_probability(), probability);
    assert_eq!(second.trading_fee(), FEE_AT_FULL_DEPTH_DEEPENING);

    cleanup(fx, market, account);
}

/// A complementary pair still costs exactly its payout in premium terms, at any
/// inventory state. The mid-shift design had to prove this; leaving the mid
/// alone makes it hold by construction.
#[test]
fun complementary_pair_prices_at_exactly_one_regardless_of_inventory() {
    let (mut fx, mut market, mut account) = setup();

    let up_flat = quote_up(&mut fx, &market, MINT_QUANTITY).entry_probability();
    let down_flat = quote_down(&mut fx, &market, MINT_QUANTITY).entry_probability();
    assert_eq!(up_flat + down_flat, float!());

    mint_up(&mut fx, &mut market, &mut account, 2 * MINT_QUANTITY);

    let up_skewed = quote_up(&mut fx, &market, MINT_QUANTITY).entry_probability();
    let down_skewed = quote_down(&mut fx, &market, MINT_QUANTITY).entry_probability();
    assert_eq!(up_skewed + down_skewed, float!());
    assert_eq!(up_skewed, up_flat);

    cleanup(fx, market, account);
}

// === The fee responds to direction ===

/// Flow that deepens the pool's lean pays a surcharge; flow that offsets it pays
/// a genuine discount — strictly below the unweighted fee, not merely below the
/// surcharged one.
///
/// The book is leaned by TWICE the quote size on purpose. At a single lean the
/// offsetting quote would drive the book to exactly flat, hit the zero-aggregate
/// early return, and come back unweighted — which would still satisfy
/// `offsetting < deepening` while never exercising the discount branch at all.
#[test]
fun offsetting_flow_is_discounted_below_the_unweighted_fee() {
    let (mut fx, mut market, mut account) = setup();

    mint_up(&mut fx, &mut market, &mut account, 2 * MINT_QUANTITY);

    // Lands the book at full depth in the direction it already leans.
    let deepening = quote_up(&mut fx, &market, MINT_QUANTITY).trading_fee();
    assert_eq!(deepening, FEE_AT_FULL_DEPTH_DEEPENING);

    // Pulls the book back to half depth: still leaning, so still weighted.
    let offsetting = quote_down(&mut fx, &market, MINT_QUANTITY).trading_fee();
    assert_eq!(offsetting, FEE_AT_HALF_DEPTH_OFFSETTING);
    assert!(offsetting < UNWEIGHTED_FEE);

    cleanup(fx, market, account);
}

/// A trade that exactly flattens the book is unweighted — the boundary the test
/// above deliberately steps around.
#[test]
fun trade_that_flattens_the_book_is_unweighted() {
    let (mut fx, mut market, mut account) = setup();

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    let flattening = quote_down(&mut fx, &market, MINT_QUANTITY).trading_fee();
    assert_eq!(flattening, UNWEIGHTED_FEE);

    cleanup(fx, market, account);
}

/// A trade whose delta exceeds the pool's current lean overshoots into the
/// opposite exposure, and is surcharged for the position it creates rather than
/// rewarded for the one it cleared. This is the sharp end of pricing post-trade.
#[test]
fun overshooting_trade_pays_for_the_exposure_it_creates() {
    let (mut fx, mut market, mut account) = setup();

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);

    // Pool is short 100_000 lots; a 300_000-lot DOWN binary lands it long
    // 200_000 — past the depth, so the weight saturates at the surcharge.
    let overshoot = quote_down(&mut fx, &market, 3 * MINT_QUANTITY).trading_fee();
    assert_eq!(overshoot, 3 * FEE_AT_FULL_DEPTH_DEEPENING);

    cleanup(fx, market, account);
}

/// A two-sided range takes no directional position, so its fee is the
/// unweighted one even on a lopsided book.
#[test]
fun two_sided_range_pays_the_unweighted_fee() {
    let (mut fx, mut market, mut account) = setup();

    let lower = strike() - ADMISSION_TICK_MULTIPLE;
    let flat_book_fee = fx
        .quote_mint_bundle(&market, lower, strike(), MINT_QUANTITY, one_x())
        .trading_fee();

    mint_up(&mut fx, &mut market, &mut account, 2 * MINT_QUANTITY);

    let lopsided_book_fee = fx
        .quote_mint_bundle(&market, lower, strike(), MINT_QUANTITY, one_x())
        .trading_fee();
    assert_eq!(lopsided_book_fee, flat_book_fee);
    assert_eq!(lopsided_book_fee, UNWEIGHTED_FEE);

    cleanup(fx, market, account);
}

/// The weight reads the position a trade LEAVES BEHIND, so it cannot be dodged
/// by sequencing: buying 2x at once and buying 1x after another 1x already
/// landed both end on the same book and pay the same weighted fee.
#[test]
fun fee_depends_only_on_the_resulting_position() {
    let (mut fx, mut market, mut account) = setup();

    let double_on_flat_book = quote_up(&mut fx, &market, 2 * MINT_QUANTITY).trading_fee();

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    let single_after_the_first = quote_up(&mut fx, &market, MINT_QUANTITY).trading_fee();

    // Twice the quantity carries twice the unweighted fee, so compare per-unit:
    // the 2x order's fee at 2x quantity against the 1x order's at 1x quantity.
    assert_eq!(double_on_flat_book / 2, single_after_the_first);

    cleanup(fx, market, account);
}

/// The close path is weighted too, and its direction depends on the book the
/// close lands on — not on the fact that it is a close.
///
/// Both closes below are the same order, the same size, at the same mid (the
/// weight never moves the mid) and the same fee ramp, so the unweighted fee is
/// identical and the ONLY difference is the pool's directional position. The
/// first lands while the pool is still short UP, so releasing an UP position
/// offsets the lean and is discounted. Between them the book is flipped long UP,
/// so the second release now deepens the lean and is surcharged.
///
/// Driven through the real redeem entrypoint and measured on fees actually
/// debited from the account, so this pins the `close_trading_fee` payment path
/// rather than a quote.
#[test]
fun close_is_discounted_offsetting_and_surcharged_when_it_deepens() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything_with_fee_weight(
        SENSITIVITY_THIRTY_PERCENT,
        CAPITAL_FRACTION,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    let after_mint = helpers::fees_paid_bundle(&account, expiry_id);

    // A position cannot be minted and closed in the same millisecond.
    fx.set_clock_for_testing(test_constants::now_ms() + 1);

    // Pool is short UP; releasing an UP position offsets that lean.
    let (_, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        HALF_MINT_QUANTITY,
    );
    let offsetting_close_fee = helpers::fees_paid_bundle(&account, expiry_id) - after_mint;
    let after_first_close = helpers::market(&market).directional_aggregate();
    assert!(after_first_close.is_negative());
    assert_eq!(after_first_close.magnitude(), HALF_MINT_LOTS);

    // Flip the book long UP, so releasing the rest now deepens the lean instead.
    fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        strike(),
        2 * MINT_QUANTITY,
        one_x(),
    );
    let before_second_close = helpers::fees_paid_bundle(&account, expiry_id);
    let after_flip = helpers::market(&market).directional_aggregate();
    assert!(!after_flip.is_negative());
    assert_eq!(after_flip.magnitude(), 3 * HALF_MINT_LOTS);

    fx.redeem_bundle(&mut market, &mut account, replacement.destroy_some(), HALF_MINT_QUANTITY);
    let deepening_close_fee = helpers::fees_paid_bundle(&account, expiry_id) - before_second_close;

    assert!(deepening_close_fee > offsetting_close_fee);

    cleanup(fx, market, account);
}

// === Aggregate accounting ===

/// The aggregate moves by exactly the traded lots and returns to exactly zero on
/// a full round trip — including across two partial closes, which exercise the
/// survivor reinsertion path rather than one symmetric removal. Exact, not
/// approximate: the aggregate reads only atoms that round-trip through the
/// packed order id, so no oracle movement between open and close leaves a
/// residual.
#[test]
fun aggregate_tracks_traded_lots_and_returns_to_zero() {
    let (mut fx, mut market, mut account) = setup();

    assert!(helpers::market(&market).directional_aggregate().is_zero());

    let order_id = mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    let after_mint = helpers::market(&market).directional_aggregate();
    assert!(after_mint.is_negative());
    assert_eq!(after_mint.magnitude(), MINT_LOTS);

    // A position cannot be minted and closed in the same millisecond.
    fx.set_clock_for_testing(test_constants::now_ms() + 1);
    let (_, replacement) = fx.redeem_bundle(
        &mut market,
        &mut account,
        order_id,
        HALF_MINT_QUANTITY,
    );
    let mid_close = helpers::market(&market).directional_aggregate();
    assert!(mid_close.is_negative());
    assert_eq!(mid_close.magnitude(), HALF_MINT_LOTS);

    fx.redeem_bundle(&mut market, &mut account, replacement.destroy_some(), HALF_MINT_QUANTITY);
    assert!(helpers::market(&market).directional_aggregate().is_zero());

    cleanup(fx, market, account);
}

/// Buying the DOWN leg moves the aggregate the other way.
#[test]
fun down_binary_moves_the_aggregate_the_other_way() {
    let (mut fx, mut market, mut account) = setup();

    fx.mint_bundle(
        &mut market,
        &mut account,
        constants::neg_inf!(),
        strike(),
        MINT_QUANTITY,
        one_x(),
    );

    let aggregate = helpers::market(&market).directional_aggregate();
    assert!(!aggregate.is_negative());
    assert_eq!(aggregate.magnitude(), MINT_LOTS);

    cleanup(fx, market, account);
}

// === Every mutation site releases ===

/// Liquidation releases the knocked-out order's directional weight, and the
/// later redeem of that already-liquidated order must NOT release it a second
/// time. Nothing else pins that asymmetry: `apply_liquidation` releases, while
/// the `Liquidated` close arm only clears the holder's position — a future edit
/// adding a release there would double-subtract and flip the aggregate's sign,
/// mis-weighting every subsequent fee on the expiry.
#[test]
fun liquidation_releases_once_and_the_liquidated_redeem_does_not_release_again() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything_with_fee_weight(
        SENSITIVITY_THIRTY_PERCENT,
        CAPITAL_FRACTION,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    // Leveraged, so the order is liquidatable at all (a 1x order has no floor).
    let order_id = fx.mint_bundle(
        &mut market,
        &mut account,
        strike(),
        constants::pos_inf_tick!(),
        MINT_QUANTITY,
        LEVERAGE_TWO_X,
    );
    assert_eq!(helpers::market(&market).directional_aggregate().magnitude(), MINT_LOTS);

    // Drop the forward far below the strike so the UP binary knocks out.
    fx.set_clock_for_testing(LIQUIDATION_CLOCK_MS);
    fx.set_pyth_price_for_testing_bundle(&mut market, DROPPED_SPOT, DROP_SOURCE_TS);
    assert!(fx.liquidate_order_bundle(&mut market, order_id));
    assert!(helpers::market(&market).directional_aggregate().is_zero());

    // Redeeming the already-liquidated order pays zero and must leave the
    // aggregate exactly where liquidation left it.
    fx.redeem_bundle(&mut market, &mut account, order_id, MINT_QUANTITY);
    assert!(helpers::market(&market).directional_aggregate().is_zero());

    cleanup(fx, market, account);
}

/// A settled redeem releases too, so the aggregate reads as the net live
/// one-sided position in every phase rather than stranding a phantom position
/// on the public getter after expiry.
#[test]
fun settled_redeem_releases_the_aggregate() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything_with_fee_weight(
        SENSITIVITY_THIRTY_PERCENT,
        CAPITAL_FRACTION,
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let order_id = mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    assert_eq!(helpers::market(&market).directional_aggregate().magnitude(), MINT_LOTS);

    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    fx.insert_exact_settlement_spot_bundle(&mut market, test_constants::default_live_price());
    assert!(fx.try_settle_bundle(&mut market));

    fx.redeem_settled_bundle(&mut market, &mut account, order_id, MINT_QUANTITY);
    assert!(helpers::market(&market).directional_aggregate().is_zero());

    cleanup(fx, market, account);
}

// === Disabled by default ===

/// With the weight off — the shipped default — the fee is the unweighted one at
/// every inventory state, while the aggregate is still maintained. Enabling a
/// future expiry therefore needs no migration.
#[test]
fun disabled_weight_leaves_every_fee_unweighted() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let flat_fee = quote_up(&mut fx, &market, MINT_QUANTITY).trading_fee();

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    assert_eq!(helpers::market(&market).directional_aggregate().magnitude(), MINT_LOTS);
    assert_eq!(quote_up(&mut fx, &market, MINT_QUANTITY).trading_fee(), flat_fee);

    cleanup(fx, market, account);
}
