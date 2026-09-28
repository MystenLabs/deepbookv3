// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Guard coverage for `pricing.move`'s live quote path.
///
/// Two abort surfaces are exercised through the production-valid `oracle_fixture`
/// bring-up:
///   - `EInvalidRange`: a degenerate range (`lower == higher`) after freshness
///     passes;
///   - `EBlockScholesPriceStale`: a hard staleness abort when one of the split
///     Block Scholes price feeds is past its configured freshness window.
/// The old deep-ITM/deep-OTM aborts (`EInvalidStrikeRatio`) are gone, and so is the
/// ratio short-circuit that replaced them: log-moneyness is now a difference of
/// logarithms, so both tails are COMPUTED and their limits are reached through
/// `d2`'s normal-CDF clamp rather than asserted by a branch. They stay pinned here
/// as exact-value tests (deep-ITM up tail -> 1.0, deep-OTM up tail -> 0) on an
/// ordinary surface, alongside the high-variance case where the deep-ITM tail is 0
/// instead — the pair that shows the tail follows the surface. A stale Pyth spot no
/// longer aborts either — it falls back to the stored Block Scholes forward; that
/// fallback is pinned with exact values in
/// `pricing_tests::live_forward_switches_source_exactly_at_pyth_staleness_boundary`,
/// so it is not duplicated here.
///
/// The `assert_inputs_pricing_safe` envelope rejects (`EBlockScholesInputsInvalid`)
/// is covered here too: one test per reachable branch seeds a surface that violates
/// exactly that bound (`forward` ceiling, `basis`, `b`, `rho`, `m`, `sigma` below
/// its 1e-5 floor, at zero, and above its ceiling), leaving every other input
/// default so only the targeted branch fires. `a` has no envelope bound: it is
/// pinned at the provider-width limit in both signs and past the former
/// `|a| <= 100` cap on both sides of the minimum-variance boundary. The smile root
/// is pinned at the envelope corners that give it its largest input.
/// The `spot == 0` / `forward == 0` branch of that assert is unreachable through
/// `load_live_pricer`: the split Block Scholes feed reads drop a zero spot or zero
/// forward upstream, so the read arrives as `none` and pricing aborts on absence
/// (-> `EBlockScholesPriceUnavailable`) before any staleness check runs. Those two
/// conditions are defensive-only and not tested here. `EBlockScholesMinVarianceInvalid`
/// covers surfaces whose analytical minimum total variance is non-positive,
/// including negative `a` values that over-offset the SVI increment and the
/// degenerate `a == 0, b == 0` surface. `EZeroForward` is reached via a pyth spot
/// far below the BS spot (no LOWER basis bound), where the re-anchored
/// `spot * bs_forward / bs_spot` floors to 0. `ENonPositiveVariance` is pinned by
/// a boundary surface whose rounded analytical minimum is positive at load but
/// whose concrete at-forward quote rounds total variance non-positive, and by a
/// production-valid unchanged tuple whose remaining-time roll-down reaches zero
/// one millisecond before expiry.
/// `ECannotBeNegative` inside `compute_nd2` is a defensive backstop: the floored
/// smile root is never below `|k - m|` and the floored `rho * (k - m)` never
/// exceeds it, so no input reaches it.
/// Active-book non-monotone UP prices are guarded by
/// `strike_payout_tree::ENonMonotonePrice` and covered in
/// `current_nav_flow_tests`.
#[test_only]
module deepbook_predict::pricing_guard_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing,
    pricing_reference_data as ref_data,
    pricing_ssvi_reference_data as ssvi,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers
};
use fixed_math::{i64, math::float_scaling as float};
use propbook::block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore};
use std::unit_test::assert_eq;

const EUnexpectedSuccess: u64 = 999;
const FOREIGN_UNDERLYING_ID: u32 = 2;
/// The largest provider-native magnitude that Predict can represent without narrowing loss.
const MAX_REPRESENTABLE_U64: u128 = 18_446_744_073_709_551_615;
/// The first provider-native magnitude that cannot be represented by Predict's u64 pricing domain.
const FIRST_UNREPRESENTABLE_U64: u128 = 18_446_744_073_709_551_616;

/// A strike far below the forward. On an ordinary low-variance surface the digital
/// reaches its neg_inf limit here through `d2`'s normal-CDF clamp; on a
/// high-variance surface it does not, which is what
/// `deep_itm_up_price_follows_the_surface_not_the_strike_ratio` pins. Both tests
/// use the default forward (100e9), where `k = ln(1e-9) - ln(100) = -25.33`.
const DEEP_ITM_STRIKE: u64 = 1;

/// A finite (non-`pos_inf`) strike far above a tiny forward. The up tail is 0 for
/// every admissible surface here: `d2 <= -sqrt(2k)` bounds the true digital below
/// 1e-11 at this moneyness regardless of variance, unlike the ITM side.
const DEEP_OTM_STRIKE: u64 = 1_000_000_000_000_000_000;

/// Surface whose total variance at `DEEP_ITM_STRIKE` is 481.2, far enough that the
/// deep-ITM digital is 4.9e-23 rather than 1. Well inside the pricing-safe envelope.
const HIGH_VARIANCE_SVI_B: u64 = 10_000_000_000;
const HIGH_VARIANCE_SIGMA: u64 = 100_000_000;
const HIGH_VARIANCE_RHO_MAGNITUDE: u64 = 900_000_000;
// Independent copies of `pricing.move`'s private pricing-safe envelope (the macros
// are module-private, so the bounds are reproduced here from the source, not read).
// The basis ceiling (100 * 1e9) is exercised by computing `spot * 101` directly.
const MAX_PRICING_SPOT: u64 = 184_467_440_737_095_516; // u64::MAX / 100
const NEGATIVE_SVI_A_MAG: u64 = 1_000_000;
const POSITIVE_MIN_VARIANCE_SVI_B: u64 = 10_000_000;
const POSITIVE_MIN_VARIANCE_SIGMA: u64 = 500_000_000;
const NEGATIVE_A_AT_FORWARD_REFERENCE: u64 = 487_386_440;
const NONPOSITIVE_MIN_VARIANCE_A_MAG: u64 = 5_000_001;

