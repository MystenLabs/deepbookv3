// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Live binary-pricing invariants for `pricing::Pricer`, driven through the
/// minimal `oracle_fixture`.
///
/// These assert EXACT structural invariants that need no precision budget:
///   - complementarity: P([-inf, X]) + P([X, +inf]) == 1 exactly (the shared
///     up(X) term cancels in `lower_up - higher_up`), for any finite X;
///   - whole-line: P([-inf, +inf]) == 1;
///   - monotonicity: the digital "above X" probability is non-increasing in X;
///   - forward-source selection: the live forward is Pyth-spot-based exactly
///     while Pyth is fresh (inclusive boundary) and falls back to the stored
///     Block Scholes forward one millisecond later;
///   - oracle provenance: every source timestamp is retained independently of
///     forward selection, with `0` reserved for an unusable normalized Pyth read.
#[test_only]
module deepbook_predict::pricing_tests;

use deepbook_predict::{
    constants,
    oracle_fixture,
    pricing,
    pricing_reference_data as ref_data,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers
};
use fixed_math::{i64, math::float_scaling as float};
use std::unit_test::assert_eq;

// Forward == `default_live_price` (spot==forward, basis 1.0). The two scenario
// strikes straddle it.
const STRIKE_BELOW: u64 = 90_000_000_000;
const STRIKE_ABOVE: u64 = 110_000_000_000;

/// The UP digital when the strike sits exactly on the live forward, for the
/// default test surface (`a` 1e-9, `b` 1e-5, `rho` 1, `m` 10, `sigma` 1e-3):
/// `Phi(-sqrt(w)/2) - phi(d2)*w'/(2*sqrt(w))` with `w = 1.0005e-9`, computed from
/// Python's stdlib `erf` independently of the contract. It is ~6,310 raw units
/// below one half — positive variance always shades an at-the-forward digital
/// down, and only the zero-variance limit is balanced.
///
/// The tests below use it to identify WHICH spot/forward the pricer anchored to:
/// anchoring elsewhere moves the strike off the money and the price far from this
/// value, so the 21-unit band (`normal_cdf` is documented to 20, and the d2 path
/// plus the truncated-to-zero skew term add under 1 between them) still
/// discriminates the sources sharply.
const AT_THE_FORWARD_UP: u64 = 499_993_690;
const AT_THE_FORWARD_UP_BUDGET: u64 = 21;

/// A Pyth print diverged +2% from the 100e9 Block Scholes spot/forward.
/// Production-reachable: the Pyth feed applies no deviation cap against the
/// Block Scholes surface, so the live forward tracks the diverged spot.
const DIVERGED_PYTH_SPOT: u64 = 102_000_000_000;
// The boundary tests below need a Pyth window strictly shorter than the BS price window; the
// production defaults are equal (10s each), so the tests tighten Pyth explicitly.
const TIGHT_PYTH_FRESHNESS_MS: u64 = 2_000;

