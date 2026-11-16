// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `block_scholes`: the decode of verified Block Scholes updates into `BsVol`
/// and `BsSpot`. The updates come from `bs_oracle`'s test constructors, under
/// the series ids the module derives, so each case checks the matching, the
/// combination of slots, and the narrowing to Predict's widths. Expected values
/// are written out by hand.
#[test_only]
module deepbook_predict_math::block_scholes_tests;

use bs_oracle::verify::{Self, SviUpdate, ValueUpdate};
use deepbook_predict_math::block_scholes;
use fixed_math::i64;
use std::{string::String, unit_test::assert_eq};

const EXPIRY_MS: u64 = 1_800_000_060_000;
const OTHER_EXPIRY_MS: u64 = 1_800_000_120_000;
const VALUE_MS: u64 = 1_800_000_000_500;
const NEXT_VALUE_MS: u64 = 1_800_000_001_000;
const SVI_MS: u64 = 1_800_000_000_000;
const NEXT_SVI_MS: u64 = 1_800_000_001_000;
/// $100,000 and $100,250 at 1e9.
const SPOT: u64 = 100_000_000_000_000;
const FORWARD: u64 = 100_250_000_000_000;
/// SVI at 9 decimals: a = -0.000001, b = 0.0002, rho = -0.3, m = 0.001, sigma = 0.002.
const A_9: u128 = 1_000;
const B_9: u128 = 200_000;
const RHO_9: u128 = 300_000_000;
const M_9: u128 = 1_000_000;
const SIGMA_9: u128 = 2_000_000;
/// The same tuple at 1e18, with digits below 1e9 that the 1e9 values round away.
const A_18: u128 = 1_000_123_456_789;
const B_18: u128 = 200_000_499_999_999;
/// 0.3000000005 rounds half up to 300_000_001 at 1e9, and 0.0009999999995 to 1_000_000.
const RHO_18: u128 = 300_000_000_500_000_000;
const RHO_18_ROUNDED: u64 = 300_000_001;
const M_18: u128 = 999_999_999_500_000;
const M_18_ROUNDED: u64 = 1_000_000;
const SIGMA_18: u128 = 2_000_000_499_999_999;
const SIGMA_18_ROUNDED: u64 = 2_000_000;
const ONE_E9: u128 = 1_000_000_000;

fun btc(): String { b"BTC".to_string() }

fun svi_model(): String { b"SVI".to_string() }

fun spot_update(source_ms: u64, value: u128): ValueUpdate {
    verify::new_value_update_for_testing(block_scholes::spot_sid(&btc()), source_ms, value)
}

fun forward_update(expiry_ms: u64, source_ms: u64, value: u128): ValueUpdate {
    verify::new_value_update_for_testing(
        block_scholes::forward_sid(&btc(), expiry_ms),
        source_ms,
        value,
    )
}

fun svi_update(
    decimals: u8,
    expiry_ms: u64,
    source_ms: u64,
    a: u128,
    b: u128,
    rho: u128,
    m: u128,
    sigma: u128,
): SviUpdate {
    verify::new_svi_for_testing(
        block_scholes::svi_sid(&btc(), &svi_model(), decimals, expiry_ms),
        source_ms,
        a,
        true,
        b,
        sigma,
        rho,
        true,
        m,
        false,
    )
}

fun svi_9(source_ms: u64): SviUpdate {
    svi_update(9, EXPIRY_MS, source_ms, A_9, B_9, RHO_9, M_9, SIGMA_9)
}

