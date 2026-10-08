// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `pricing::load_vol_snapshot`, the volatility read a queued order takes at enqueue.
///
/// The snapshot must hold exactly the raw inputs the oracle holds (narrowed, not
/// rolled down), with the canonical Pyth source, and its t₀ Pricer must be the live
/// pricer at the same instant. A stale or unusable Pyth spot must not abort: the t₀
/// Pricer falls back to the Block Scholes forward. Every abort the load can raise is
/// pinned below with a production-valid fixture.
///
/// "SVI source time before expiry" has no test of its own because no reachable SVI
/// violates it: the live SVI window requires the source to be at or before now, and
/// the load requires now before expiry.
#[test_only]
module deepbook_predict::vol_snapshot_tests;

use bs_oracle::verify;
use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing,
    pricing_reference_data as ref_data,
    protocol_config::ProtocolConfig,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers,
    vol_snapshot_test_helpers::{Self as helpers, load_snapshot}
};
use fixed_math::i64;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use std::unit_test::assert_eq;
use sui::{clock, test_scenario::return_shared};

const EUnexpectedSuccess: u64 = 999;

/// A surface whose every SVI field differs and whose signed fields are negative, so a
/// swapped or sign-dropped field in the snapshot cannot match. Pricing-safe: the
/// minimum SVI increment is `b * sigma * sqrt(1 - rho^2)` = 1e-5 * 1e-3 * 0.866 = 8.66e-9,
/// which floors to 8 raw units and clears `a = -5` raw units.
const SNAPSHOT_SVI_A_MAGNITUDE: u64 = 5;
const SNAPSHOT_SVI_B: u64 = 10_000;
const SNAPSHOT_SVI_SIGMA: u64 = 1_000_000;
const SNAPSHOT_SVI_RHO_MAGNITUDE: u64 = 500_000_000;
const SNAPSHOT_SVI_M_MAGNITUDE: u64 = 2_000_000;
/// Block Scholes forward at basis 1.005 over the default 100e9 spot.
const SNAPSHOT_BS_FORWARD: u64 = 100_500_000_000;

/// A Pyth source on the underlying after the fixture rebinds it.
const REBOUND_PYTH_SOURCE_ID: u32 = 2;
/// A real underlying whose Block Scholes stores are not this market's.
const FOREIGN_UNDERLYING_ID: u32 = 2;

/// A Pyth print diverged +2% from the 100e9 Block Scholes spot and forward, one
/// millisecond newer than the bootstrap tick so the feed accepts it.
const DIVERGED_PYTH_SPOT: u64 = 102_000_000_000;
const DIVERGED_PYTH_SOURCE_MS: u64 = 119_001;
/// A Pyth window shorter than the 999 ms age of the diverged print at the 120_000
/// fixture clock, while the Block Scholes prices (age 1_000, window 2_000) stay fresh.
const TIGHT_PYTH_FRESHNESS_MS: u64 = 500;
/// A strictly newer Pyth row whose zero price has no normalized spot.
const UNUSABLE_PYTH_SPOT: u64 = 0;
const NO_USABLE_PYTH_SOURCE_TIMESTAMP_MS: u64 = 0;

/// `prepare_live_oracle` seeds the SVI at 119_000 and the fixture clock is 120_000,
/// so the tuple is exactly 1_000 ms old at the load.
const LIVE_SVI_AGE_MS: u64 = 1_000;
/// Block Scholes source for the same-transaction spot write.
const SAME_TX_SOURCE_MS: u64 = 119_002;
/// The first provider-native magnitude Predict's u64 pricing domain cannot hold.
const FIRST_UNREPRESENTABLE_U64: u128 = 18_446_744_073_709_551_616;
/// u64::MAX / 100, Predict's pricing-safe spot ceiling.
const MAX_PRICING_SPOT: u64 = 184_467_440_737_095_516;

// === Captured inputs ===

