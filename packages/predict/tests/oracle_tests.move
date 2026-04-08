// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for core oracle lifecycle, settlement, and one-sided pricing.
#[test_only]
module deepbook_predict::oracle_tests;

use deepbook_predict::{
    constants::float_scaling as float,
    generated_oracle as go,
    i64,
    oracle::{Self as oracle, OracleSVICap, OracleSVI, new_price_data, new_svi_params},
    oracle_helper,
    precision
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::{Scenario, begin, end, return_shared}};

const ALICE: address = @0xA;
const BOB: address = @0xB;

// === Common test SVI params ===
const SVI_SIGMA_0_25: u64 = 250_000_000;

fun signed(magnitude: u64, is_negative: bool): i64::I64 {
    i64::from_parts(magnitude, is_negative)
}

fun svi(
    a: u64,
    b: u64,
    rho: u64,
    rho_negative: bool,
    m: u64,
    m_negative: bool,
    sigma: u64,
): oracle::SVIParams {
    new_svi_params(a, b, signed(rho, rho_negative), signed(m, m_negative), sigma)
}

fun new_test_clock(now_ms: u64, test: &mut Scenario): clock::Clock {
    let mut test_clock = clock::create_for_testing(test.ctx());
    test_clock.set_for_testing(now_ms);
    test_clock
}

fun binary_price_pair(
    oracle_state: &OracleSVI,
    strike: u64,
    _test_clock: &clock::Clock,
): (u64, u64) {
    let up = oracle::compute_price(oracle_state, strike);
    (up, float!() - up)
}

fun assert_pair_exact(
    oracle_state: &OracleSVI,
    strike: u64,
    test_clock: &clock::Clock,
    expected_up: u64,
    expected_dn: u64,
) {
    let (up, dn) = binary_price_pair(oracle_state, strike, test_clock);
    assert_eq!(up, expected_up);
    assert_eq!(dn, expected_dn);
}

fun assert_pair_approx(
    oracle_state: &OracleSVI,
    strike: u64,
    test_clock: &clock::Clock,
    expected_up: u64,
    expected_dn: u64,
) {
    let (up, dn) = binary_price_pair(oracle_state, strike, test_clock);
    precision::assert_approx(up, expected_up);
    precision::assert_approx(dn, expected_dn);
}

fun setup_configured_oracle(
    svi: oracle::SVIParams,
    prices: oracle::PriceData,
    risk_free_rate: u64,
    expiry_ms: u64,
    now_ms: u64,
    active: bool,
    test: &mut Scenario,
): ID {
    oracle_helper::setup_configured_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        svi,
        prices,
        risk_free_rate,
        expiry_ms,
        now_ms,
        active,
        test,
    )
}

fun run_oracle_scenario(idx: u64) {
    let mut test = begin(ALICE);
    let scenarios = go::scenarios();
    let scenario = &scenarios[idx];
    let oracle_id = oracle_helper::setup_oracle_from_scenario(ALICE, scenario, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(scenario.now_ms(), &mut test);

        scenario.strike_points().do_ref!(|sp| {
            assert_pair_approx(
                &oracle_state,
                sp.strike(),
                &test_clock,
                sp.expected_up(),
                sp.expected_dn(),
            );
        });

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

// ============================================================
// Construction and getters
// ============================================================

#[test]
fun create_oracle_initial_state() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        100_000,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);

        assert_eq!(oracle::underlying_asset(&oracle_state), b"BTC".to_string());
        assert_eq!(oracle::spot_price(&oracle_state), 0);
        assert_eq!(oracle::forward_price(&oracle_state), 0);
        assert_eq!(oracle::expiry(&oracle_state), 100_000);
        assert_eq!(oracle::timestamp(&oracle_state), 0);
        assert!(oracle::settlement_price(&oracle_state).is_none());
        assert_eq!(oracle::is_active(&oracle_state), false);
        assert_eq!(oracle::is_settled(&oracle_state), false);

        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun configured_oracle_with_nonzero_params() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(100, 200, 300, true, 400, false, 500),
        new_price_data(50 * float!(), 51 * float!()),
        42,
        999_999,
        12_345,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);

        assert_eq!(oracle::spot_price(&oracle_state), 50 * float!());
        assert_eq!(oracle::forward_price(&oracle_state), 51 * float!());
        assert_eq!(oracle::expiry(&oracle_state), 999_999);
        assert_eq!(oracle::timestamp(&oracle_state), 12_345);
        assert_eq!(oracle::is_active(&oracle_state), true);

        return_shared(oracle_state);
    };

    end(test);
}

// ============================================================
// Settlement
// ============================================================