#[test]
fun vols_decodes_a_spot_forward_pair_and_svi_at_9_decimals() {
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, VALUE_MS, FORWARD as u128),
    ];
    let vols = block_scholes::vols(
        &values,
        &vector[svi_9(SVI_MS)],
        btc(),
        svi_model(),
        9,
        vector[EXPIRY_MS],
    );
    assert_eq!(vols.length(), 1);
    let vol = &vols[0];
    assert_eq!(vol.base_asset(), btc());
    assert_eq!(vol.svi_model(), svi_model());
    assert_eq!(vol.svi_decimals(), 9);
    assert_eq!(vol.expiry_ms(), EXPIRY_MS);
    assert_eq!(vol.value_ms(), VALUE_MS);
    assert_eq!(vol.spot(), SPOT);
    assert_eq!(vol.forward(), FORWARD);
    assert_eq!(vol.svi_ms(), SVI_MS);
    // `a` and `b` are carried at 1e18: the 9-decimal values times 1e9, exactly.
    assert_eq!(vol.a_magnitude(), A_9 * ONE_E9);
    assert!(vol.a_is_negative());
    assert_eq!(vol.b(), B_9 * ONE_E9);
    assert_eq!(vol.rho(), i64::from_parts(RHO_9 as u64, true));
    assert_eq!(vol.m(), i64::from_parts(M_9 as u64, false));
    assert_eq!(vol.sigma(), SIGMA_9 as u64);
}

#[test]
fun vols_keeps_a_and_b_at_18_decimals_and_rounds_the_rest_half_up() {
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, VALUE_MS, FORWARD as u128),
    ];
    let svis = vector[svi_update(18, EXPIRY_MS, SVI_MS, A_18, B_18, RHO_18, M_18, SIGMA_18)];
    let vols = block_scholes::vols(&values, &svis, btc(), svi_model(), 18, vector[EXPIRY_MS]);
    assert_eq!(vols.length(), 1);
    let vol = &vols[0];
    assert_eq!(vol.svi_decimals(), 18);
    assert_eq!(vol.a_magnitude(), A_18);
    assert_eq!(vol.b(), B_18);
    assert_eq!(vol.rho(), i64::from_parts(RHO_18_ROUNDED, true));
    assert_eq!(vol.m(), i64::from_parts(M_18_ROUNDED, false));
    assert_eq!(vol.sigma(), SIGMA_18_ROUNDED);
}

#[test]
fun vols_pairs_spot_and_forward_only_at_one_source_time() {
    // A forward one slot after the spot pairs with nothing: the spot at that
    // later time is missing.
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, NEXT_VALUE_MS, FORWARD as u128),
    ];
    let vols = block_scholes::vols(
        &values,
        &vector[svi_9(SVI_MS)],
        btc(),
        svi_model(),
        9,
        vector[EXPIRY_MS],
    );
    assert!(vols.is_empty());
}

#[test]
fun vols_combines_every_value_slot_with_every_svi_slot() {
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, VALUE_MS, FORWARD as u128),
        spot_update(NEXT_VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, NEXT_VALUE_MS, FORWARD as u128),
    ];
    let svis = vector[svi_9(SVI_MS), svi_9(NEXT_SVI_MS)];
    let vols = block_scholes::vols(&values, &svis, btc(), svi_model(), 9, vector[EXPIRY_MS]);
    // 2 value slots x 2 SVI slots.
    assert_eq!(vols.length(), 4);
    let found = block_scholes::vol_at(
        &values,
        &svis,
        btc(),
        svi_model(),
        9,
        EXPIRY_MS,
        NEXT_VALUE_MS,
        SVI_MS,
    );
    assert!(found.is_some());
    assert_eq!(found.borrow().value_ms(), NEXT_VALUE_MS);
    assert_eq!(found.borrow().svi_ms(), SVI_MS);
}

#[test]
fun vols_ignores_other_series() {
    // Another expiry's forward and SVI, another model's SVI, and another asset's
    // spot match nothing for `EXPIRY_MS`.
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(OTHER_EXPIRY_MS, VALUE_MS, FORWARD as u128),
        verify::new_value_update_for_testing(
            block_scholes::spot_sid(&b"ETH".to_string()),
            VALUE_MS,
            SPOT as u128,
        ),
    ];
    let svis = vector[
        svi_update(9, OTHER_EXPIRY_MS, SVI_MS, A_9, B_9, RHO_9, M_9, SIGMA_9),
        verify::new_svi_for_testing(
            block_scholes::svi_sid(&btc(), &b"SVI_REGIME".to_string(), 9, EXPIRY_MS),
            SVI_MS,
            A_9,
            true,
            B_9,
            SIGMA_9,
            RHO_9,
            true,
            M_9,
            false,
        ),
    ];
    assert!(
        block_scholes::vols(&values, &svis, btc(), svi_model(), 9, vector[EXPIRY_MS]).is_empty(),
    );
    // Asked for the other expiry, the same updates decode its forward and SVI with
    // the BTC spot: one combination.
    assert_eq!(
        block_scholes::vols(
            &values,
            &svis,
            btc(),
            svi_model(),
            9,
            vector[OTHER_EXPIRY_MS],
        ).length(),
        1,
    );
}

