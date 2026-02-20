// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Cross-validation tests: compare Move binary option pricing against
/// Python (scipy) reference values computed via cross_validation.py.
///
/// The Python script uses the exact same mathematical path:
///   k = ln(strike/forward)
///   total_var = a + b*(rho*(k-m) + sqrt((k-m)^2 + sigma^2))
///   d2 = (-k - total_var/2) / sqrt(total_var)
///   N(d2) for UP, N(-d2) for DOWN
///   price = e^(-r*t) * N(±d2)
///
/// Tolerance: ±0.5% (5_000_000 in 1e9) accounts for fixed-point
/// truncation in mul/div and approximation differences in ln/exp/cdf.
#[test_only]
module deepbook_predict::cross_validation_tests;

use deepbook_predict::oracle;
use std::unit_test::destroy;
use sui::clock;

public struct BTC has drop {}

/// Tolerance for price comparisons: 0.01% in FLOAT_SCALING.
/// Actual observed deviation is ~0.00001% (max ~68 out of 1e9).
const TOLERANCE: u64 = 100_000;

fun assert_approx(actual: u64, expected: u64, tolerance: u64) {
    let diff = if (actual > expected) {
        actual - expected
    } else {
        expected - actual
    };
    assert!(diff <= tolerance, actual);
}

// =========================================================================
// Scenario 1: Real BTC params, 126 days to expiry
//
// SVI: a=0.01178, b=0.18226, rho=-0.28796, m=0.02823, sigma=0.34312
// Spot: $67,293  Forward: $68,071  Rate: 3.5%
// Python reference values from cross_validation.py
// =========================================================================

fun make_btc_126d_oracle(ctx: &mut TxContext): oracle::OracleSVI<BTC> {
    let svi = oracle::new_svi_params(
        11_780_000, // a = 0.01178
        182_260_000, // b = 0.18226
        287_960_000, // rho = 0.28796
        true, // rho_negative
        28_230_000, // m = 0.02823
        false, // m_negative
        343_120_000, // sigma = 0.34312
    );
    let prices = oracle::new_price_data(
        67_293_000_000_000, // spot  = $67,293
        68_071_000_000_000, // forward = $68,071
    );

    let now_ms = 1_000_000_000;
    let expiry_ms = 11_886_400_000; // now + 126 days

    oracle::create_test_oracle<BTC>(
        svi,
        prices,
        35_000_000, // r = 3.5%
        expiry_ms,
        now_ms,
        ctx,
    )
}

