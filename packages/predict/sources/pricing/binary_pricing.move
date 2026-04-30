// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fair binary pricing over canonical oracle snapshots.
///
/// This module prices UP tails and vertical ranges from already-selected
/// canonical oracle values. It does not choose oracle sources, apply spread or
/// fees, enforce market lifecycle, or settle expired markets.
module deepbook_predict::binary_pricing;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    block_scholes_source,
    constants,
    i64,
    math as predict_math,
    meta_oracle::CanonicalSnapshot
};

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const EZeroVariance: u64 = 2;
const EInvalidRange: u64 = 3;
const ERangePriceUnderflow: u64 = 4;
const ESVISqrtInputOverflow: u64 = 5;
const ETotalVarianceOverflow: u64 = 6;

// === Public-Package Functions ===

/// Compute the fair UP tail price for `strike`.
public(package) fun compute_up_price(snapshot: &CanonicalSnapshot, strike: u64): u64 {
    if (strike == constants::neg_inf!()) {
        return constants::float_scaling!()
    };
    if (strike == constants::pos_inf!()) {
        return 0
    };

    compute_nd2(snapshot, strike)
}

/// Compute the fair price for the range `(lower, higher]`.
public(package) fun compute_range_price(
    snapshot: &CanonicalSnapshot,
    lower: u64,
    higher: u64,
): u64 {
    assert!(lower < higher, EInvalidRange);

    let lower_up_price = compute_up_price(snapshot, lower);
    let higher_up_price = compute_up_price(snapshot, higher);
    assert!(lower_up_price >= higher_up_price, ERangePriceUnderflow);

    lower_up_price - higher_up_price
}

// === Private Functions ===

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
fun compute_nd2(snapshot: &CanonicalSnapshot, strike: u64): u64 {
    let forward = snapshot.forward();
    assert!(forward > 0, EZeroForward);

    let svi = snapshot.svi();

    let k = predict_math::ln(math::div(strike, forward));
    let m = block_scholes_source::svi_m(&svi);
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = block_scholes_source::svi_sigma(&svi);
    let sigma_squared = math::mul(sigma, sigma);
    assert!(k_minus_m_squared <= max_u64() - sigma_squared, ESVISqrtInputOverflow);
    let sqrt_input = k_minus_m_squared + sigma_squared;
    let sq = predict_math::sqrt(sqrt_input, constants::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho = block_scholes_source::svi_rho(&svi);
    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    assert!(!inner.is_negative(), ECannotBeNegative);

    let a = block_scholes_source::svi_a(&svi);
    let b = block_scholes_source::svi_b(&svi);
    let wing_var = math::mul(b, inner.magnitude());
    assert!(a <= max_u64() - wing_var, ETotalVarianceOverflow);
    let total_var = a + wing_var;
    assert!(total_var > 0, EZeroVariance);

    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = k.add(&half_var_i64);
    let d2 = d2_numerator.div_scaled(&sqrt_var_i64);
    let d2 = d2.neg();

    predict_math::normal_cdf(&d2)
}
