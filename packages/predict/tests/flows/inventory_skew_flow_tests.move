// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the inventory skew: the properties that make it safe to
/// quote off the oracle's fair mark, driven through the production mint and
/// redeem entrypoints.
///
/// Covered here: the aggregate's exact round trip (the drift property that sank
/// the first build of this mechanism), post-trade and path-independent pricing,
/// the no-free-money bound on a complete partition, and directional flatness of
/// two-sided ranges. The shift arithmetic itself is unit-tested in
/// `config/inventory_skew_tests`.
#[test_only]
module deepbook_predict::inventory_skew_flow_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, test_constants};
use fixed_math::math::float_scaling as float;
use std::unit_test::assert_eq;

/// 2% shift at full depth.
const MAX_SHIFT_TWO_PERCENT: u64 = 20_000_000;
/// Depth in lots. `MINT_QUANTITY` is a tenth of it, so a single test mint moves
/// the skew by a tenth of its maximum — well clear of integer rounding.
const DEPTH_LOTS: u64 = 1_000_000;

/// 1e9 base units at the 10_000-unit lot size = 100_000 lots. Above the
/// `min_net_premium` floor at the ~0.5 probability these ranges price at.
const MINT_QUANTITY: u64 = 1_000_000_000;
const MINT_LOTS: u64 = 100_000;
const HALF_MINT_QUANTITY: u64 = 500_000_000;
const HALF_MINT_LOTS: u64 = 50_000;

/// Finite mint boundaries must sit on the coarse admission grid, which is
/// `default_admission_tick_size / default_tick_size = 10` fine ticks apart.
const ADMISSION_TICK_MULTIPLE: u64 = 10;

fun one_x(): u64 { test_constants::leverage_one_x() }

/// The default strike, at roughly the money for the default live price.
fun strike(): u64 { helpers::strike_tick() }