/// ATM: strike = forward = $68,071
/// Python: nd2_up=445_179_672, nd2_down=554_820_328
/// Python: price_up=439_833_289, price_down=548_157_216
#[test]
fun btc_126d_atm_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);

    let strike = 68_071_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 445_179_672, TOLERANCE);
    assert_approx(down, 554_820_328, TOLERANCE);
    // Sum should be ~1e9 (no discounting)
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun btc_126d_atm_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 68_071_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 439_833_289, TOLERANCE);
    assert_approx(down, 548_157_216, TOLERANCE);
    // Sum ≈ discount = 987_990_505
    assert_approx(up + down, 987_990_505, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// OTM call: strike = $78,071 (forward + $10k)
/// Python: nd2_up=259_192_712, nd2_down=740_807_288
/// Python: price_up=256_079_939, price_down=731_910_566
#[test]
fun btc_126d_otm_call_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);

    let strike = 78_071_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 259_192_712, TOLERANCE);
    assert_approx(down, 740_807_288, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun btc_126d_otm_call_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 78_071_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 256_079_939, TOLERANCE);
    assert_approx(down, 731_910_566, TOLERANCE);
    assert_approx(up + down, 987_990_505, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// ITM call: strike = $58,071 (forward - $10k)
/// Python: nd2_up=643_985_875, nd2_down=356_014_125
/// Python: price_up=636_251_930, price_down=351_738_575
#[test]
fun btc_126d_itm_call_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);

    let strike = 58_071_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 643_985_875, TOLERANCE);
    assert_approx(down, 356_014_125, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun btc_126d_itm_call_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 58_071_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 636_251_930, TOLERANCE);
    assert_approx(down, 351_738_575, TOLERANCE);
    assert_approx(up + down, 987_990_505, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// Deep ITM: strike = $48,071 (forward - $20k)
/// Python: nd2_up=791_138_894, nd2_down=208_861_106
/// Python: price_up=781_637_715, price_down=206_352_789
#[test]
fun btc_126d_deep_itm_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);

    let strike = 48_071_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 791_138_894, TOLERANCE);
    assert_approx(down, 208_861_106, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun btc_126d_deep_itm_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_btc_126d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 48_071_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 781_637_715, TOLERANCE);
    assert_approx(down, 206_352_789, TOLERANCE);
    assert_approx(up + down, 987_990_505, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

// =========================================================================
// Scenario 2: Synthetic params, 30 days to expiry
//
// SVI: a=0.04, b=0.1, rho=-0.3, m=0, sigma=0.1
// Spot: $100,000  Forward: $100,500  Rate: 5%
// Python reference values from cross_validation.py
// =========================================================================

fun make_synthetic_30d_oracle(ctx: &mut TxContext): oracle::OracleSVI<BTC> {
    let svi = oracle::new_svi_params(
        40_000_000, // a = 0.04
        100_000_000, // b = 0.1
        300_000_000, // rho = 0.3
        true, // rho_negative
        0, // m = 0
        false,
        100_000_000, // sigma = 0.1
    );
    let prices = oracle::new_price_data(
        100_000_000_000_000, // spot = $100,000
        100_500_000_000_000, // forward = $100,500
    );

    let now_ms = 1_000_000_000;
    let expiry_ms = 3_592_000_000; // now + 30 days

    oracle::create_test_oracle<BTC>(
        svi,
        prices,
        50_000_000, // r = 5%
        expiry_ms,
        now_ms,
        ctx,
    )
}

/// ATM: strike = forward = $100,500
/// Python: nd2_up=455_489_646, nd2_down=544_510_354
/// Python: price_up=453_621_612, price_down=542_277_232
#[test]
fun synthetic_30d_atm_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);

    let strike = 100_500_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 455_489_646, TOLERANCE);
    assert_approx(down, 544_510_354, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun synthetic_30d_atm_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 100_500_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 453_621_612, TOLERANCE);
    assert_approx(down, 542_277_232, TOLERANCE);
    assert_approx(up + down, 995_898_844, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// OTM call: strike = $110,000
/// Python: nd2_up=303_788_946, nd2_down=696_211_054
/// Python: price_up=302_543_061, price_down=693_355_783
#[test]
fun synthetic_30d_otm_call_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);

    let strike = 110_000_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 303_788_946, TOLERANCE);
    assert_approx(down, 696_211_054, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun synthetic_30d_otm_call_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 110_000_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 302_543_061, TOLERANCE);
    assert_approx(down, 693_355_783, TOLERANCE);
    assert_approx(up + down, 995_898_844, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}

/// ITM call: strike = $90,000
/// Python: nd2_up=631_855_871, nd2_down=368_144_129
/// Python: price_up=629_264_531, price_down=366_634_312
#[test]
fun synthetic_30d_itm_call_undiscounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);

    let strike = 90_000_000_000_000;

    let up = oracle.get_binary_price_undiscounted(strike, true);
    let down = oracle.get_binary_price_undiscounted(strike, false);

    assert_approx(up, 631_855_871, TOLERANCE);
    assert_approx(down, 368_144_129, TOLERANCE);
    assert_approx(up + down, 1_000_000_000, TOLERANCE);

    destroy(oracle);
}

#[test]
fun synthetic_30d_itm_call_discounted() {
    let ctx = &mut tx_context::dummy();
    let oracle = make_synthetic_30d_oracle(ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(1_000_000_000);

    let strike = 90_000_000_000_000;

    let up = oracle.get_binary_price(strike, true, &clock);
    let down = oracle.get_binary_price(strike, false, &clock);

    assert_approx(up, 629_264_531, TOLERANCE);
    assert_approx(down, 366_634_312, TOLERANCE);
    assert_approx(up + down, 995_898_844, TOLERANCE);

    destroy(oracle);
    clock.destroy_for_testing();
}