/// `normal_cdf` and `normal_pdf` saturate beyond `|8|`; the cap sits one raw unit
/// past that so a capped value is unambiguously outside the live domain.
const SATURATED_D2_MAGNITUDE: u64 = 8_000_000_001;
/// w = 1e-9 at 1e18 (`b * inner / 1e9` = 1e9), the smallest variance the load gate
/// can admit: sqrt(w) is 31_622 and d2 stays far inside the cap. `b` is the rolled
/// 1e18 form, so raw b = 1_000 arrives as 1_000 * 1e9.
const WELL_CONDITIONED_B_1E18: u128 = 1_000_000_000_000;
const WELL_CONDITIONED_INNER: u64 = 1_000_000;
const WELL_CONDITIONED_SQRT_W: u64 = 31_622;
/// The smallest representable variance: `b * inner / 1e9` = 1 raw unit at 1e18.
const MINIMAL_B_1E18: u128 = 1_000_000_000;
const MINIMAL_INNER: u64 = 1;

/// A loadable surface (`|rho| == 1e9` zeroes min_increment, so it clears the gate
/// on `a` alone) whose skew correction is live and whose small `sqrt(w)` amplifies
/// it, separating the 1e18 and 1e9 forms of `w'`. `m` is negative.
const W_PRIME_SURFACE_A: u64 = 203;
const W_PRIME_SURFACE_B: u64 = 13;
const W_PRIME_SURFACE_RHO: u64 = 1_000_000_000;
const W_PRIME_SURFACE_M: u64 = 831_439;
const W_PRIME_SURFACE_SIGMA: u64 = 5_000_000;
/// Seed the tuple at `now_ms`, price one second later: the seed's source time
/// is the roll-down anchor, so the roll-down is live at 119_000/120_000.
const W_PRIME_EXPIRY_MS: u64 = 240_000;
const W_PRIME_PRICED_AT_MS: u64 = 121_000;

/// A surface found by search whose rounded analytical minimum total variance is
/// exactly one raw unit: the load gate's increment comes to 2_904_654 (flooring
/// `rho^2` rounds `1 - rho^2` up) and `a` is one unit less. `m` sits within two raw
/// units of the smile's minimum `rho * sigma / sqrt(1 - rho^2) = 1_824_255.58`, so
/// at the forward strike (`k = 0`) the true increment is 2_904_653.99996 raw units
/// and the floored root makes it 2_904_653: true variance about +1e-9, computed 0.
const PER_STRIKE_NONPOSITIVE_A_MAG: u64 = 2_904_653;
const PER_STRIKE_NONPOSITIVE_B: u64 = 1_000_000_000;
const PER_STRIKE_NONPOSITIVE_SIGMA: u64 = 3_315_343;
const PER_STRIKE_NONPOSITIVE_RHO: u64 = 482_084_487;
const PER_STRIKE_NONPOSITIVE_M: u64 = 1_824_257;
const ROLL_DOWN_ZERO_VARIANCE_RAW_A: u64 = 1;
const ROLL_DOWN_ZERO_VARIANCE_RAW_B: u64 = 0;
const ROLL_DOWN_CLOCK_ADVANCE_MS: u64 = 1;
const TERMINAL_ROLL_DOWN_REMAINING_MS: u64 = 1;
const ZERO_SVI_SHAPE_PARAM: u64 = 0;

/// The envelope corners that hand the smile root its largest inputs: `sigma` and
/// `|m|` at the 100 ceiling, and a strike and forward at opposite ends of `u64`, so
/// `|k - m|` reaches 144.4 (OTM) and 139.8 (ITM) and the root's 1e18 input is about
/// 3e22. Both digitals are saturated in true math (`|d2|` is 9.97 and ~1e5), so
/// the exact expected values are the clamps: these pin that the root's largest
/// inputs neither overflow nor abort, not the root's value, which the SSVI
/// reference tests pin.
const ROOT_CORNER_MIN_PRICE: u64 = 1;
const ROOT_CORNER_OTM_B: u64 = 1_000_000_000;
const ROOT_CORNER_ITM_B: u64 = 1;
/// A BTC-scale forward, $70,000, for the extreme-`a` corner.
const EXTREME_A_FORWARD: u64 = 70_000_000_000_000;
/// A surface past the former `|a| <= 100` cap: `b` at its 100 ceiling, `sigma = 2`,
/// `rho = m = 0`, so the SVI increment's minimum is `100 * 2 * sqrt(1 - 0) = 200`,
/// reached at the forward.
const PAST_A_CAP_SIGMA: u64 = 2_000_000_000;
const PAST_A_CAP_MIN_INCREMENT: u64 = 200_000_000_000;

// === Abort guards ===

#[test, expected_failure(abort_code = pricing::EInvalidRange)]
fun live_quote_with_equal_range_bounds_aborts() {
    let (mut fx, oracle) = setup_live();
    // lower must be strictly below higher; the empty (degenerate) range aborts
    // after the freshness gates pass.
    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceUnavailable)]
