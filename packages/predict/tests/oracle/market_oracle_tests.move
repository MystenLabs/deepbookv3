// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_tests;

use deepbook_predict::{constants, market_oracle};
use predict_math::{i64, math::float_scaling as float};
use std::unit_test::assert_eq;

const VALID_A: u64 = 0;
const VALID_B: u64 = 500_000_000; // 0.5 in 1e9 fixed-point.
const VALID_SIGMA: u64 = 1_000_000_000; // 1.0 in 1e9 fixed-point.
const ZERO_RHO_MAGNITUDE: u64 = 0;
const POSITIVE_RHO_SIGN: bool = false;
const NEGATIVE_RHO_SIGN: bool = true;
const ONE_ULP: u64 = 1;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = market_oracle::EInvalidSviB)]
fun assert_valid_svi_rejects_b_below_min() {
    let svi = new_svi(
        constants::svi_b_min!() - ONE_ULP,
        ZERO_RHO_MAGNITUDE,
        POSITIVE_RHO_SIGN,
        VALID_SIGMA,
    );
    market_oracle::assert_valid_svi(&svi);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EInvalidSviB)]
fun assert_valid_svi_rejects_b_above_max() {
    let svi = new_svi(
        constants::svi_b_max!() + ONE_ULP,
        ZERO_RHO_MAGNITUDE,
        POSITIVE_RHO_SIGN,
        VALID_SIGMA,
    );
    market_oracle::assert_valid_svi(&svi);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EInvalidSviRho)]
fun assert_valid_svi_rejects_rho_magnitude_above_one() {
    let svi = new_svi(VALID_B, float!() + ONE_ULP, POSITIVE_RHO_SIGN, VALID_SIGMA);
    market_oracle::assert_valid_svi(&svi);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EInvalidSviSigma)]
fun assert_valid_svi_rejects_sigma_below_min() {
    let svi = new_svi(
        VALID_B,
        ZERO_RHO_MAGNITUDE,
        POSITIVE_RHO_SIGN,
        constants::svi_sigma_min!() - ONE_ULP,
    );
    market_oracle::assert_valid_svi(&svi);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_oracle::EInvalidSviSigma)]
fun assert_valid_svi_rejects_sigma_above_max() {
    let svi = new_svi(
        VALID_B,
        ZERO_RHO_MAGNITUDE,
        POSITIVE_RHO_SIGN,
        constants::svi_sigma_max!() + ONE_ULP,
    );
    market_oracle::assert_valid_svi(&svi);
    abort EUnexpectedSuccess
}

#[test]
fun assert_valid_svi_accepts_in_bounds_positive_rho_boundary() {
    let svi = new_svi(VALID_B, float!(), POSITIVE_RHO_SIGN, VALID_SIGMA);
    market_oracle::assert_valid_svi(&svi);
    assert_eq!(svi.rho().magnitude(), float!());
}

#[test]
fun assert_valid_svi_accepts_in_bounds_negative_rho_boundary() {
    let svi = new_svi(VALID_B, float!(), NEGATIVE_RHO_SIGN, VALID_SIGMA);
    market_oracle::assert_valid_svi(&svi);
    assert_eq!(svi.rho().magnitude(), float!());
}

fun new_svi(
    b: u64,
    rho_magnitude: u64,
    rho_is_negative: bool,
    sigma: u64,
): market_oracle::SVIParams {
    market_oracle::new_svi_params(
        VALID_A,
        b,
        i64::from_parts(rho_magnitude, rho_is_negative),
        i64::zero(),
        sigma,
    )
}
