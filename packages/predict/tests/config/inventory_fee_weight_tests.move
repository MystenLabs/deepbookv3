// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_exposure_config::inventory_fee_weight` and the
/// capital-derived depth that normalizes it.
///
/// Every expected value is derived from the mechanism's specification rather
/// than the implementation's expression: the weight is
/// `1 ± sensitivity · min(1, |post_trade_aggregate| / depth_lots)`, raised when
/// the trade deepens the pool's existing directional lean and lowered when it
/// offsets one. Each constant below shows that arithmetic worked out by hand.
#[test_only]
module deepbook_predict::inventory_fee_weight_tests;

use deepbook_predict::{config_constants, strike_exposure_config};
use fixed_math::i64;
use std::unit_test::{assert_eq, destroy};

/// The unweighted fee: weight 1.0 in FLOAT_SCALING.
const UNWEIGHTED: u64 = 1_000_000_000;
/// 30% — the most this sensitivity may move a fee in either direction.
const SENSITIVITY_THIRTY_PERCENT: u64 = 300_000_000;
/// Capital that yields a 1,000,000-lot depth at `HALF_OF_CAPITAL`:
/// 50% of 20_000e6 base units is 10_000e6, over the 10_000-unit lot size.
const CAPITAL_FOR_DEPTH: u64 = 20_000_000_000;
/// The depth `CAPITAL_FOR_DEPTH` produces, in lots.
const DEPTH_LOTS: u64 = 1_000_000;
const HALF_DEPTH_LOTS: u64 = 500_000;
/// Ten times the depth, to exercise the saturation clamp on the loading.
const TEN_TIMES_DEPTH_LOTS: u64 = 10_000_000;

/// 1 + 0.30 · 1.0 = 1.30. Trade deepens a fully-loaded lean.
const FULL_DEEPENING: u64 = 1_300_000_000;
/// 1 - 0.30 · 1.0 = 0.70. Trade offsets a fully-loaded lean.
const FULL_OFFSETTING: u64 = 700_000_000;
/// 1 + 0.30 · 0.5 = 1.15. Half-loaded book.
const HALF_DEEPENING: u64 = 1_150_000_000;
/// 1 - 0.30 · 0.5 = 0.85.
const HALF_OFFSETTING: u64 = 850_000_000;

/// 50%, in FLOAT_SCALING: the shipped default share of an expiry's capital.
const HALF_OF_CAPITAL: u64 = 500_000_000;
/// The test-fixture per-expiry allocation, in DUSDC base units.
const EXPIRY_ALLOCATION: u64 = 250_000_000_000;
/// 50% of 250_000e6 = 125_000e6 base units, over the 10_000-unit lot size.
const HALF_ALLOCATION_DEPTH_LOTS: u64 = 12_500_000;
/// An allocation whose half is under one lot (10_000 base units).
const DUST_ALLOCATION: u64 = 10_000;
/// `1 - 0.5`, the weight at the hard sensitivity ceiling on the offsetting side.
const HALF_WEIGHT: u64 = 500_000_000;

/// Capital yielding a 3-lot depth: 50% of 60_000 is 30_000, over the 10_000-unit
/// lot size. Chosen so `|aggregate| / depth` does not divide evenly.
const CAPITAL_FOR_THREE_LOT_DEPTH: u64 = 60_000;
/// 1 lot against a 3-lot depth: loading truncates to 0.333_333_333, and
/// `0.3 · 0.333_333_333` truncates again to 0.099_999_999, so the weight is
/// 1.099_999_999 — both truncations round toward the trader on a surcharge.
const WEIGHT_AT_ONE_THIRD_LOADING: u64 = 1_099_999_999;

/// Capital yielding a 1-lot depth: 50% of 20_000 is 10_000, exactly one lot.
const CAPITAL_FOR_ONE_LOT_DEPTH: u64 = 20_000;

/// A config with the weight enabled at 30%.
fun weighted_config(): strike_exposure_config::StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_inventory_fee_sensitivity(SENSITIVITY_THIRTY_PERCENT);
    config.set_inventory_capital_fraction(HALF_OF_CAPITAL);
    config
}

/// The pool is net SHORT UP by `lots` (traders are long UP): aggregate negative.
fun short_up(lots: u64): i64::I64 {
    i64::from_parts(lots, true)
}

/// The pool is net LONG UP by `lots`: aggregate positive.
fun long_up(lots: u64): i64::I64 {
    i64::from_u64(lots)
}

// === Direction ===