fun live_quote_with_no_block_scholes_price_aborts() {
    // A market that has never received a BS push: normalized_spot is none, so
    // pricing aborts on absence (distinct from the staleness code below).
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    live_quote(&mut fx, &oracle, test_constants::default_live_price(), constants::pos_inf!());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIUnavailable)]
fun live_quote_with_prices_but_no_svi_aborts() {
    // Spot and forward pushed, SVI never pushed: the SVI absence code fires,
    // distinct from EBlockScholesSVIStale.
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let now = test_constants::live_source_timestamp_ms();
    fx.set_bs_spot_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    live_quote(&mut fx, &oracle, test_constants::default_live_price(), constants::pos_inf!());
    abort EUnexpectedSuccess
}

/// The provider store accepts u128 values, but Predict names the width failure before narrowing.
#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_price_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_live_price(),
    );
    fx.set_bs_spot_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        FIRST_UNREPRESENTABLE_U64,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// The inclusive u64 maximum crosses the width gate and reaches Predict's tighter semantic bounds.
#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun block_scholes_forward_at_u64_max_reaches_semantic_validation() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        MAX_REPRESENTABLE_U64,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_forward_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        FIRST_UNREPRESENTABLE_U64,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// The same named representation boundary applies to the signed SVI `a` magnitude.
#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_svi_a_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_svi_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        FIRST_UNREPRESENTABLE_U64,
        test_constants::default_svi_b() as u128,
        test_constants::default_svi_sigma() as u128,
        test_constants::default_svi_rho_magnitude() as u128,
        test_constants::default_svi_m() as u128,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_svi_b_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_svi_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_svi_a() as u128,
        FIRST_UNREPRESENTABLE_U64,
        test_constants::default_svi_sigma() as u128,
        test_constants::default_svi_rho_magnitude() as u128,
        test_constants::default_svi_m() as u128,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_svi_rho_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_svi_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_svi_a() as u128,
        test_constants::default_svi_b() as u128,
        test_constants::default_svi_sigma() as u128,
        FIRST_UNREPRESENTABLE_U64,
        test_constants::default_svi_m() as u128,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_svi_m_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_svi_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_svi_a() as u128,
        test_constants::default_svi_b() as u128,
        test_constants::default_svi_sigma() as u128,
        test_constants::default_svi_rho_magnitude() as u128,
        FIRST_UNREPRESENTABLE_U64,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_svi_sigma_above_u64_aborts_with_named_width_error() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_svi_raw_for_testing_bundle(
        &mut oracle,
        test_constants::now_ms(),
        test_constants::default_svi_a() as u128,
        test_constants::default_svi_b() as u128,
        FIRST_UNREPRESENTABLE_U64,
        test_constants::default_svi_rho_magnitude() as u128,
        test_constants::default_svi_m() as u128,
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_stale_block_scholes_surface_aborts() {
    let (mut fx, oracle) = setup_live();
    // One ms past the BS price freshness window, the spot and forward feeds are
    // stale and the quote aborts before any pricing.
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_fresh_spot_but_stale_forward_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, stale_now, test_constants::default_live_price());

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun live_quote_with_fresh_prices_but_stale_svi_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let stale_now =
        test_constants::now_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_svi_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, stale_now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        stale_now,
        test_constants::default_live_price(),
    );

    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// A newer batch timestamp does not refresh an unchanged spot update. Freshness remains keyed to
/// the update's provider source timestamp, which is older than the configured price window here.
#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_a_retransmitted_aged_spot_source_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let source_ms = test_constants::live_source_timestamp_ms();
    let retransmitted_now =
        source_ms
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(retransmitted_now);
    fx.retransmit_bs_spot_for_testing(
        &mut oracle,
        source_ms,
        retransmitted_now,
        test_constants::default_live_price(),
    );
    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// The same rule applies to forwards: transport in a current batch does not make an unchanged
/// forward source timestamp current.
#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun live_quote_with_a_retransmitted_aged_forward_source_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let source_ms = test_constants::live_source_timestamp_ms();
    let retransmitted_now =
        source_ms
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(retransmitted_now);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        retransmitted_now,
        test_constants::default_live_price(),
    );
    fx.retransmit_bs_forward_for_testing(
        &mut oracle,
        source_ms,
        retransmitted_now,
        test_constants::default_live_price(),
    );
    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// SVI freshness also stays on the tuple's source timestamp. A newer batch timestamp neither
/// refreshes the tuple nor changes the roll-down anchor.
#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun live_quote_with_a_retransmitted_aged_svi_source_aborts() {
    let (mut fx, mut oracle) = setup_live();
    let source_ms = test_constants::live_source_timestamp_ms();
    let retransmitted_now =
        source_ms
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_svi_freshness_ms()
        + 1;
    fx.set_clock_for_testing(retransmitted_now);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        retransmitted_now,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        retransmitted_now,
        test_constants::default_live_price(),
    );
    fx.retransmit_bs_svi_for_testing(
        &mut oracle,
        source_ms,
        retransmitted_now,
        test_constants::default_svi_a(),
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    live_quote(
        &mut fx,
        &oracle,
        test_constants::default_live_price(),
        constants::pos_inf!(),
    );
    abort EUnexpectedSuccess
}

/// A store for another underlying is a real, registry-created store that simply is not the one
/// bound to this market's underlying. Predict must reject it on the binding rather than on the
/// store's own claim about itself.
#[test, expected_failure(abort_code = pricing::EWrongBlockScholesValueStore)]
fun live_pricer_with_another_underlyings_value_store_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let foreign_pair = fx.create_foreign_block_scholes_stores(
        FOREIGN_UNDERLYING_ID,
    );
    let foreign_values_id = foreign_pair.block_scholes_value_store_id();

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let foreign_values = fx
        .scenario_mut()
        .take_shared_by_id<BlockScholesValueStore>(
            foreign_values_id,
        );
    load_pricer_with_values(&mut fx, &oracle, &foreign_values);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSVIStore)]
