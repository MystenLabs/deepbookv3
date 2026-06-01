// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_basis_tests;

use deepbook_predict::{admin, market_oracle};

const EXPIRY_MS: u64 = 100_000;

#[test, expected_failure(abort_code = market_oracle::EZeroSpot)]
fun basis_aborts_when_spot_zero() {
    // Fresh market has block_scholes_spot = 0; basis() guards against
    // division-by-zero before forward is even read.
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    let _ = market.block_scholes_basis();
    abort 999
}

// Exercising EZeroForward and the basis-computation happy path requires
// driving block_scholes_spot/forward through update_block_scholes_prices,
// which needs a matched PythSource. Those paths are covered in
// market_oracle_update_prices_tests.move.