#[test]
fun settled_above_strike_up_wins() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 60 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);

        assert_pair_exact(&oracle_state, 50 * float!(), &test_clock, float!(), 0);

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun settled_below_strike_dn_wins() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 40 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);

        assert_pair_exact(&oracle_state, 50 * float!(), &test_clock, 0, float!());

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun settled_at_strike_dn_wins() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 50 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);

        assert_pair_exact(&oracle_state, 50 * float!(), &test_clock, 0, float!());

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun settled_various_strikes() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 100 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);

        assert_pair_exact(&oracle_state, 99 * float!(), &test_clock, float!(), 0);
        assert_pair_exact(&oracle_state, 100 * float!(), &test_clock, 0, float!());
        assert_pair_exact(&oracle_state, 101 * float!(), &test_clock, 0, float!());
        assert_pair_exact(&oracle_state, 1 * float!(), &test_clock, float!(), 0);

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun settled_up_plus_dn_always_one() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 75 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let strikes = vector[1, 50, 74, 75, 76, 100, 200];

        strikes.do!(|s| {
            let strike = s * float!();
            let (up, dn) = binary_price_pair(&oracle_state, strike, &test_clock);
            assert_eq!(up + dn, float!());
        });

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun is_settled_true_after_settle() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 50 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);

        assert_eq!(oracle::is_settled(&oracle_state), true);
        assert_eq!(oracle::is_active(&oracle_state), false);
        assert_eq!(oracle::settlement_price(&oracle_state).destroy_some(), 50 * float!());

        return_shared(oracle_state);
    };

    end(test);
}

// ============================================================
// Live pricing
// ============================================================

#[test]
fun live_price_ignores_rate() {
    let mut test = begin(ALICE);
    let forward = 100 * float!();
    let oracle_with_rate_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        forward,
        forward,
        50_000_000,
        100_000,
        0,
        true,
        &mut test,
    );
    let oracle_zero_rate_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        forward,
        forward,
        0,
        100_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_with_rate = test.take_shared_by_id<OracleSVI>(oracle_with_rate_id);
        let oracle_zero_rate = test.take_shared_by_id<OracleSVI>(oracle_zero_rate_id);
        let test_clock = new_test_clock(0, &mut test);

        let (up, dn) = binary_price_pair(&oracle_with_rate, forward, &test_clock);
        let (up_zero_rate, dn_zero_rate) = binary_price_pair(
            &oracle_zero_rate,
            forward,
            &test_clock,
        );

        precision::assert_approx(up, up_zero_rate);
        precision::assert_approx(dn, dn_zero_rate);

        destroy(test_clock);
        return_shared(oracle_with_rate);
        return_shared(oracle_zero_rate);
    };

    end(test);
}

#[test]
fun live_forward_one_unit_above_strike() {
    let mut test = begin(ALICE);
    let forward = 100 * float!();
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        forward,
        forward,
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let strike = forward - 1_000_000;
        let (up, dn) = binary_price_pair(&oracle_state, strike, &test_clock);

        assert_eq!(up + dn, float!());

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = oracle::EZeroForward)]
fun live_price_with_zero_forward_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        0,
        0,
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        binary_price_pair(&oracle_state, 50 * float!(), &test_clock);
    };

    abort 999
}

// ============================================================
// Positive-path: activate, update_prices, update_svi
// ============================================================

#[test]
fun activate_succeeds_with_registered_cap() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(0, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
        new_price_data(100 * float!(), 100 * float!()),
        0,
        1_000_000,
        0,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(5_000, &mut test);

        assert_eq!(oracle::is_active(&oracle_state), false);
        oracle::activate(&mut oracle_state, &cap, &test_clock);
        assert_eq!(oracle::is_active(&oracle_state), true);

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

#[test]
fun update_prices_updates_spot_and_forward() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        1_000_000,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(5_000, &mut test);

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(105 * float!(), 106 * float!()),
            &test_clock,
        );

        assert_eq!(oracle::spot_price(&oracle_state), 105 * float!());
        assert_eq!(oracle::forward_price(&oracle_state), 106 * float!());
        assert_eq!(oracle::timestamp(&oracle_state), 5_000);

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

#[test]
fun update_prices_past_expiry_settles_oracle() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        100_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(200_000, &mut test);

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(105 * float!(), 106 * float!()),
            &test_clock,
        );

        assert_eq!(oracle::is_settled(&oracle_state), true);
        assert_eq!(oracle::is_active(&oracle_state), false);
        assert_eq!(oracle::settlement_price(&oracle_state).destroy_some(), 105 * float!());

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