/// Source timestamp for the diverged Pyth print. Strictly newer than the bootstrap
/// tick's `live_source_timestamp_ms` (99_000) so the feed accepts the overwrite
/// (`store_tick_if_fresh` requires a strictly newer source), yet old enough that
/// its `freshness_ts + pyth_budget` boundary stays inside the (longer) Block
/// Scholes surface window, so the post-staleness fallback is observable rather than
/// aborting on a stale surface.
const DIVERGED_PYTH_SOURCE_MS: u64 = 119_500;
const PYTH_SOURCE_MS: u64 = 119_001;
const BLOCK_SCHOLES_SPOT_SOURCE_MS: u64 = 119_002;
const BLOCK_SCHOLES_FORWARD_SOURCE_MS: u64 = 119_003;
/// A strictly newer Pyth row whose zero price cannot produce a normalized spot.
const UNUSABLE_PYTH_SOURCE_MS: u64 = 119_001;
const UNUSABLE_PYTH_SPOT: u64 = 0;
const NO_USABLE_PYTH_SOURCE_TIMESTAMP_MS: u64 = 0;
const ROLL_DOWN_ANCHOR_MS: u64 = 120_000;
const ROLL_DOWN_EXPIRY_MS: u64 = 120_100;
const ROLL_DOWN_MIDPOINT_MS: u64 = 120_050;
const SHORT_ROLL_DOWN_EXPIRY_MS: u64 = 180_000;
const SHORT_ROLL_DOWN_MIDPOINT_MS: u64 = 150_000;
/// Halfway between the retransmit envelope (150_000) and expiry: the envelope anchor
/// scales the surface by 1/2 here, while the original model anchor (120_000) would
/// scale it by 1/4 — far enough apart that the ATM reference band tells them apart.
const SHORT_ROLL_DOWN_QUOTE_MS: u64 = 165_000;
const ODD_ROLL_DOWN_VALUE: u64 = 11;
const BOUNDARY_ROLL_DOWN_VALUE: u64 = 100;
const ONE_MS_ROLL_DOWN_VALUE: u64 = 1;
/// `roll_down_to_1e18` results, hand-derived as `value * 1e9 * remaining / anchor`.
/// 11 at the anchor; 11 halved is 5.5, which only exists at 1e18 — the 1e9 form
/// floored it to 5, a 9.1% loss on the term that dominates short-dated variance.
const ODD_AT_ANCHOR_1E18: u128 = 11_000_000_000;
const ODD_HALVED_1E18: u128 = 5_500_000_000;
/// 11 * 1e9 / 3 = 3_666_666_666.67 — the residual floor, now at 1e18 not 1e9.
const ODD_THIRD_1E18: u128 = 3_666_666_666;
const ONE_MS_1E18: u128 = 1_000_000_000;
/// u64::MAX * 1e9. Reached at ratio 1 with both terms at u64::MAX, where the
/// unreduced product is ~1.7e47 — far past u128, so this pins the u256 intermediate.
const U64_MAX_1E18: u128 = 18_446_744_073_709_551_615_000_000_000;
/// sqrt(w) for w = 5.5e9 at 1e18, i.e. isqrt(5_500_000_000). The 1e9 roll-down
/// produced w = 5e9 here and sqrt 70_710, so this value is what the extra
/// resolution is worth on the term pricing actually divides by.
const HALVED_B_SQRT_VAR: u64 = 74_161;
const UNIT_INNER: u64 = 1_000_000_000;
const RETRANSMITTED_SVI_A: u64 = 2;
const RETRANSMITTED_SVI_B: u64 = 0;
const ZERO_SVI_SHAPE_PARAM: u64 = 0;

#[test]
fun roll_down_is_exact_at_anchor_and_keeps_sub_1e9_resolution() {
    let anchor_tte_ms = ROLL_DOWN_EXPIRY_MS - ROLL_DOWN_ANCHOR_MS;

    // At the anchor the fraction is 1, so the value is just restated at 1e18.
    assert_eq!(
        pricing::roll_down_to_1e18(ODD_ROLL_DOWN_VALUE, anchor_tte_ms, anchor_tte_ms),
        ODD_AT_ANCHOR_1E18,
    );

    // 11 * 1e9 * 50 / 100 = 5.5e9. Half of an odd raw unit has no representation
    // at 1e9 — the previous roll-down floored it to 5 — so this exact 5.5 is the
    // resolution the 1e18 carry exists to keep.
    assert_eq!(
        pricing::roll_down_to_1e18(
            ODD_ROLL_DOWN_VALUE,
            ROLL_DOWN_EXPIRY_MS - ROLL_DOWN_MIDPOINT_MS,
            anchor_tte_ms,
        ),
        ODD_HALVED_1E18,
    );

    // 11 * 1e9 / 3 does not divide either: the floor still exists, it is just a
    // billionth of the one it replaced.
    assert_eq!(pricing::roll_down_to_1e18(ODD_ROLL_DOWN_VALUE, 1, 3), ODD_THIRD_1E18);
}

#[test]
fun roll_down_handles_one_ms_boundary_and_u256_intermediates() {
    let anchor_tte_ms = ROLL_DOWN_EXPIRY_MS - ROLL_DOWN_ANCHOR_MS;

    // u64::MAX * 1e9 * u64::MAX / u64::MAX. The unreduced product is ~1.7e47,
    // three orders past u128, so an exact result here pins the u256 intermediate
    // rather than any bound on the anchored horizon.
    assert_eq!(
        pricing::roll_down_to_1e18(
            std::u64::max_value!(),
            std::u64::max_value!(),
            std::u64::max_value!(),
        ),
        U64_MAX_1E18,
    );

    // 100 * 1e9 * 1 / 100 = 1e9 exactly one millisecond before expiry.
    assert_eq!(
        pricing::roll_down_to_1e18(
            BOUNDARY_ROLL_DOWN_VALUE,
            ONE_MS_ROLL_DOWN_VALUE,
            anchor_tte_ms,
        ),
        ONE_MS_1E18,
    );
}

