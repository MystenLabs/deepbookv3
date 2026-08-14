// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S1/L1 live-solvency boundary for a thin FINITE-range 1x order: minted on the
/// first admitted finite range above min_strike exactly at the money, then partially closed
/// live. Pins that the close removes the order's entire live terms and reinserts
/// the exact residual (cancel-and-replace) so liability drops to the surviving
/// half, that the survivor carries zero floor (a 1x order), and that custody
/// conserves across the market-cash / account sheets with S1 backing intact.
///
/// The settled-redeem boundary legs are covered by the explicit settlement flow
/// tests; this file keeps the live cancel-and-replace solvency boundary focused.
#[test_only]
module deepbook_predict::settled_solvency_boundary_tests;

use deepbook_predict::{flow_test_helpers as helpers, order, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;

/// Per-trade fee floors at `min_fee`: the fixture floors base_fee to 1, so the
/// raw Bernoulli fee mul(1, sqrt(0.5 * 0.5)) rounds to 0 and the floor binds.
/// The default expiry-fee ramp multiplier is exactly 1.0 (ramp disabled).
const MINT_MIN_FEE: u64 = 5_000_000;
/// The order is the first admitted finite range above min_strike and the live
/// forward == min_strike, so it is exactly at the money and the upper tail clamps
/// to 0 (|d2| ≈ 315σ, far past the Φ clamp at 8σ). A 1x order fronts its full
/// premium, read from the quote; the close payout is measured from the manager's
/// balance and cross-checked against the market's cash, which is what solvency
/// preservation actually asserts. `pricing_exact_tests` owns the price itself.
/// Half the minted quantity (a whole number of 10_000-unit lots).
const HALF_CLOSE: u64 = 500_000_000;
/// Live close fee on the closed slice: 5e6 * 5e8 / 1e9 (fee basis is the
/// closed quantity, not the original order quantity).
const CLOSE_FEE: u64 = 2_500_000;
/// Rebate reserve = floor(cumulative fees * 0.5 default rebate rate):
/// after the mint floor(5e6 * 0.5), after the close floor(7.5e6 * 0.5).
const REBATE_AFTER_MINT: u64 = 2_500_000;
const REBATE_AFTER_CLOSE: u64 = 3_750_000;