/// A trade that leaves the pool deeper in the direction it was already leaning
/// pays more. Both the trade and the resulting position are short UP.
#[test]
fun trade_deepening_the_lean_raises_the_fee() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(
            &short_up(DEPTH_LOTS),
            &short_up(DEPTH_LOTS),
            CAPITAL_FOR_DEPTH,
        ),
        FULL_DEEPENING,
    );
    destroy(config);
}

/// The mirror: a trade whose own direction opposes the resulting position is
/// rebalancing flow and pays less.
#[test]
fun trade_offsetting_the_lean_lowers_the_fee() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(&short_up(DEPTH_LOTS), &long_up(DEPTH_LOTS), CAPITAL_FOR_DEPTH),
        FULL_OFFSETTING,
    );
    destroy(config);
}

/// Sign-symmetric: a pool leaning long UP treats a long-UP trade as deepening.
#[test]
fun direction_is_symmetric_in_the_sign_of_the_position() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(&long_up(DEPTH_LOTS), &long_up(DEPTH_LOTS), CAPITAL_FOR_DEPTH),
        FULL_DEEPENING,
    );
    assert_eq!(
        config.inventory_fee_weight(&long_up(DEPTH_LOTS), &short_up(DEPTH_LOTS), CAPITAL_FOR_DEPTH),
        FULL_OFFSETTING,
    );
    destroy(config);
}

// === Magnitude ===

/// The swing is linear in how loaded the book is, up to the depth.
#[test]
fun half_loaded_book_swings_half_as_far() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(&short_up(HALF_DEPTH_LOTS), &short_up(1), CAPITAL_FOR_DEPTH),
        HALF_DEEPENING,
    );
    assert_eq!(
        config.inventory_fee_weight(&short_up(HALF_DEPTH_LOTS), &long_up(1), CAPITAL_FOR_DEPTH),
        HALF_OFFSETTING,
    );
    destroy(config);
}

/// Position past the depth saturates: the weight never exceeds `1 ± sensitivity`,
/// which is what bounds the fee no matter how lopsided the book gets.
#[test]
fun position_beyond_depth_saturates_at_the_configured_sensitivity() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(
            &short_up(TEN_TIMES_DEPTH_LOTS),
            &short_up(DEPTH_LOTS),
            CAPITAL_FOR_DEPTH,
        ),
        FULL_DEEPENING,
    );
    destroy(config);
}

// === Weight is exactly 1 ===

/// A trade that leaves the book exactly flat is neutral, whichever way it came.
#[test]
fun trade_landing_on_a_flat_book_is_unweighted() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(&i64::zero(), &long_up(DEPTH_LOTS), CAPITAL_FOR_DEPTH),
        UNWEIGHTED,
    );
    destroy(config);
}

/// A two-sided range is directionally flat — the pool is short one boundary and
/// long the other — so it never moves the fee, even on a lopsided book.
#[test]
fun directionally_neutral_trade_is_unweighted() {
    let config = weighted_config();
    assert_eq!(
        config.inventory_fee_weight(&short_up(DEPTH_LOTS), &i64::zero(), CAPITAL_FOR_DEPTH),
        UNWEIGHTED,
    );
    destroy(config);
}

/// The shipped default: every trade pays exactly today's fee until an admin
/// snapshots a sensitivity into a new expiry.
#[test]
fun default_config_leaves_every_fee_unweighted() {
    let config = strike_exposure_config::new();
    assert_eq!(config.inventory_fee_sensitivity(), 0);
    assert_eq!(
        config.inventory_fee_weight(
            &short_up(DEPTH_LOTS),
            &short_up(DEPTH_LOTS),
            CAPITAL_FOR_DEPTH,
        ),
        UNWEIGHTED,
    );
    destroy(config);
}

/// At the ceiling of the sensitivity envelope a fully-offsetting trade still
/// pays a strictly positive fee. This is the property that keeps the weight from
/// ever owing the trader a rebate, which would make a round trip through the
/// vault profitable.
#[test]
fun ceiling_sensitivity_still_charges_a_positive_fee() {
    let mut config = strike_exposure_config::new();
    config.set_inventory_fee_sensitivity(config_constants::max_inventory_fee_sensitivity!());
    config.set_inventory_capital_fraction(HALF_OF_CAPITAL);
    let weight = config.inventory_fee_weight(
        &short_up(DEPTH_LOTS),
        &long_up(DEPTH_LOTS),
        CAPITAL_FOR_DEPTH,
    );
    // 1 - 0.5 = 0.5 exactly, at the hard ceiling: still strictly positive, so
    // the vault is never in the position of owing the trader a rebate.
    assert_eq!(weight, HALF_WEIGHT);
    destroy(config);
}