fun live_pricer_with_another_underlyings_svi_store_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let foreign_pair = fx.create_foreign_block_scholes_stores(
        FOREIGN_UNDERLYING_ID,
    );
    let foreign_svi_id = foreign_pair.block_scholes_svi_store_id();

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let foreign_svi = fx.scenario_mut().take_shared_by_id<BlockScholesSVIStore>(foreign_svi_id);
    load_pricer_with_svi(&mut fx, &oracle, &foreign_svi);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EPythSpotInvalid)]
fun fresh_pyth_spot_above_pricing_ceiling_aborts() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_pyth_bundle(
        &mut oracle,
        MAX_PRICING_SPOT + 1,
        test_constants::live_source_timestamp_ms() + 1,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);

    abort EUnexpectedSuccess
}

/// The companion of the test above, and the reason `EPythSpotInvalid` sits inside
/// the re-anchor branch rather than above it: the ceiling guards the value the
/// re-anchor multiplies, so with `use_pyth_spot_for_forward` clear an oversized
/// print is ignored like any other Pyth print instead of taking down live pricing.
/// Hoisting the assert out of the branch would let one bad Pyth print abort the
/// mandatory pool flush in the mode that never reads Pyth — every other test in
/// this file still passes under that change, so this is the pin.
#[test]
fun pyth_spot_above_pricing_ceiling_is_inert_while_the_switch_is_off() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_use_pyth_spot_for_forward_bundle(&mut oracle, false);
    let oversized_source_ms = test_constants::live_source_timestamp_ms() + 1;
    fx.set_pyth_bundle(&mut oracle, MAX_PRICING_SPOT + 1, oversized_source_ms);

    // Loads, and on the stored Block Scholes forward: the at-the-forward digital is
    // the default surface's, unaffected by the oversized print.
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::flow_fixture_atm_up(),
        ref_data::flow_fixture_atm_budget(),
    );
    // Ignored for the forward, still snapshotted for provenance: an out-of-envelope
    // print is not a missing observation, so it must not read back as the `0`
    // sentinel that means "no usable normalized Pyth read".
    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), oversized_source_ms);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Price tails (computed, not branched on the strike ratio) ===

/// Deep-ITM up tail on an ordinary low-variance surface: a strike far below the
/// forward prices to ~1.0 (the neg_inf limit), reached through `d2`'s normal-CDF
/// clamp rather than asserted by a branch. The companion test below drives the same
/// strike on a high-variance surface, where the correct answer is 0 instead.
#[test]
fun deep_itm_up_price_saturates_to_one() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Fresh spot == forward == 100e9.
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(DEEP_ITM_STRIKE)), float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// The same deep-ITM strike as the test above, repriced on a high-variance surface:
/// the digital limit is a property of the SURFACE, not of the strike alone, and this
/// is the case that separates them.
///
/// `b = 10`, `sigma = 0.1`, `rho = -0.9`, `m = 0` at `k = ln(1e-9) - ln(100) =
/// -25.3285` gives total variance `w = 481.2`, hence
/// `d2 = -(k + w/2)/sqrt(w) = -9.81` and a true digital of `4.9e-23` — zero at the
/// 1e9 scale the price is returned in. Reference computed from Python stdlib `erf`,
/// independent of the contract.
///
/// This inverts under the previous implementation, which formed `strike * 1e9 /
/// forward` first: that quotient floors to zero here, and the deep-ITM branch
/// returned the exact digital limit `1e9` — certainty, against a true probability
/// of ~0 — for every admissible surface, because the branch never read the surface
/// at all. Every consumer of `range_price` inherited it: the mint's entry
/// probability and the NAV mark.
#[test]
fun deep_itm_up_price_follows_the_surface_not_the_strike_ratio() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::default_svi_a(),
        false,
        HIGH_VARIANCE_SVI_B,
        HIGH_VARIANCE_SIGMA,
        HIGH_VARIANCE_RHO_MAGNITUDE,
        true,
        0,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(DEEP_ITM_STRIKE)), 0);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Deep-OTM up tail: a strike far above the forward prices to 0 (the pos_inf limit).
/// Unlike the ITM side this holds for every admissible surface, not just low-variance
/// ones — `d2 <= -sqrt(2k)` bounds the true digital below 1e-11 at this moneyness
/// regardless of variance — so there is no high-variance companion case.
#[test]
fun deep_otm_up_price_saturates_to_zero() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Fresh spot == forward == 1 (a tiny forward, so a finite u64 strike can clear
    // the saturation threshold without being the pos_inf sentinel).
    fx.prepare_live_oracle_bundle(&mut oracle, 1);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(DEEP_OTM_STRIKE)), 0);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Surface pricing-safe envelope rejects (EBlockScholesInputsInvalid) ===

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_forward_above_spot_ceiling_aborts() {
    // forward just over the spot ceiling fires the `forward <= max_pricing_spot`
    // branch before the basis check. spot small so the basis arithmetic stays in u128.
    load_pricer_with_spot_forward(test_constants::float(), MAX_PRICING_SPOT + 1);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_basis_above_max_aborts() {
    // basis = forward * 1e9 / spot = 101e9 > 100e9, with forward still under the
    // spot ceiling so the basis branch (not the ceiling branch) is the one that fires.
    let spot = 100 * test_constants::float();
    let forward = spot * 101;
    load_pricer_with_spot_forward(spot, forward);
    abort EUnexpectedSuccess
}

/// The basis envelope is exact: `forward == factor * spot` is the largest
/// admitted forward. The old widening compare admitted a `floor(spot/1e9)`-unit
/// sliver above it; the `div_ceil` form deliberately tightens that away, so the
/// very next unit must reject (companion admit case below pins the boundary
/// from the other side).
#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_basis_one_above_exact_factor_aborts() {
    let spot = 100 * test_constants::float();
    let forward = spot * 100 + 1;
    load_pricer_with_spot_forward(spot, forward);
    abort EUnexpectedSuccess
}

