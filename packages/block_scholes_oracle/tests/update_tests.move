// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module block_scholes_oracle::update_tests;

use block_scholes_oracle::update;
use std::unit_test::assert_eq;

// Independent fixture values (1e9-scaled where they represent prices/params).
const SOURCE_ID: u32 = 1;
const EXPIRY_MS: u64 = 1_700_100_000_000;
const PUBLISHED_AT_MS: u64 = 1_700_000_000_000;
const SPOT: u64 = 65_000_000_000_000;
const FORWARD: u64 = 65_100_000_000_000;
const SVI_A_MAG: u64 = 40_000_000;
const SVI_A_NEG: bool = true;
const SVI_B: u64 = 120_000_000;
const SVI_SIGMA: u64 = 90_000_000;
const RHO_MAG: u64 = 300_000_000;
const RHO_NEG: bool = true;
const M_MAG: u64 = 25_000_000;
const M_NEG: bool = false;

#[test]
fun spot_update_getters_round_trip_inputs() {
    let upd = update::new_spot_update(SOURCE_ID, PUBLISHED_AT_MS, SPOT);

    assert_eq!(upd.spot_source_id(), SOURCE_ID);
    assert_eq!(upd.spot_published_at_ms(), PUBLISHED_AT_MS);
    assert_eq!(upd.spot(), SPOT);
}

#[test]
fun forward_update_getters_round_trip_inputs() {
    let upd = update::new_forward_update(SOURCE_ID, EXPIRY_MS, PUBLISHED_AT_MS, FORWARD);

    assert_eq!(upd.forward_source_id(), SOURCE_ID);
    assert_eq!(upd.forward_expiry_ms(), EXPIRY_MS);
    assert_eq!(upd.forward_published_at_ms(), PUBLISHED_AT_MS);
    assert_eq!(upd.forward(), FORWARD);
}

#[test]
fun svi_update_getters_round_trip_inputs() {
    let upd = update::new_svi_update(
        SOURCE_ID,
        EXPIRY_MS,
        PUBLISHED_AT_MS,
        SVI_A_MAG,
        SVI_A_NEG,
        SVI_B,
        SVI_SIGMA,
        RHO_MAG,
        RHO_NEG,
        M_MAG,
        M_NEG,
    );

    assert_eq!(upd.svi_source_id(), SOURCE_ID);
    assert_eq!(upd.svi_expiry_ms(), EXPIRY_MS);
    assert_eq!(upd.svi_published_at_ms(), PUBLISHED_AT_MS);
    assert_eq!(upd.svi_a_magnitude(), SVI_A_MAG);
    assert_eq!(upd.svi_a_is_negative(), SVI_A_NEG);
    assert_eq!(upd.svi_b(), SVI_B);
    assert_eq!(upd.svi_sigma(), SVI_SIGMA);
    assert_eq!(upd.svi_rho_magnitude(), RHO_MAG);
    assert_eq!(upd.svi_rho_is_negative(), RHO_NEG);
    assert_eq!(upd.svi_m_magnitude(), M_MAG);
    assert_eq!(upd.svi_m_is_negative(), M_NEG);
}
