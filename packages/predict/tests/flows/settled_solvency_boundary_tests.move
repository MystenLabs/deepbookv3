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