#[test]
fun update_svi_updates_params_but_not_timestamp() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        1_000_000,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(5_000, &mut test);

        oracle::update_svi(
            &mut oracle_state,
            &cap,
            svi(100, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
            &test_clock,
        );

        let svi = oracle::svi(&oracle_state);
        assert_eq!(oracle::svi_a(&svi), 100);
        assert_eq!(oracle::svi_b(&svi), float!());
        assert_eq!(oracle::svi_sigma(&svi), SVI_SIGMA_0_25);
        assert_eq!(oracle::timestamp(&oracle_state), 0);

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

// ============================================================
// Abort code coverage
// ============================================================

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun activate_with_unauthorized_cap_aborts() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        1_000_000,
        &mut test,
    );
    let _unauthorized_cap = oracle_helper::create_unregistered_cap(BOB, &mut test);

    test.next_tx(BOB);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(0, &mut test);
        oracle::activate(&mut oracle_state, &cap, &test_clock);
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun update_prices_with_unauthorized_cap_aborts() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        1_000_000,
        &mut test,
    );
    let _unauthorized_cap = oracle_helper::create_unregistered_cap(BOB, &mut test);

    test.next_tx(BOB);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(0, &mut test);
        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(105 * float!(), 106 * float!()),
            &test_clock,
        );
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun update_svi_with_unauthorized_cap_aborts() {
    let mut test = begin(ALICE);
    let (oracle_id, _cap_id) = oracle_helper::setup_shared_oracle(
        ALICE,
        b"BTC".to_string(),
        1_000_000,
        &mut test,
    );
    let _unauthorized_cap = oracle_helper::create_unregistered_cap(BOB, &mut test);

    test.next_tx(BOB);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(0, &mut test);
        oracle::update_svi(
            &mut oracle_state,
            &cap,
            svi(0, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
            &test_clock,
        );
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EOracleAlreadyActive)]
fun activate_already_active_oracle_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(0, &mut test);
        oracle::activate(&mut oracle_state, &cap, &test_clock);
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun activate_expired_oracle_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(0, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
        new_price_data(100 * float!(), 100 * float!()),
        0,
        1_000_000,
        0,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(2_000_000, &mut test);
        oracle::activate(&mut oracle_state, &cap, &test_clock);
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EOracleSettled)]
fun update_svi_on_settled_oracle_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 100 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(0, &mut test);
        oracle::update_svi(
            &mut oracle_state,
            &cap,
            svi(0, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
            &test_clock,
        );
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::ECannotBeNegative)]
fun compute_nd2_negative_inner_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(0, float!(), float!(), true, 0, false, 1),
        new_price_data(100 * float!(), 100 * float!()),
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        binary_price_pair(&oracle_state, 1000 * float!(), &test_clock);
    };

    abort 999
}

#[test, expected_failure(abort_code = oracle::EZeroVariance)]
fun zero_svi_params_on_live_oracle_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(0, 0, 0, false, 0, false, 0),
        new_price_data(100 * float!(), 100 * float!()),
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        binary_price_pair(&oracle_state, 100 * float!(), &test_clock);
    };

    abort 999
}

// ============================================================
// Expiry boundary tests
// ============================================================

#[test, expected_failure(abort_code = oracle::EOracleExpired)]
fun activate_at_exact_expiry_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = setup_configured_oracle(
        svi(0, float!(), 0, false, 0, false, SVI_SIGMA_0_25),
        new_price_data(100 * float!(), 100 * float!()),
        0,
        1_000_000,
        0,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(1_000_000, &mut test);
        oracle::activate(&mut oracle_state, &cap, &test_clock);
    };

    abort 999
}

#[test]
fun update_prices_at_exact_expiry_does_not_settle() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(1_000_000, &mut test);

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(105 * float!(), 106 * float!()),
            &test_clock,
        );

        assert!(oracle::settlement_price(&oracle_state).is_none());
        assert_eq!(oracle::spot_price(&oracle_state), 105 * float!());

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

#[test]
fun update_prices_on_settled_oracle_preserves_settlement() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let cap = test.take_from_sender<OracleSVICap>();
        let test_clock = new_test_clock(2_000_000, &mut test);

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(105 * float!(), 106 * float!()),
            &test_clock,
        );
        assert_eq!(oracle::settlement_price(&oracle_state).destroy_some(), 105 * float!());

        oracle::update_prices(
            &mut oracle_state,
            &cap,
            new_price_data(110 * float!(), 111 * float!()),
            &test_clock,
        );

        assert_eq!(oracle::settlement_price(&oracle_state).destroy_some(), 105 * float!());
        assert_eq!(oracle::spot_price(&oracle_state), 110 * float!());

        destroy(test_clock);
        return_shared(oracle_state);
        test.return_to_sender(cap);
    };

    end(test);
}

// ============================================================
// Scenario runner — all 13 scenarios against scipy ground truth
// ============================================================

#[test]
fun scenario_std() { run_oracle_scenario(0); }
#[test]
fun scenario_std_5pct() { run_oracle_scenario(1); }
#[test]
fun scenario_full_svi() { run_oracle_scenario(2); }
#[test]
fun scenario_small_sigma() { run_oracle_scenario(3); }
#[test]
fun scenario_nonzero_a() { run_oracle_scenario(4); }
#[test]
fun scenario_neg_rho() { run_oracle_scenario(5); }
#[test]
fun scenario_nonzero_m() { run_oracle_scenario(6); }
#[test]
fun scenario_s0() { run_oracle_scenario(7); }
#[test]
fun scenario_s1() { run_oracle_scenario(8); }
#[test]
fun scenario_s2() { run_oracle_scenario(9); }
#[test]
fun scenario_s3() { run_oracle_scenario(10); }
#[test]
fun scenario_s4() { run_oracle_scenario(11); }
#[test]
fun scenario_s5() { run_oracle_scenario(12); }
