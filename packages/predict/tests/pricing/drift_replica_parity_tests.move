// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PARITY pin (not correctness coverage): bit-exact agreement between the
/// chain's `drift_envelope`/`up_price` and the DBU-557 measurement replica.
///
/// The expected values here are the measurement replica's own outputs
/// (predict-research `scripts/drift_replica.py`, a deliberate fixed-point
/// parity model of pricing.move; generator `scripts/drift_fixture_gen.py`).
/// Per the unit-test rules that makes this a two-sided consistency contract,
/// NOT an independent correctness oracle: if pricing.move were wrong, both
/// sides would agree on the wrong number. Correctness is owned elsewhere —
/// `pricing_exact_tests` pins prices against an independent erf reference,
/// and the envelope's soundness claim is validated empirically by the
/// DBU-557 measurement (envelope >= realized sup over historical oracle
/// pairs). What THIS file guarantees: the off-chain measurement computes
/// exactly what the chain computes (the M0 fidelity gate — without it the
/// measurement's conclusions would be about the replica, not the contract),
/// and any future pricing.move change that shifts a covered value breaks
/// loudly, flagging that the measurement fixture must be regenerated.
///
/// Each vector seeds its two oracle snapshots through the production ingest
/// (`prepare_real_oracle_bundle`, driving the fresh-Pyth forward round-trip),
/// loads real `Pricer`s, and asserts exact equality. Coverage: the zero
/// early-out, every reachable fail-closed reason (variance floor, forward
/// ratio guards, decay/band degeneracies incl. the round-down band collapse),
/// real captured SVI surfaces under perturbation ladders, one-ulp parameter
/// deltas, and wing/grid strikes.
#[test_only]
module deepbook_predict::drift_replica_parity_tests;

use deepbook_predict::{drift_reference_data as ref_data, oracle_fixture, pricing, test_constants};
use propbook::block_scholes_svi_feed::SVIParams;
use std::unit_test::assert_eq;

/// Seed one snapshot's oracle values through the real ingest paths at an
/// explicit source timestamp (the oracle lanes keep the newest source
/// timestamp, so seeding two snapshots requires advancing it) and return the
/// loaded pricer's forward, SVI params, and the UP price at `strike` (0 when
/// the vector's surface cannot price).
fun snapshot(
    fx: &mut oracle_fixture::OracleFixture,
    oracle: &mut oracle_fixture::OracleBundle,
    source_ts_ms: u64,
    spot: u64,
    bs_forward: u64,
    a: u64,
    b: u64,
    sigma: u64,
    rho_mag: u64,
    rho_neg: bool,
    m_mag: u64,
    m_neg: bool,
    strike: u64,
    price: bool,
): (u64, SVIParams, u64) {
    fx.set_pyth_bundle(oracle, spot, source_ts_ms);
    fx.set_bs_spot_for_testing_bundle(oracle, source_ts_ms, spot);
    fx.set_bs_forward_for_testing_bundle(oracle, source_ts_ms, bs_forward);
    fx.set_bs_svi_for_testing_bundle(
        oracle,
        source_ts_ms,
        a,
        b,
        sigma,
        rho_mag,
        rho_neg,
        m_mag,
        m_neg,
    );
    let pricer = fx.load_pricer_bundle(oracle);
    let up = if (price) pricer.up_price(strike) else 0;
    (pricer.forward(), pricer.svi_params(), up)
}

fun run_range(start: u64, end: u64) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let vectors = ref_data::vectors();
    let stop = end.min(vectors.length());
    let base_ts = test_constants::live_source_timestamp_ms();
    let mut i = start;
    while (i < stop) {
        let v = &vectors[i];
        let (forward0, svi0, up0) = snapshot(
            &mut fx,
            &mut oracle,
            base_ts + 2 * (i - start),
            v.spot0(),
            v.bs_forward0(),
            v.a0(),
            v.b0(),
            v.sigma0(),
            v.rho0_mag(),
            v.rho0_neg(),
            v.m0_mag(),
            v.m0_neg(),
            v.strike(),
            v.has_price(),
        );
        let (forward1, svi1, up1) = snapshot(
            &mut fx,
            &mut oracle,
            base_ts + 2 * (i - start) + 1,
            v.spot1(),
            v.bs_forward1(),
            v.a1(),
            v.b1(),
            v.sigma1(),
            v.rho1_mag(),
            v.rho1_neg(),
            v.m1_mag(),
            v.m1_neg(),
            v.strike(),
            v.has_price(),
        );
        assert_eq!(forward0, v.forward0());
        assert_eq!(forward1, v.forward1());
        let live = pricing::from_anchors(
            sui::object::id_from_address(@0xD41F7),
            forward1,
            svi1,
        );
        assert_eq!(live.drift_envelope(forward0, &svi0), v.envelope());
        if (v.has_price()) {
            assert_eq!(up0, v.up0());
            assert_eq!(up1, v.up1());
        };
        i = i + 1;
    };
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun drift_vectors_00_09() { run_range(0, 10) }

#[test]
fun drift_vectors_10_19() { run_range(10, 20) }

#[test]
fun drift_vectors_20_29() { run_range(20, 30) }

#[test]
fun drift_vectors_30_39() { run_range(30, 40) }

#[test]
fun drift_vectors_40_49() { run_range(40, 50) }

#[test]
fun drift_vectors_50_59() { run_range(50, 60) }

#[test]
fun drift_vectors_60_69() { run_range(60, 70) }

#[test]
fun drift_vectors_70_79() { run_range(70, 80) }

#[test]
fun drift_vectors_80_end() { run_range(80, 1000) }