#[test]
fun surface_with_basis_at_exact_factor_admits() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let spot = 100 * test_constants::float();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        spot,
        spot * 100, // basis exactly at the factor: the largest admitted forward
        default_svi_a(),
        false,
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    // Envelope admitted: quote at the re-anchored forward itself (pyth spot
    // equals the BS spot here, so the live forward is spot * 100), where the
    // at-the-forward digital is strictly interior — neither the zero-forward
    // abort nor a saturated tail. Exact pricing values are owned by the oracle
    // scenario tests; this test pins that the exact-boundary basis is admitted
    // and priceable.
    let price = pricer.up_price(strike(spot * 100));
    assert!(0 < price && price < float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === `a` carries no bound beyond total variance ===

/// `a` at `u64::MAX`, the largest value that narrows to Predict's width, loads:
/// the minimum-variance check compares rather than sums, and the roll-down, total
/// variance, and `sqrt(w)` all fit. Total variance is about 1.8e10, so the true
/// digital at the forward is `Phi(-6.8e4)`, which is 0. One unit wider aborts with
/// the named width error (`block_scholes_svi_a_above_u64_aborts_with_named_width_error`).
#[test]
fun svi_a_at_the_provider_width_limit_prices_to_zero() {
    let pricer_up = load_pricer_with_signed_a_and_price_forward(
        std::u64::max_value!(),
        false,
        default_svi_b(),
        default_svi_sigma(),
    );
    assert_eq!(pricer_up, 0);
}

/// `a = u64::MAX` with every shape bound at its ceiling as well: `b = sigma = 100`,
/// `|rho| = 1` (so the SVI increment's minimum is 0 and `a` alone carries the
/// minimum variance), and `m = +-100`. Total variance is at least 1.8e10 at every
/// strike, so the true digital is 0 from the smallest strike to the pricing-spot
/// ceiling; the contract prices all of them without an arithmetic abort.
#[test]
fun svi_a_at_the_provider_width_limit_with_shape_ceilings_and_positive_m_prices_to_zero() {
    assert_extreme_a_prices_to_zero(false);
}

#[test]
fun svi_a_at_the_provider_width_limit_with_shape_ceilings_and_negative_m_prices_to_zero() {
    assert_extreme_a_prices_to_zero(true);
}

fun assert_extreme_a_prices_to_zero(m_is_negative: bool) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        EXTREME_A_FORWARD,
        EXTREME_A_FORWARD,
        std::u64::max_value!(),
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_max_svi_input(),
        test_constants::float(),
        true,
        test_constants::pricing_max_svi_input(),
        m_is_negative,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let strikes = vector[
        ROOT_CORNER_MIN_PRICE,
        test_constants::float(),
        EXTREME_A_FORWARD,
        MAX_PRICING_SPOT,
    ];
    strikes.do_ref!(|k| assert_eq!(pricer.up_price(strike(*k)), 0));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// The same magnitude negative: no SVI increment can offset it, so the load
/// gate rejects it by name rather than by an arithmetic abort.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun negative_svi_a_at_the_provider_width_limit_aborts_at_load() {
    load_pricer_with_signed_a_and_price_forward(
        std::u64::max_value!(),
        true,
        default_svi_b(),
        default_svi_sigma(),
    );
    abort EUnexpectedSuccess
}

/// `a = -199.999999999`, past the former cap, leaves one raw unit of minimum
/// total variance. At the forward `k = m = 0`, so the root is exactly `sigma`,
/// `rho * (k - m)` is 0, and the 1e18 path computes `w = 200 - 199.999999999`
/// exactly: 1e-9, with `w' = b * rho = 0`. That is the flat `a = 1e-9, b = 0`
/// surface's digital, so its reference and budget apply unchanged.
#[test]
fun negative_svi_a_past_the_former_cap_cancels_to_one_unit_of_variance() {
    let up = load_pricer_with_signed_a_and_price_forward(
        PAST_A_CAP_MIN_INCREMENT - 1,
        true,
        test_constants::pricing_max_svi_input(),
        PAST_A_CAP_SIGMA,
    );
    test_helpers::assert_within(
        up,
        ref_data::flat_surface_atm_up(),
        ref_data::flat_surface_atm_budget(),
    );
}

/// One raw unit further: `a` exactly offsets the SVI increment's minimum, so
/// minimum total variance is zero and the load gate rejects it.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun negative_svi_a_past_the_former_cap_offsetting_the_minimum_increment_aborts() {
    load_pricer_with_signed_a_and_price_forward(
        PAST_A_CAP_MIN_INCREMENT,
        true,
        test_constants::pricing_max_svi_input(),
        PAST_A_CAP_SIGMA,
    );
    abort EUnexpectedSuccess
}