#[test]
fun snapshot_stores_the_seeded_raw_inputs() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        SNAPSHOT_BS_FORWARD,
        SNAPSHOT_SVI_A_MAGNITUDE,
        true,
        SNAPSHOT_SVI_B,
        SNAPSHOT_SVI_SIGMA,
        SNAPSHOT_SVI_RHO_MAGNITUDE,
        true,
        SNAPSHOT_SVI_M_MAGNITUDE,
        true,
    );

    let (snapshot, t0_pricer) = load_snapshot(
        &mut fx,
        &oracle,
        helpers::default_svi_max_age_ms(),
    );

    assert_eq!(snapshot.pyth_source_id(), test_constants::pyth_feed_id());
    assert_eq!(snapshot.bs_spot(), test_constants::default_live_price());
    assert_eq!(snapshot.bs_forward(), SNAPSHOT_BS_FORWARD);
    // Raw, not rolled down: the stored `a` and `b` are the seeded 1e9 values.
    assert_eq!(snapshot.svi_a(), i64::from_parts(SNAPSHOT_SVI_A_MAGNITUDE, true));
    assert_eq!(snapshot.svi_b(), SNAPSHOT_SVI_B);
    assert_eq!(snapshot.svi_rho(), i64::from_parts(SNAPSHOT_SVI_RHO_MAGNITUDE, true));
    assert_eq!(snapshot.svi_m(), i64::from_parts(SNAPSHOT_SVI_M_MAGNITUDE, true));
    assert_eq!(snapshot.svi_sigma(), SNAPSHOT_SVI_SIGMA);
    // `prepare_real_oracle` stamps spot and forward at the live source time and the SVI
    // at the fixture clock.
    assert_eq!(snapshot.bs_spot_source_timestamp_ms(), test_constants::live_source_timestamp_ms());
    assert_eq!(
        snapshot.bs_forward_source_timestamp_ms(),
        test_constants::live_source_timestamp_ms(),
    );
    assert_eq!(snapshot.svi_source_timestamp_ms(), test_constants::now_ms());

    // The t₀ Pricer is the live pricer at the same instant and inputs.
    assert_eq!(t0_pricer, fx.load_pricer_bundle(&oracle));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// The stored Pyth source is the underlying's current binding, not a fixed id: after
/// Propbook rebinds the underlying, a snapshot records the new feed's source.
#[test]
fun snapshot_takes_the_pyth_source_from_the_current_binding() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_PYTH_SOURCE_ID);
    let mut oracle = fx.take_oracle_bundle_by_ids(rebound_ids);
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());

    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());

    assert_eq!(snapshot.pyth_source_id(), REBOUND_PYTH_SOURCE_ID);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === Pyth fallback ===