#[test]
fun rolled_sub_1e9_resolution_reaches_the_variance_pricing_divides_by() {
    // The roll-down above is only worth carrying if it survives into `sqrt(w)`.
    // With `b` halved from 11 to 5.5 and `inner` at one, w is 5.5e9 at 1e18 and
    // isqrt(5_500_000_000) = 74_161. The 1e9 roll-down floored b to 5, giving
    // w = 5e9 and sqrt 70_710 — a 4.7% error on the divisor of d2.
    let (sqrt_var, _d2) = pricing::variance_sqrt_and_d2_for_testing(
        0,
        false,
        ODD_HALVED_1E18,
        UNIT_INNER,
        &i64::from_u64(0),
    );
    assert_eq!(sqrt_var, HALVED_B_SQRT_VAR);
}

/// A retransmission carries the tuple's original model time in a newer envelope, and the envelope
/// is the economic clock: the roll-down re-anchors to the retransmit's publish time — the provider
/// re-asserted the tuple as current there — while the snapshotted source time still reports the
/// model time the data is "as of". Quoted between the retransmit and expiry, the envelope anchor
/// scales the raw surface by 1/2; the old model anchor would have scaled it by 1/4.
#[test]
fun svi_retransmit_reanchors_the_roll_down_and_holds_the_source_time() {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        SHORT_ROLL_DOWN_EXPIRY_MS,
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        RETRANSMITTED_SVI_A,
        false,
        RETRANSMITTED_SVI_B,
        test_constants::default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );

    fx.set_clock_for_testing(SHORT_ROLL_DOWN_MIDPOINT_MS);
    fx.retransmit_bs_svi_for_testing(
        &mut oracle,
        ROLL_DOWN_ANCHOR_MS,
        SHORT_ROLL_DOWN_MIDPOINT_MS,
        RETRANSMITTED_SVI_A,
        false,
        RETRANSMITTED_SVI_B,
        test_constants::default_svi_sigma(),
        ZERO_SVI_SHAPE_PARAM,
        false,
        ZERO_SVI_SHAPE_PARAM,
        false,
    );
    fx.set_clock_for_testing(SHORT_ROLL_DOWN_QUOTE_MS);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        SHORT_ROLL_DOWN_QUOTE_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        SHORT_ROLL_DOWN_QUOTE_MS,
        test_constants::default_live_price(),
    );

    let pricer = fx.load_pricer_bundle(&oracle);
    assert_eq!(pricer.block_scholes_svi_source_timestamp_ms(), ROLL_DOWN_ANCHOR_MS);
    // Quoted at 165_000: remaining 15s over the envelope anchor's 30s horizon
    // scales raw a=2 to effective a=1 and b remains zero. At K=F, positive
    // variance gives d2=-sqrt(1e-9)/2, checked against the generated
    // first-principles reference. Anchoring on the retransmitted tuple's model
    // time instead would scale by 15s/60s and halve the effective variance again.
    test_helpers::assert_within(
        pricer.range_price(
            strike(test_constants::default_live_price()),
            strike(constants::pos_inf!()),
        ),
        ref_data::flat_surface_atm_up(),
        ref_data::flat_surface_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun pricer_snapshots_all_oracle_source_timestamps() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_pyth_bundle(&mut oracle, test_constants::default_live_price(), PYTH_SOURCE_MS);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        BLOCK_SCHOLES_SPOT_SOURCE_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        BLOCK_SCHOLES_FORWARD_SOURCE_MS,
        test_constants::default_live_price(),
    );
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), PYTH_SOURCE_MS);
    assert_eq!(pricer.block_scholes_spot_source_timestamp_ms(), BLOCK_SCHOLES_SPOT_SOURCE_MS);
    assert_eq!(pricer.block_scholes_forward_source_timestamp_ms(), BLOCK_SCHOLES_FORWARD_SOURCE_MS);
    assert_eq!(
        pricer.block_scholes_svi_source_timestamp_ms(),
        test_constants::live_source_timestamp_ms(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun unusable_pyth_observation_uses_zero_timestamp_sentinel() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_pyth_bundle(&mut oracle, UNUSABLE_PYTH_SPOT, UNUSABLE_PYTH_SOURCE_MS);
    let pricer = fx.load_pricer_bundle(&oracle);

    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), NO_USABLE_PYTH_SOURCE_TIMESTAMP_MS);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun complementary_ranges_sum_to_one_at_the_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    let below = pricer.range_price(
        strike(constants::neg_inf!()),
        strike(test_constants::default_live_price()),
    );
    let above = pricer.range_price(
        strike(test_constants::default_live_price()),
        strike(constants::pos_inf!()),
    );

    // Exact: the partition of the real line sums to probability 1.
    assert_eq!(below + above, float!());
    // Non-trivial: a finite at-the-forward strike splits strictly inside (0, 1).
    assert!(above > 0);
    assert!(above < float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun whole_line_range_is_certain() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    let whole = pricer.range_price(
        strike(constants::neg_inf!()),
        strike(constants::pos_inf!()),
    );
    assert_eq!(whole, float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun digital_above_probability_is_non_increasing_in_strike() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    // P(price > X) must be non-increasing as X rises: a higher strike is less
    // likely to be exceeded.
    let above_low = pricer.range_price(strike(STRIKE_BELOW), strike(constants::pos_inf!()));
    let above_high = pricer.range_price(strike(STRIKE_ABOVE), strike(constants::pos_inf!()));
    assert!(above_low >= above_high);
    // And strictly so straddling the forward with this curve.
    assert!(above_low > above_high);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A price Pyth carried forward must not resurrect the live re-anchor. Pyth
/// delivers on a fixed cadence whether or not it has a fresh aggregate; when it
/// has none it re-publishes the previous price under a newer envelope. Keying
/// `latest` on the envelope let that redelivery renew the freshness window for
/// as long as the stall lasted, so pricing re-anchored the Block Scholes forward
/// on a frozen spot (`forward = bs_forward * pyth_spot / bs_spot`). Keying on the
/// generation time makes redelivery a no-op, so the fallback that the staleness
/// boundary below establishes actually holds.
#[test]
fun carried_pyth_price_does_not_resurrect_the_live_reanchor() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Block Scholes spot = forward = 100e9, so basis = 1.0 exactly.
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_pyth_spot_freshness_for_testing(&mut oracle, TIGHT_PYTH_FRESHNESS_MS);
    fx.set_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);

    let pyth_budget = oracle_fixture::config(&oracle).pricing_config().pyth_spot_freshness_ms();

    // Pyth stalls: one ms past the budget the diverged print is stale, so the
    // forward is the stored Block Scholes forward = 100e9.
    let now = DIVERGED_PYTH_SOURCE_MS + pyth_budget + 1;
    fx.set_clock_for_testing(now);
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );
    assert_eq!(pricer.up_price(strike(DIVERGED_PYTH_SPOT)), 0);

    // Pyth still has no fresh aggregate, so it carries the same 102e9 print
    // forward under an envelope stamped at the current clock. Nothing about the
    // observation is newer — only its delivery.
    fx.carry_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS, now);

    // The carried delivery must change nothing: `latest` still ages from the
    // generation time, so the forward stays on the Block Scholes fallback rather
    // than snapping back to the frozen 102e9 re-anchor.
    let pricer = fx.load_pricer_bundle(&oracle);
    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), DIVERGED_PYTH_SOURCE_MS);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );
    assert_eq!(pricer.up_price(strike(DIVERGED_PYTH_SPOT)), 0);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Decision-pinned: `use_pyth_spot_for_forward` selects which source builds the