#[test]
fun vols_skips_zero_and_wide_values_and_unknown_decimals() {
    let svis = vector[svi_9(SVI_MS)];
    let zero_spot = vector[
        spot_update(VALUE_MS, 0),
        forward_update(EXPIRY_MS, VALUE_MS, FORWARD as u128),
    ];
    assert!(
        block_scholes::vols(&zero_spot, &svis, btc(), svi_model(), 9, vector[EXPIRY_MS]).is_empty(),
    );
    let wide_forward = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, VALUE_MS, (std::u64::max_value!() as u128) + 1),
    ];
    assert!(
        block_scholes::vols(
            &wide_forward,
            &svis,
            btc(),
            svi_model(),
            9,
            vector[EXPIRY_MS],
        ).is_empty(),
    );
    let values = vector[
        spot_update(VALUE_MS, SPOT as u128),
        forward_update(EXPIRY_MS, VALUE_MS, FORWARD as u128),
    ];
    // A 9-decimal `sigma` past u64 does not fit Predict's width.
    let wide_sigma = vector[
        svi_update(
            9,
            EXPIRY_MS,
            SVI_MS,
            A_9,
            B_9,
            RHO_9,
            M_9,
            (std::u64::max_value!() as u128) + 1,
        ),
    ];
    assert!(
        block_scholes::vols(
            &values,
            &wide_sigma,
            btc(),
            svi_model(),
            9,
            vector[EXPIRY_MS],
        ).is_empty(),
    );
    // Decimals other than 9 and 18 decode nothing.
    let svis_12 = vector[svi_update(12, EXPIRY_MS, SVI_MS, A_9, B_9, RHO_9, M_9, SIGMA_9)];
    assert!(
        block_scholes::vols(
            &values,
            &svis_12,
            btc(),
            svi_model(),
            12,
            vector[EXPIRY_MS],
        ).is_empty(),
    );
}

#[test]
fun spot_at_reads_the_spot_stamped_at_the_time() {
    let values = vector[spot_update(SVI_MS, SPOT as u128), spot_update(VALUE_MS, FORWARD as u128)];
    let spot = block_scholes::spot_at(&values, btc(), VALUE_MS);
    assert!(spot.is_some());
    let spot = spot.destroy_some();
    assert_eq!(spot.spot_base_asset(), btc());
    assert_eq!(spot.source_ms(), VALUE_MS);
    assert_eq!(spot.spot_price(), FORWARD);
    assert!(block_scholes::spot_at(&values, btc(), NEXT_VALUE_MS).is_none());
    assert!(block_scholes::spot_at(&values, b"ETH".to_string(), VALUE_MS).is_none());
    let zero = vector[spot_update(VALUE_MS, 0)];
    assert!(block_scholes::spot_at(&zero, btc(), VALUE_MS).is_none());
}

#[test]
fun svi_sid_depends_on_model_decimals_and_expiry() {
    let base = block_scholes::svi_sid(&btc(), &svi_model(), 9, EXPIRY_MS);
    assert!(base != block_scholes::svi_sid(&btc(), &svi_model(), 18, EXPIRY_MS));
    assert!(base != block_scholes::svi_sid(&btc(), &b"SVI_REGIME".to_string(), 9, EXPIRY_MS));
    assert!(base != block_scholes::svi_sid(&btc(), &svi_model(), 9, OTHER_EXPIRY_MS));
    assert!(block_scholes::spot_sid(&btc()) != block_scholes::forward_sid(&btc(), EXPIRY_MS));
}