/// A stale Pyth spot does not abort the load. The t₀ Pricer keeps the stale print's
/// source timestamp for provenance and prices on the Block Scholes forward, which is
/// the same Pricer as re-anchoring on the Block Scholes spot itself
/// (`bs_spot * bs_forward / bs_spot` is exact). Re-anchoring on the diverged 102e9
/// print instead would put the 100e9 strike 2% in the money on a ~3e-5 sqrt(w)
/// surface, far outside the at-the-forward reference band.
#[test]
fun stale_pyth_spot_falls_back_to_the_block_scholes_forward() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_pyth_spot_freshness_for_testing(&mut oracle, TIGHT_PYTH_FRESHNESS_MS);
    fx.set_pyth_bundle(&mut oracle, DIVERGED_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);

    let (snapshot, t0_pricer) = load_snapshot(
        &mut fx,
        &oracle,
        helpers::default_svi_max_age_ms(),
    );

    assert_eq!(t0_pricer.pyth_spot_source_timestamp_ms(), DIVERGED_PYTH_SOURCE_MS);
    let on_block_scholes_forward = pricing::pricer_at(
        &snapshot,
        snapshot.bs_spot(),
        DIVERGED_PYTH_SOURCE_MS,
        test_constants::now_ms(),
        fx.expiry_id(),
        fx.expiry(),
    );
    assert_eq!(t0_pricer, on_block_scholes_forward.destroy_some());
    test_helpers::assert_within(
        t0_pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::flow_fixture_atm_up(),
        ref_data::flow_fixture_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A Pyth row with no normalized spot does not abort the load either; the t₀ Pricer
/// records the `0` sentinel and prices on the Block Scholes forward.
#[test]
fun unusable_pyth_spot_falls_back_with_the_zero_sentinel() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_pyth_bundle(&mut oracle, UNUSABLE_PYTH_SPOT, DIVERGED_PYTH_SOURCE_MS);

    let (_, t0_pricer) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());

    assert_eq!(t0_pricer.pyth_spot_source_timestamp_ms(), NO_USABLE_PYTH_SOURCE_TIMESTAMP_MS);
    test_helpers::assert_within(
        t0_pricer.up_price(strike(test_constants::default_live_price())),
        ref_data::flow_fixture_atm_up(),
        ref_data::flow_fixture_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === SVI age bound ===

/// The policy bound is inclusive: an SVI exactly `svi_max_age_ms` old loads.
#[test]
fun svi_exactly_at_the_max_age_loads() {
    let (mut fx, oracle) = setup_live();

    let (snapshot, _) = load_snapshot(&mut fx, &oracle, LIVE_SVI_AGE_MS);

    assert_eq!(snapshot.svi_source_timestamp_ms(), test_constants::live_source_timestamp_ms());
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// One millisecond tighter than the SVI's age aborts, though the live SVI window
/// (60 s) would accept it.
#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun svi_one_ms_past_the_max_age_aborts() {
    let (mut fx, oracle) = setup_live();
    let (_, _) = load_snapshot(&mut fx, &oracle, LIVE_SVI_AGE_MS - 1);
    abort EUnexpectedSuccess
}

/// The live SVI window still applies when the policy bound is looser: at the 120 s
/// policy maximum, an SVI one millisecond past the 60 s live window aborts.
#[test, expected_failure(abort_code = pricing::EBlockScholesSVIStale)]
fun svi_past_the_live_window_aborts_under_a_looser_policy_bound() {
    let (mut fx, mut oracle) = setup_live();
    let svi_window_ms = oracle_fixture::config(&oracle)
        .pricing_config()
        .block_scholes_svi_freshness_ms();
    let now = test_constants::live_source_timestamp_ms() + svi_window_ms + 1;
    fx.set_clock_for_testing(now);
    fx.set_bs_spot_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());

    let (_, _) = load_snapshot(&mut fx, &oracle, config_max_svi_max_age_ms());
    abort EUnexpectedSuccess
}

// === Gate and binding aborts ===

#[test, expected_failure(abort_code = pricing::EPythForwardRequired)]
fun pyth_forward_switch_off_aborts() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_use_pyth_spot_for_forward_bundle(&mut oracle, false);
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::ELivePricingExpired)]
fun load_at_expiry_aborts() {
    let (mut fx, oracle) = setup_live();
    let expiry = fx.expiry();
    fx.set_clock_for_testing(expiry);
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun old_pyth_feed_after_a_rebind_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let _rebound_ids = fx.create_and_rebind_oracle(REBOUND_PYTH_SOURCE_ID);
    let oracle = fx.take_oracle_bundle();
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesValueStore)]
fun another_underlyings_value_store_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let foreign_pair = fx.create_foreign_block_scholes_stores(FOREIGN_UNDERLYING_ID);
    let foreign_values_id = foreign_pair.block_scholes_value_store_id();

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let foreign_values = fx
        .scenario_mut()
        .take_shared_by_id<BlockScholesValueStore>(foreign_values_id);
    let (_, _) = helpers::load_snapshot_with_stores(
        &mut fx,
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        &foreign_values,
        oracle_fixture::bs(&oracle).svi(),
        helpers::default_svi_max_age_ms(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongBlockScholesSVIStore)]
fun another_underlyings_svi_store_aborts() {
    let (mut fx, oracle) = setup_live();
    oracle_fixture::return_oracle_bundle(oracle);
    let foreign_pair = fx.create_foreign_block_scholes_stores(FOREIGN_UNDERLYING_ID);
    let foreign_svi_id = foreign_pair.block_scholes_svi_store_id();

    fx.scenario_mut().next_tx(test_constants::admin());
    let oracle = fx.take_oracle_bundle();
    let foreign_svi = fx.scenario_mut().take_shared_by_id<BlockScholesSVIStore>(foreign_svi_id);
    let (_, _) = helpers::load_snapshot_with_stores(
        &mut fx,
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        oracle_fixture::bs(&oracle).values(),
        &foreign_svi,
        helpers::default_svi_max_age_ms(),
    );
    abort EUnexpectedSuccess
}