#[test]
fun negative_svi_a_with_positive_min_variance_prices() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NEGATIVE_SVI_A_MAG,
        true,
        POSITIVE_MIN_VARIANCE_SVI_B,
        POSITIVE_MIN_VARIANCE_SIGMA,
        0,
        false,
        0,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    let up = pricer
        .range_price(
            strike(test_constants::default_live_price()),
            strike(constants::pos_inf!()),
        )
        .probability();
    // Independent Python true-math reference:
    // w = -0.001 + 0.01 * sqrt(0^2 + 0.5^2) = 0.004, w' = 0,
    // d2 = -(w / 2) / sqrt(w), Phi(d2) = 0.4873864396849802.
    // The tolerance uses the committed pricing-reference generator's worst-case
    // per-endpoint error budget. This at-forward, zero-skew point is less
    // ill-conditioned than that generated small-variance worst case.
    test_helpers::assert_within(
        up,
        NEGATIVE_A_AT_FORWARD_REFERENCE,
        ref_data::worst_case_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun negative_svi_a_with_nonpositive_min_variance_aborts_at_load() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        NONPOSITIVE_MIN_VARIANCE_A_MAG,
        true,
        POSITIVE_MIN_VARIANCE_SVI_B,
        POSITIVE_MIN_VARIANCE_SIGMA,
        0,
        false,
        0,
        false,
    );

    let _pricer = fx.load_pricer_bundle(&oracle);
    abort EUnexpectedSuccess
}