/// Stand up a live market with the skew snapshotted in, ready for the trader to
/// transact against.
fun setup(): (helpers::Fixture, helpers::MarketBundle, helpers::AccountBundle) {
    let (mut fx, expiry_id, trader) = helpers::setup_everything_with_skew(
        MAX_SHIFT_TWO_PERCENT,
        DEPTH_LOTS,
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

/// Quote a `(K, +inf]` UP binary of `quantity` without touching the book.
fun quote_up(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): u64 {
    fx
        .quote_mint_bundle(market, strike(), constants::pos_inf_tick!(), quantity, one_x())
        .entry_probability()
}

/// Quote the complementary `(-inf, K]` DOWN binary of `quantity`.
fun quote_down(fx: &mut helpers::Fixture, market: &helpers::MarketBundle, quantity: u64): u64 {
    fx
        .quote_mint_bundle(market, constants::neg_inf!(), strike(), quantity, one_x())
        .entry_probability()
}

fun mint_up(
    fx: &mut helpers::Fixture,
    market: &mut helpers::MarketBundle,
    account: &mut helpers::AccountBundle,
    quantity: u64,
): u256 {
    fx.mint_bundle(market, account, strike(), constants::pos_inf_tick!(), quantity, one_x())
}

/// Buying `(K, +inf]` makes the pool net SHORT UP: the aggregate goes negative
/// by exactly the traded lots, and returns to exactly zero when the position
/// closes — including across two partial closes, which exercise the survivor
/// reinsertion path rather than one symmetric removal.
#[test]
fun up_binary_mint_moves_aggregate_by_its_lots_and_close_returns_it_to_zero() {
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
    // Exactly zero, not approximately: the aggregate reads only atoms that
    // round-trip through the packed order id, so no oracle-surface movement
    // between open and close can leave a residual behind.
    assert!(helpers::market(&market).directional_aggregate().is_zero());

    cleanup(fx, market, account);
}

/// The mirror: buying `(-inf, K]` makes the pool net LONG UP.
#[test]
fun down_binary_mint_moves_the_aggregate_the_other_way() {
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

/// A two-sided range carries no net directional exposure — the pool is short one
/// boundary and long the other — so it leaves the aggregate untouched.
#[test]
fun two_sided_range_is_directionally_flat() {
    let (mut fx, mut market, mut account) = setup();

    fx.mint_bundle(
        &mut market,
        &mut account,
        strike() - ADMISSION_TICK_MULTIPLE,
        strike(),
        MINT_QUANTITY,
        one_x(),
    );

    assert!(helpers::market(&market).directional_aggregate().is_zero());

    cleanup(fx, market, account);
}

/// A trade is quoted against the inventory it is about to create, so a bigger
/// order prices worse than a smaller one on the same book, and the same size
/// prices worse once the book is already leaning that way.
///
/// The equality is the sharp part: a quote depends only on the inventory the
/// trade leaves behind, never on the path taken to it. Buying 2x at once and
/// buying 1x after another 1x already landed both quote against the same
/// aggregate, so they quote identically — which is what makes the skew
/// independent of how a trader sequences their orders.
#[test]
fun quotes_worsen_with_size_and_depend_only_on_resulting_inventory() {
    let (mut fx, mut market, mut account) = setup();

    let single_on_flat_book = quote_up(&mut fx, &market, MINT_QUANTITY);
    let double_on_flat_book = quote_up(&mut fx, &market, 2 * MINT_QUANTITY);
    assert!(double_on_flat_book > single_on_flat_book);

    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    let single_after_the_first = quote_up(&mut fx, &market, MINT_QUANTITY);
    assert!(single_after_the_first > single_on_flat_book);
    assert_eq!(double_on_flat_book, single_after_the_first);

    cleanup(fx, market, account);
}

/// Buying a complete partition of the line — `(-inf, K]` plus `(K, +inf]` —
/// pays out exactly 1 per unit whatever settles, so it must never cost less
/// than 1. Under the skew each leg is quoted against its own impact, which
/// pushes both legs UP, so the pair costs strictly more than its payout. There
/// is no inventory state that turns the pair into free money: the leg that would
/// be discounted is exactly the leg whose own impact moves it back toward fair.
#[test]
fun complete_partition_never_costs_less_than_its_payout() {
    let (mut fx, mut market, mut account) = setup();

    let up_leg = quote_up(&mut fx, &market, MINT_QUANTITY);
    let down_leg = quote_down(&mut fx, &market, MINT_QUANTITY);
    assert!(up_leg + down_leg > float!());

    // Now lean the book hard one way and re-check.
    mint_up(&mut fx, &mut market, &mut account, 2 * MINT_QUANTITY);
    let skewed_up_leg = quote_up(&mut fx, &market, MINT_QUANTITY);
    let skewed_down_leg = quote_down(&mut fx, &market, MINT_QUANTITY);
    assert!(skewed_up_leg + skewed_down_leg > float!());

    cleanup(fx, market, account);
}

/// With the skew off — the shipped default — every quote is the fair mark, so
/// the partition sums to exactly its payout and the aggregate never moves.
#[test]
fun disabled_skew_quotes_the_fair_mark_and_the_partition_sums_to_one() {
    let (mut fx, expiry_id, trader) = helpers::setup_everything();
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);

    let up_leg = quote_up(&mut fx, &market, MINT_QUANTITY);
    let down_leg = quote_down(&mut fx, &market, MINT_QUANTITY);
    assert_eq!(up_leg + down_leg, float!());

    // The aggregate is still maintained while the skew is off; it simply has no
    // effect on price, so re-enabling on a future expiry needs no migration.
    mint_up(&mut fx, &mut market, &mut account, MINT_QUANTITY);
    assert_eq!(helpers::market(&market).directional_aggregate().magnitude(), MINT_LOTS);
    assert_eq!(quote_up(&mut fx, &market, MINT_QUANTITY), up_leg);

    cleanup(fx, market, account);
}