/// RP-24: the spot the forward pairs with was written in this transaction.
#[test, expected_failure(abort_code = pricing::EOracleWrittenInThisTransaction)]
fun spot_written_in_this_transaction_aborts() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_bs_forward_for_testing_bundle(
        &mut oracle,
        SAME_TX_SOURCE_MS,
        test_constants::default_live_price(),
    );
    oracle_fixture::return_oracle_bundle(oracle);
    fx.scenario_mut().next_tx(test_constants::admin());

    load_after_spot_write_in_current_transaction(&mut fx);
    abort EUnexpectedSuccess
}

// === Read and envelope aborts ===

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceUnavailable)]
fun missing_block_scholes_price_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesPriceStale)]
fun stale_block_scholes_price_aborts() {
    let (mut fx, oracle) = setup_live();
    let stale_now =
        test_constants::live_source_timestamp_ms()
        + oracle_fixture::config(&oracle).pricing_config().block_scholes_price_freshness_ms()
        + 1;
    fx.set_clock_for_testing(stale_now);
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesSVIUnavailable)]
fun missing_svi_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let now = test_constants::live_source_timestamp_ms();
    fx.set_bs_spot_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    fx.set_bs_forward_for_testing_bundle(&mut oracle, now, test_constants::default_live_price());
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EBlockScholesInputTooWide)]
fun block_scholes_spot_above_u64_aborts() {
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
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

/// `b` one raw unit above the pricing-safe ceiling of 100.
#[test, expected_failure(abort_code = pricing::EBlockScholesInputsInvalid)]
fun svi_b_above_the_pricing_safe_ceiling_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        test_constants::default_svi_a(),
        false,
        test_constants::pricing_max_svi_input() + 1,
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

/// `a == 0, b == 0` has zero minimum total variance.
#[test, expected_failure(abort_code = pricing::EBlockScholesMinVarianceInvalid)]
fun zero_minimum_variance_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        0,
        false,
        0,
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

/// A fresh Pyth print above the pricing-safe spot ceiling cannot re-anchor the t₀ forward.
#[test, expected_failure(abort_code = pricing::EPythSpotInvalid)]
fun fresh_pyth_spot_above_the_ceiling_aborts() {
    let (mut fx, mut oracle) = setup_live();
    fx.set_pyth_bundle(&mut oracle, MAX_PRICING_SPOT + 1, DIVERGED_PYTH_SOURCE_MS);
    let (_, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    abort EUnexpectedSuccess
}

// === Helpers ===

fun config_max_svi_max_age_ms(): u64 { constants::max_svi_max_age_ms!() }

/// The default live oracle: Pyth, Block Scholes spot and forward at 100e9 sourced at
/// 119_000, the default surface sourced at 119_000, fixture clock 120_000.
fun setup_live(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle)
}

/// Write the Block Scholes spot at `SAME_TX_SOURCE_MS` in the current transaction,
/// then load a snapshot in that same transaction.
fun load_after_spot_write_in_current_transaction(fx: &mut OracleFixture) {
    let values_id = fx.bs_values_id();
    let mut values = fx.scenario_mut().take_shared_by_id<BlockScholesValueStore>(values_id);
    let batch = verify::new_value_batch_for_testing(
        SAME_TX_SOURCE_MS,
        vector[
            verify::new_value_update_for_testing(
                values.spot_sid(),
                SAME_TX_SOURCE_MS,
                (test_constants::default_live_price() as u128),
            ),
        ],
    );
    let mut chain_clock = clock::create_for_testing(fx.scenario_mut().ctx());
    chain_clock.set_for_testing(test_constants::now_ms());
    values.apply_spot_batch(batch, &chain_clock, fx.scenario_mut().ctx());
    chain_clock.destroy_for_testing();

    let pyth_id = fx.pyth_id();
    let svi_id = fx.bs_svi_id();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(pyth_id);
    let svi = fx.scenario_mut().take_shared_by_id<BlockScholesSVIStore>(svi_id);
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let (_, _) = helpers::load_snapshot_with_stores(
        fx,
        &config,
        &registry,
        &pyth,
        &values,
        &svi,
        helpers::default_svi_max_age_ms(),
    );
    return_shared(registry);
    return_shared(config);
    return_shared(svi);
    return_shared(pyth);
    return_shared(values);
}