// === Capital-derived depth ===

/// The depth is a fraction of the expiry's own allocated capital, converted to
/// lots: 50% of 250_000e6 base units is 125_000e6, or 12.5M lots at the
/// 10_000-unit lot size.
#[test]
fun depth_is_a_fraction_of_the_expiry_allocation() {
    let config = weighted_config();
    assert_eq!(config.inventory_depth_lots(EXPIRY_ALLOCATION), HALF_ALLOCATION_DEPTH_LOTS);
    destroy(config);
}

/// Twice the capital absorbs twice the position before the fee moves by the same
/// amount — the property that makes the weight self-scaling, and the reason the
/// depth is derived rather than hand-set per market.
#[test]
fun depth_scales_linearly_with_allocated_capital() {
    let config = weighted_config();
    assert_eq!(config.inventory_depth_lots(2 * EXPIRY_ALLOCATION), 2 * HALF_ALLOCATION_DEPTH_LOTS);
    destroy(config);
}

/// An expiry whose share of the fraction is under one lot yields depth zero. The
/// weight must saturate rather than divide by zero: a trade on an under-funded
/// expiry still has to price, and an abort here would brick its trade path.
#[test]
fun sub_lot_depth_saturates_instead_of_aborting() {
    let config = weighted_config();
    assert_eq!(config.inventory_depth_lots(DUST_ALLOCATION), 0);
    assert_eq!(config.inventory_fee_weight(&short_up(1), &short_up(1), 0), FULL_DEEPENING);
    destroy(config);
}

// === Rounding and overflow ===

/// Both fixed-point truncations are visible only at a ratio that does not divide
/// evenly. Every other test here uses loadings of 1.0 or 0.5, where they hide.
#[test]
fun weight_truncates_at_a_non_round_loading() {
    let config = weighted_config();
    assert_eq!(config.inventory_depth_lots(CAPITAL_FOR_THREE_LOT_DEPTH), 3);
    assert_eq!(
        config.inventory_fee_weight(&short_up(1), &short_up(1), CAPITAL_FOR_THREE_LOT_DEPTH),
        WEIGHT_AT_ONE_THIRD_LOADING,
    );
    destroy(config);
}

/// The other half of the checked-arithmetic arm: a position whose ratio to the
/// depth overflows `u64` saturates at full strength instead of aborting. The
/// zero-depth half is covered by `sub_lot_depth_saturates_instead_of_aborting`.
#[test]
fun ratio_too_large_for_u64_saturates_instead_of_aborting() {
    let config = weighted_config();
    assert_eq!(config.inventory_depth_lots(CAPITAL_FOR_ONE_LOT_DEPTH), 1);
    assert_eq!(
        config.inventory_fee_weight(
            &short_up(std::u64::max_value!()),
            &short_up(1),
            CAPITAL_FOR_ONE_LOT_DEPTH,
        ),
        FULL_DEEPENING,
    );
    destroy(config);
}

/// The smallest legal capital fraction drives the depth to zero against a
/// realistic allocation, so every trade saturates at full sensitivity. That is
/// the boundary an operator can actually reach by misconfiguration, and it must
/// still price rather than abort.
#[test]
fun minimum_capital_fraction_saturates_every_trade() {
    let mut config = strike_exposure_config::new();
    config.set_inventory_fee_sensitivity(SENSITIVITY_THIRTY_PERCENT);
    config.set_inventory_capital_fraction(config_constants::min_inventory_capital_fraction!());
    assert_eq!(config.inventory_depth_lots(EXPIRY_ALLOCATION), 0);
    assert_eq!(
        config.inventory_fee_weight(&short_up(1), &short_up(1), EXPIRY_ALLOCATION),
        FULL_DEEPENING,
    );
    destroy(config);
}

// === Config envelope ===

#[test, expected_failure(abort_code = config_constants::EInvalidInventoryFeeSensitivity)]
fun sensitivity_above_ceiling_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_inventory_fee_sensitivity(config_constants::max_inventory_fee_sensitivity!() + 1);
    abort 1337
}

#[test, expected_failure(abort_code = config_constants::EInvalidInventoryCapitalFraction)]
fun zero_capital_fraction_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_inventory_capital_fraction(0);
    abort 1337
}

#[test, expected_failure(abort_code = config_constants::EInvalidInventoryCapitalFraction)]
fun capital_fraction_above_one_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_inventory_capital_fraction(config_constants::max_inventory_capital_fraction!() + 1);
    abort 1337
}
