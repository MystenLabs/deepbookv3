// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Math module - mathematical utilities for pricing.
///
/// Fixed-point arithmetic:
/// - mul(a, b) - multiply two scaled values
/// - div(a, b) - divide two scaled values
/// - mul_div(a, b, c) - (a * b) / c with intermediate precision
///
/// Exponential and logarithm (for Black-Scholes):
/// - exp(x) - e^x approximation for scaled x
/// - ln(x) - natural log approximation for scaled x
/// - pow(base, exp) - base^exp
///
/// Normal distribution (for Black-Scholes):
/// - norm_cdf(x) - cumulative distribution function N(x)
/// - norm_pdf(x) - probability density function N'(x)
///
/// Square root:
/// - sqrt(x) - integer square root
///
/// Implementation notes:
/// - All functions use fixed-point arithmetic with FLOAT_SCALING
/// - Approximations are used for exp/ln/norm_cdf (no floating point in Move)
/// - Accuracy is sufficient for pricing (within 0.1% of reference implementations)
///
/// The normal CDF is particularly important as it directly determines option prices.
/// Uses Abramowitz & Stegun approximation or similar polynomial approximation.
module deepbook_predict::math;



// === Imports ===

// === Errors ===

// === Public Functions ===

// === Private Functions ===
