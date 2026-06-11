// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the numeric domain envelope of `pyth_source::value_in_dusdc`, whose
/// out-of-domain backstop is the native VM arithmetic abort (per the in-code
/// contract): the exact largest `(amount, spot, decimals)` combination that
/// succeeds and the abort one step past it, on both arms — the final u64
/// downcast of the DUSDC value and the `10^(decimals + 3)` u128 divisor.
#[test_only]
module deepbook_predict::pyth_source_value_tests;

use deepbook_predict::{
    admin::AdminCap,
    pyth_source::PythSource,
    registry::{Self, Registry},
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

/// $1,000 in Predict's 1e9 price scaling. At SUI decimals (9) the conversion
/// divisor is 10^(9 + 9 - 6) = 1e12 == this spot, so `value_in_dusdc` is an
/// exact identity: ceil(amount * 1e12 / 1e12) = amount for every amount.
const IDENTITY_SPOT: u64 = 1_000_000_000_000;
/// One unit above the identity spot: at amount = u64::MAX the value becomes
/// ceil(u64::MAX * (1e12 + 1) / 1e12) = u64::MAX + 18_446_745 > u64::MAX,
/// overflowing the final `as u64` downcast.
const SPOT_ONE_PAST_IDENTITY: u64 = 1_000_000_000_001;
/// SUI coin decimals — the production decimals for the SUI incentive arm.
const SUI_DECIMALS: u8 = 9;
/// Largest asset-decimals whose divisor still fits u128: 10^(35 + 3) = 1e38
/// < u128::MAX ~= 3.4e38. At 36 decimals the divisor is 10^39 and the
/// `10u128.pow` multiply overflows. Production incentive assets are SUI (9) /
/// DEEP (6), so this arm is unreachable at HEAD; the pin guards the envelope
/// against a future generic incentive-asset path.
const MAX_POW10_SAFE_DECIMALS: u8 = 35;

/// Bring up the registered Pyth source through the production registry path
/// and seed it with `spot` (fresh timestamps; `value_in_dusdc` itself reads
/// only the spot).
fun setup_pyth(spot: u64): (Scenario, PythSource, AdminCap) {
    let mut scenario = test::begin(test_constants::admin());
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(spot, live_ts, live_ts);
    (scenario, pyth, admin_cap)
}

#[test]
fun value_at_identity_spot_maps_max_amount_exactly() {
    let (scenario, pyth, admin_cap) = setup_pyth(IDENTITY_SPOT);

    // The largest combination that succeeds: the full u64 range maps onto the
    // full u64 range with zero rounding (the product divides evenly), so the
    // largest representable DUSDC value is reachable exactly.
    //   ceil(18_446_744_073_709_551_615 * 1e12 / 1e12) = 18_446_744_073_709_551_615
    assert_eq!(pyth.value_in_dusdc(std::u64::max_value!(), SUI_DECIMALS), std::u64::max_value!());

    return_shared(pyth);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(arithmetic_error, location = deepbook_predict::pyth_source)]
fun value_one_past_identity_spot_overflows_downcast() {
    let (_scenario, pyth, _admin_cap) = setup_pyth(SPOT_ONE_PAST_IDENTITY);

    // One spot unit past the success boundary above: the u128 intermediate is
    // fine, but the result u64::MAX + 18_446_745 no longer fits the `as u64`
    // downcast — the documented native out-of-domain backstop.
    pyth.value_in_dusdc(std::u64::max_value!(), SUI_DECIMALS);

    abort 999
}

#[test]
fun value_at_max_pow10_safe_decimals_rounds_up_to_one() {
    let (scenario, pyth, admin_cap) = setup_pyth(IDENTITY_SPOT);

    // Decimals boundary success side: divisor 10^38 fits u128, and the ceil
    // rounds the tiny positive value up to a single micro-DUSDC:
    //   ceil(1 * 1e12 / 1e38) = 1
    assert_eq!(pyth.value_in_dusdc(1, MAX_POW10_SAFE_DECIMALS), 1);

    return_shared(pyth);
    destroy(admin_cap);
    scenario.end();
}

// The pow overflow aborts inside `std::u128::pow` (where the stdlib `num_pow!`
// macro expands), not in `pyth_source`.
#[test, expected_failure(arithmetic_error, location = std::u128)]
fun value_one_past_max_pow10_safe_decimals_overflows_divisor() {
    let (_scenario, pyth, _admin_cap) = setup_pyth(IDENTITY_SPOT);

    // One decimal past the boundary: 10u128.pow(36 + 3) computes 10^39 >
    // u128::MAX and aborts before any value math runs.
    pyth.value_in_dusdc(1, MAX_POW10_SAFE_DECIMALS + 1);

    abort 999
}