/// live forward, and the choice is reversible. Nothing about the oracle state or
/// the clock changes across the three loads below — only the admin setting — so
/// the at-the-money strike moving between the 102e9 Pyth anchor and the 100e9
/// Block Scholes forward isolates the formula switch itself. With the switch off
/// a fresh, in-envelope Pyth print is inert for pricing while its provenance is
/// still retained on the `Pricer`.
#[test]
fun use_pyth_spot_for_forward_selects_the_live_forward_source() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Block Scholes spot = forward = 100e9, so basis = 1.0 exactly.
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    // A +2% Pyth print, 500 ms old at the fixture clock: inside the Pyth window
    // and well inside the (longer) Block Scholes one, so the switch is the only
    // thing that can decide the source here.
    fx.set_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);
    assert!(oracle_fixture::config(&oracle).pricing_config().use_pyth_spot_for_forward());

    // Default on: the fresh spot carries the basis, so forward = mul(102e9, 1.0)
    // = 102e9 and the diverged strike is the at-the-money one.
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(DIVERGED_PYTH_SPOT)),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );

    // Off: same oracle rows, same clock, forward = the stored Block Scholes
    // forward = 100e9. The 102e9 strike is now 2% out of the money and prices at
    // zero on this near-zero-variance surface.
    fx.set_use_pyth_spot_for_forward_bundle(&mut oracle, false);
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );
    assert_eq!(pricer.up_price(strike(DIVERGED_PYTH_SPOT)), 0);
    // The spot is out of the forward, not out of the snapshot: trade events still
    // report which Pyth observation was current when the quote was taken.
    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), DIVERGED_PYTH_SOURCE_MS);

    // Back on: the same admin path restores the re-anchor, so the switch is a
    // reversible policy knob and not a one-way migration.
    fx.set_use_pyth_spot_for_forward_bundle(&mut oracle, true);
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(DIVERGED_PYTH_SPOT)),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Decision-pinned: the setting selects Pyth whenever Pyth is independently fresh; it is not a
/// newest-observation chooser. Here both Block Scholes price rows have later model timestamps, but
/// the still-fresh Pyth spot remains the live anchor and carries the 1.0 Block Scholes basis.
#[test]
fun fresh_pyth_remains_selected_when_block_scholes_is_newer() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, PYTH_SOURCE_MS);
    fx.set_bs_spot_for_testing_bundle(
        &mut oracle,
        BLOCK_SCHOLES_SPOT_SOURCE_MS,
        test_constants::default_live_price(),
    );
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        BLOCK_SCHOLES_FORWARD_SOURCE_MS,
        test_constants::default_live_price(),
    );

    let pricer = fx.load_pricer_bundle(&oracle);
    assert!(
        pricer.pyth_spot_source_timestamp_ms() < pricer.block_scholes_spot_source_timestamp_ms(),
    );
    test_helpers::assert_within(
        pricer.up_price(strike(DIVERGED_PYTH_SPOT)),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Decision-pinned: the live forward switches source exactly at the Pyth
/// staleness boundary (`pricing::load_live_pricer`, fallback documented in-code).
/// While Pyth is fresh — inclusive: `now − freshness_ts == max_age` — the
/// forward is `mul(pyth_spot, basis)`; one millisecond later, with ZERO
/// oracle-data change, it is the stored Block Scholes forward. With a +2%
/// diverged Pyth print the mark therefore jumps 2% discontinuously on a 1 ms
/// clock advance — accepted behavior, pinned so any future smoothing
/// (blending, hysteresis) is an explicit decision.
#[test]
fun live_forward_switches_source_exactly_at_pyth_staleness_boundary() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    // Block Scholes spot = forward = 100e9, so basis = div(100e9, 100e9) = 1.0
    // exactly.
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    fx.set_pyth_spot_freshness_for_testing(&mut oracle, TIGHT_PYTH_FRESHNESS_MS);
    // Overwrite only the Pyth print with the diverged spot at a strictly-newer
    // source timestamp (freshness uses min(source, update) = 99_500).
    fx.set_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);

    // The stale-Pyth/fresh-Block-Scholes window exists because the test tightens
    // the Pyth budget strictly below the BS price budget.
    let pyth_budget = oracle_fixture::config(&oracle).pricing_config().pyth_spot_freshness_ms();
    assert!(
        pyth_budget
            < oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms(),
    );

    // AT the boundary (now − 99_500 == budget): Pyth is fresh (inclusive), so
    // forward = mul(102e9, 1.0) = floor(102e9 * 1e9 / 1e9) = 102e9 exactly.
    fx.set_clock_for_testing(DIVERGED_PYTH_SOURCE_MS + pyth_budget);
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(DIVERGED_PYTH_SPOT)),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );

    // ONE ms past the boundary: Pyth is stale, the BS surface still fresh, so the
    // forward falls back to the stored Block Scholes forward = 100e9.
    fx.set_clock_for_testing(DIVERGED_PYTH_SOURCE_MS + pyth_budget + 1);
    let pricer = fx.load_pricer_bundle(&oracle);
    test_helpers::assert_within(
        pricer.up_price(strike(test_constants::default_live_price())),
        AT_THE_FORWARD_UP,
        AT_THE_FORWARD_UP_BUDGET,
    );
    assert_eq!(pricer.up_price(strike(DIVERGED_PYTH_SPOT)), 0);
    assert_eq!(pricer.pyth_spot_source_timestamp_ms(), DIVERGED_PYTH_SOURCE_MS);

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