/// The one-minute negative-`a` slice with `a` one raw unit more negative, so it
/// exactly offsets the rounded minimum increment: minimum total variance falls
/// from one unit to zero and the load gate rejects it.
/// `short_dated_slice_with_negative_a_prices_to_true_math` in `pricing_exact_tests`
/// prices the unmodified slice on the other side.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun short_dated_negative_a_offsetting_the_minimum_increment_aborts() {
    let s = ssvi::negative_a_slice();
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ssvi::spot(s),
        ssvi::forward(s),
        ssvi::svi_a_magnitude(s) + 1,
        ssvi::svi_a_is_negative(s),
        ssvi::svi_b(s),
        ssvi::svi_sigma(s),
        ssvi::svi_rho_magnitude(s),
        ssvi::svi_rho_is_negative(s),
        ssvi::svi_m_magnitude(s),
        ssvi::svi_m_is_negative(s),
    );

    let _pricer = fx.load_pricer_bundle(&oracle);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_b_above_max_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        test_constants::pricing_max_svi_input() + 1,
        default_svi_sigma(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_rho_above_one_aborts() {
    // rho magnitude just over 1.0 fails `|rho| <= 1e9`.
    load_pricer_with_full_svi(
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::float() + 1,
        false,
        default_svi_m_magnitude(),
        false,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_m_above_max_aborts() {
    load_pricer_with_full_svi(
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::float(),
        false,
        test_constants::pricing_max_svi_input() + 1,
        false,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_below_min_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        default_svi_b(),
        test_constants::pricing_min_svi_sigma() - 1,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_zero_svi_sigma_aborts() {
    load_pricer_with_invalid_svi(default_svi_a(), default_svi_b(), ZERO_SVI_SHAPE_PARAM);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun surface_with_svi_sigma_above_max_aborts() {
    load_pricer_with_invalid_svi(
        default_svi_a(),
        default_svi_b(),
        test_constants::pricing_max_svi_input() + 1,
    );
    abort EUnexpectedSuccess
}

// === Smile root at the envelope corner ===

/// Largest finite strike over a one-raw-unit forward with `m = -100`: the root
/// takes `144.4^2 + 100^2` at 1e18 without overflowing, and the far-OTM digital is 0.
#[test]
fun smile_root_at_the_otm_envelope_corner_prices_the_tail_to_zero() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ROOT_CORNER_MIN_PRICE,
        ROOT_CORNER_MIN_PRICE,
        ZERO_SVI_SHAPE_PARAM,
        false,
        ROOT_CORNER_OTM_B,
        test_constants::pricing_max_svi_input(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        test_constants::pricing_max_svi_input(),
        true,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(constants::pos_inf!() - 1)), 0);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// One-raw-unit strike under the largest pricing-safe forward with `m = 100`: the
/// root takes `139.8^2 + 100^2` at 1e18, and the deep-ITM digital is exactly one.
#[test]
fun smile_root_at_the_itm_envelope_corner_prices_the_tail_to_one() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        MAX_PRICING_SPOT,
        MAX_PRICING_SPOT,
        ZERO_SVI_SHAPE_PARAM,
        false,
        ROOT_CORNER_ITM_B,
        test_constants::pricing_max_svi_input(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        test_constants::pricing_max_svi_input(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.up_price(strike(ROOT_CORNER_MIN_PRICE)), float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Deep-math abort (EZeroForward) ===

/// A surface whose forward is tiny relative to the BS spot passes the envelope
/// (there is no LOWER basis bound), but re-anchoring at a pyth spot far below the
/// BS spot floors `spot * bs_forward / bs_spot` to 0, and `compute_nd2` aborts on
/// the first finite-strike quote.
#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun re_anchored_zero_forward_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let bs_spot = 100_000_000_000_000_000; // 1e17, under the spot ceiling
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        bs_spot,
        1, // bs_forward == 1
        default_svi_a(),
        false,
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    // Re-anchor at a pyth spot far below the BS spot: 1e9 * 1 / 1e17 floors to 0.
    let pyth_source_ts = fx.clock().timestamp_ms();
    fx.set_pyth_bundle(&mut oracle, 1_000_000_000, pyth_source_ts);
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// A boundary-valid surface can still hit the quote-time positive-variance
/// backstop: the load-time rounded analytical minimum is positive by one unit,
/// and at the forward strike the floored smile root takes that unit back, so
/// total variance rounds to exactly zero against a true value of 1e-9.
#[test, expected_failure(abort_code = pricing::ENonPositiveVariance)]
fun boundary_loaded_surface_with_nonpositive_per_strike_variance_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        PER_STRIKE_NONPOSITIVE_A_MAG,
        true,
        PER_STRIKE_NONPOSITIVE_B,
        PER_STRIKE_NONPOSITIVE_SIGMA,
        PER_STRIKE_NONPOSITIVE_RHO,
        false,
        PER_STRIKE_NONPOSITIVE_M,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// The `d2` saturation from RP-20, exercised at the helper's own scalar inputs.
///
/// `d2` is `(k + w/2) / sqrt(w)` with the numerator carried at 1e18 and the
/// divisor at 1e9, so as `w` collapses the quotient grows without bound and the
/// narrowing cast to the `I64` magnitude would abort. `normal_cdf` and
/// `normal_pdf` are already saturated everywhere past `|8|`, so the value is
/// capped there instead: the arithmetic cannot abort, and no reachable price
/// changes because the caller was already on the clamp.
///
/// Driven directly rather than through a surface: the pricer-load gate keeps the
/// minimum total variance at or above one raw unit at 1e9, which bounds `sqrt(w)`
/// from below and holds the quotient inside `u64` for every admissible surface
/// sampled. The guard is defence against that bound being wrong, so it is pinned
/// where it can actually be driven.
#[test]
fun d2_saturates_at_the_normal_clamp_instead_of_overflowing() {
    // w = 1 raw unit at 1e18, so sqrt(w) is 1 and d2 is the numerator itself:
    // k at its domain maximum would otherwise divide out to ~2e19, past u64.
    let k = i64::from_parts(20_000_000_000, true);
    let (sqrt_var, d2) = pricing::variance_sqrt_and_d2_for_testing(
        0,
        false,
        MINIMAL_B_1E18,
        MINIMAL_INNER,
        &k,
    );

    assert_eq!(sqrt_var, 1);
    assert_eq!(d2.magnitude(), SATURATED_D2_MAGNITUDE);
    assert!(!d2.is_negative());

    // A well-conditioned input on the same path is untouched by the cap.
    let (sqrt_var, d2) = pricing::variance_sqrt_and_d2_for_testing(
        0,
        false,
        WELL_CONDITIONED_B_1E18,
        WELL_CONDITIONED_INNER,
        &i64::from_u64(0),
    );
    assert_eq!(sqrt_var, WELL_CONDITIONED_SQRT_W);
    assert!(d2.magnitude() < SATURATED_D2_MAGNITUDE);
}

/// Raw `a == 1` one millisecond past the publish anchor. The 1e9 roll-down
/// floored it straight to zero here and aborted `ENonPositiveVariance` on a
/// surface whose variance is barely reduced; carrying the roll-down at 1e18
/// leaves `a` at 0.9999833e-9 (ratio 59_999/60_000) and the surface prices
/// normally. The expected value is the flat-surface reference: `b` is zero, so
/// `w` is just the rolled `a`, and the roll-down moves the digital by well
/// under one raw unit at this horizon.
#[test]
fun pre_expiry_roll_down_keeps_positive_variance() {
    let expiry_ms = test_constants::now_ms() + test_constants::default_cadence_period_ms();
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        expiry_ms,
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    fx.set_clock_for_testing(test_constants::now_ms() + ROLL_DOWN_CLOCK_ADVANCE_MS);
    let pricer = fx.load_pricer_bundle(&oracle);

    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::flat_surface_atm_up(),
        ref_data::flat_surface_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A raw-valid `a = 1e-9, b = 0` tuple sourced at `now_ms`, quoted one millisecond before a
/// one-year expiry with no newer source update in between. Flooring the rolled variance to zero
/// needs `anchor_tte_ms >= 1e9 * remaining_ms` — a source anchor years older than any admissible
/// freshness window — so source freshness pre-empts RP-21's zero-variance response: the quote
/// aborts stale long before the terminal region. A new source tuple near expiry instead re-anchors
/// the roll-down and prices at ratio ~1, so the terminal region is unreachable from both sides.
#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun terminal_roll_down_to_zero_is_preempted_by_source_freshness() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        ROLL_DOWN_ZERO_VARIANCE_RAW_A,
        false,
        ROLL_DOWN_ZERO_VARIANCE_RAW_B,
        default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );

    let terminal_source_timestamp_ms =
        test_constants::default_expiry_ms() - TERMINAL_ROLL_DOWN_REMAINING_MS;
    fx.set_clock_for_testing(terminal_source_timestamp_ms);
    fx.set_pyth_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        terminal_source_timestamp_ms,
    );
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        terminal_source_timestamp_ms,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        terminal_source_timestamp_ms,
        test_constants::default_live_price(),
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// Pins the rolled `b`'s precision through the SKEW CORRECTION, not just through
/// the variance. `compute_nd2` forms `w' = b * slope / 1e18` with `b` at 1e18;
/// narrowing `b` back to 1e9 first — the shape the variance path itself used to
/// have — silently drops up to a raw unit of it.
///
/// The flow fixtures cannot catch that: their `slope` is ~5 raw units, so `w'`
/// floors to zero and the correction term vanishes either way. And a fixture whose
/// pricer loads at the publish anchor cannot either, because at ratio 1 the
/// rolled `b` is integral at 1e9 and both forms agree exactly. So this seeds the
/// tuple and quotes one second after its publish anchor to get a genuinely
/// non-integral rolled `b`. Carrying it at 1e18 lands 4 units from the
/// independently generated digital; narrowing to 1e9 misses by ~890 — 42x the
/// budget.
#[test]
fun w_prime_keeps_the_rolled_b_precision() {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        W_PRIME_EXPIRY_MS,
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        W_PRIME_SURFACE_A,
        false,
        W_PRIME_SURFACE_B,
        W_PRIME_SURFACE_SIGMA,
        W_PRIME_SURFACE_RHO,
        false,
        W_PRIME_SURFACE_M,
        true,
    );

    fx.set_clock_for_testing(W_PRIME_PRICED_AT_MS);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        W_PRIME_PRICED_AT_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        W_PRIME_PRICED_AT_MS,
        test_constants::default_live_price(),
    );

    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::w_prime_precision_surface_up(),
        ref_data::flow_fixture_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Surface minimum-variance abort ===

/// A degenerate surface (`a == 0, b == 0`) has zero analytical minimum total
/// variance (`a + b*sigma*sqrt(1-rho^2) == 0`), so it is rejected while loading
/// the live pricer rather than reaching the first finite-strike quote.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun zero_total_variance_aborts_at_load() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        0, // svi_a == 0
        false,
        0, // svi_b == 0, so total_var = a + b*inner == 0
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    abort EUnexpectedSuccess
}

/// At `|rho| == 1` the SVI increment `b * (rho * x + sqrt(x^2 + sigma^2))` has
/// infimum 0 over `x` for any `b` (it tends to 0 along one wing), so the minimum
/// total variance is `a` alone: `a == 0` is rejected even with a live `b`.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun zero_svi_a_with_unit_rho_aborts_at_load() {
    load_pricer_with_unit_rho(0, false);
    abort EUnexpectedSuccess
}

/// The same with `a` one raw unit negative.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun negative_svi_a_with_unit_rho_aborts_at_load() {
    load_pricer_with_unit_rho(1, true);
    abort EUnexpectedSuccess
}

/// Seed the SSVI reference's `rho = -1` slice with `a` replaced. With `a` one raw
/// unit positive it loads and prices
/// (`pricing_exact_tests::unit_rho_surface_with_one_unit_of_a_prices_to_true_math`).
fun load_pricer_with_unit_rho(svi_a_magnitude: u64, svi_a_is_negative: bool) {
    let s = ssvi::unit_rho_slice();
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ssvi::spot(s),
        ssvi::forward(s),
        svi_a_magnitude,
        svi_a_is_negative,
        ssvi::svi_b(s),
        ssvi::svi_sigma(s),
        ssvi::svi_rho_magnitude(s),
        ssvi::svi_rho_is_negative(s),
        ssvi::svi_m_magnitude(s),
        ssvi::svi_m_is_negative(s),
    );
    let _pricer = fx.load_pricer_bundle(&oracle);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Helpers ===

fun default_svi_a(): u64 { test_constants::default_svi_a() }

fun default_svi_b(): u64 { test_constants::default_svi_b() }

fun default_svi_sigma(): u64 { test_constants::default_svi_sigma() }

fun default_svi_m_magnitude(): u64 { test_constants::default_svi_m() }

/// Seed a surface with the given spot/forward and default SVI, then load the pricer
/// (where `assert_inputs_pricing_safe` runs).
fun load_pricer_with_spot_forward(spot: u64, forward: u64) {
    load_pricer_with_full_svi_and_spot(
        spot,
        forward,
        default_svi_a(),
        default_svi_b(),
        default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
}

/// Seed a default-spot/forward surface with the given SVI a/b/sigma (rho/m default),
/// then load the pricer.
fun load_pricer_with_invalid_svi(svi_a: u64, svi_b: u64, svi_sigma: u64) {
    load_pricer_with_full_svi(
        svi_a,
        svi_b,
        svi_sigma,
        test_constants::default_svi_rho_magnitude(),
        false,
        default_svi_m_magnitude(),
        false,
    );
}

/// Seed a default-spot/forward surface with a fully specified SVI, then load.
fun load_pricer_with_full_svi(
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    load_pricer_with_full_svi_and_spot(
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        svi_a,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

fun load_pricer_with_full_svi_and_spot(
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        spot,
        forward,
        svi_a,
        false,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
    // `load_pricer` runs `assert_inputs_pricing_safe`; the invalid surface aborts
    // here before the pricer is returned.
    let _pricer = fx.load_pricer_bundle(&oracle);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Seed a default-spot surface with signed `a` and the given `b`/`sigma` (`rho` and
/// `m` zero), load it, and return the UP digital at the forward.
fun load_pricer_with_signed_a_and_price_forward(
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
): u64 {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    let up = pricer.up_price(strike(test_constants::default_live_price()));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
    up
}

fun load_pricer_with_values(
    fx: &mut OracleFixture,
    oracle: &OracleBundle,
    values: &BlockScholesValueStore,
) {
    let _pricer = fx.load_pricer_with_stores(
        oracle_fixture::config(oracle),
        oracle_fixture::oracle_registry(oracle),
        oracle_fixture::pyth(oracle),
        values,
        oracle_fixture::bs(oracle).svi(),
    );
}

fun load_pricer_with_svi(
    fx: &mut OracleFixture,
    oracle: &OracleBundle,
    svi: &BlockScholesSVIStore,
) {
    let _pricer = fx.load_pricer_with_stores(
        oracle_fixture::config(oracle),
        oracle_fixture::oracle_registry(oracle),
        oracle_fixture::pyth(oracle),
        oracle_fixture::bs(oracle).values(),
        svi,
    );
}

/// Bring up the default live oracle: fresh Pyth spot + split Block Scholes feeds,
/// quotable at the fixture clock (forward == 100e9).
fun setup_live(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle)
}

/// Worker: one live quote over `(lower, higher]` against the fixture market.
fun live_quote(fx: &mut OracleFixture, oracle: &OracleBundle, lower: u64, higher: u64): u64 {
    let pricer = fx.load_pricer_bundle(oracle);
    pricer.range_price(strike(lower), strike(higher)).probability()
}
