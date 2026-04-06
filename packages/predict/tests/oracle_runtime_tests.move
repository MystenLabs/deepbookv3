// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for Predict runtime grid validation, liveness checks, and curves.
#[test_only]
module deepbook_predict::oracle_runtime_tests;

use deepbook_predict::{
    constants::{Self, float_scaling as float, oracle_tick_size_unit, oracle_strike_grid_ticks},
    market_key,
    oracle::{Self as oracle, OracleSVI},
    oracle_helper,
    oracle_runtime::{Self as oracle_runtime, new_curve_point},
    precision,
    predict,
    treap
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};

const ALICE: address = @0xA;
const RATE_5_PCT: u64 = 50_000_000;
// floor(e^(-0.05 * 1.0) * FLOAT_SCALING)
const DISCOUNT_5PCT_1YR: u64 = 951_229_424;

fun new_test_clock(now_ms: u64, test: &mut Scenario): clock::Clock {
    let mut test_clock = clock::create_for_testing(test.ctx());
    test_clock.set_for_testing(now_ms);
    test_clock
}

fun new_predict_with_grid(
    test: &mut Scenario,
    oracle_state: &OracleSVI,
    min_strike: u64,
    tick_size: u64,
): predict::Predict<SUI> {
    let mut test_predict = predict::create_test_predict<SUI>(test.ctx());
    oracle_helper::add_grid_to_predict(&mut test_predict, oracle_state, min_strike, tick_size);
    test_predict
}

fun new_std_predict(test: &mut Scenario, oracle_state: &OracleSVI): predict::Predict<SUI> {
    let (min_strike, tick_size) = oracle_helper::default_std_grid();
    new_predict_with_grid(test, oracle_state, min_strike, tick_size)
}

// ============================================================
// Curve points and strike validation
// ============================================================

#[test]
fun curve_point_getters() {
    let pt = new_curve_point(50 * float!(), 600_000_000, 400_000_000);
    assert_eq!(oracle_runtime::strike(&pt), 50 * float!());
    assert_eq!(oracle_runtime::up_price(&pt), 600_000_000);
    assert_eq!(oracle_runtime::dn_price(&pt), 400_000_000);
}

#[test, expected_failure(abort_code = oracle_runtime::EOracleRuntimeNotFound)]
fun assert_valid_strike_without_registered_grid_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        500_000_000,
        500_000_000,
        0,
        100_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_predict = predict::create_test_predict<SUI>(test.ctx());

        oracle_runtime::assert_valid_strike(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
        );
    };

    abort
}

#[test]
fun binary_price_at_min_and_max_strike_succeeds() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        500_000_000,
        500_000_000,
        0,
        100_000,
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let min_strike = oracle_tick_size_unit!();
        let tick_size = oracle_tick_size_unit!();
        let max_strike = min_strike + tick_size * oracle_strike_grid_ticks!();
        let test_predict = new_predict_with_grid(
            &mut test,
            &oracle_state,
            min_strike,
            tick_size,
        );

        let runtime = predict::oracle_runtime(&test_predict);

        let min_up = oracle_runtime::binary_price(
            runtime,
            &oracle_state,
            min_strike,
            true,
            &test_clock,
        );
        let max_up = oracle_runtime::binary_price(
            runtime,
            &oracle_state,
            max_strike,
            true,
            &test_clock,
        );

        assert!(min_up <= float!());
        assert!(max_up <= float!());

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = oracle_runtime::EInvalidStrike)]
fun binary_price_strike_not_on_tick_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        500_000_000,
        500_000_000,
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
        let min_strike = oracle_tick_size_unit!();
        let tick_size = oracle_tick_size_unit!();
        let test_predict = new_predict_with_grid(
            &mut test,
            &oracle_state,
            min_strike,
            tick_size,
        );
        oracle_runtime::binary_price(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            500_000_001,
            true,
            &test_clock,
        );
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EInvalidStrike)]
fun binary_price_below_min_strike_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        500_000_000,
        500_000_000,
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
        let min_strike = oracle_tick_size_unit!();
        let tick_size = oracle_tick_size_unit!();
        let test_predict = new_predict_with_grid(
            &mut test,
            &oracle_state,
            min_strike,
            tick_size,
        );
        oracle_runtime::binary_price(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            min_strike - tick_size,
            true,
            &test_clock,
        );
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EInvalidStrike)]
fun binary_price_above_max_strike_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        500_000_000,
        500_000_000,
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
        let min_strike = oracle_tick_size_unit!();
        let tick_size = oracle_tick_size_unit!();
        let max_strike = min_strike + tick_size * oracle_strike_grid_ticks!();
        let test_predict = new_predict_with_grid(
            &mut test,
            &oracle_state,
            min_strike,
            tick_size,
        );
        oracle_runtime::binary_price(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            max_strike + tick_size,
            true,
            &test_clock,
        );
    };

    abort
}

// ============================================================
// Key and liveness validation
// ============================================================

#[test]
fun assert_key_matches_succeeds() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        10_000,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let key = market_key::up(oracle_id, oracle::expiry(&oracle_state), 100 * float!());

        oracle_runtime::assert_key_matches(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            &key,
        );

        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = oracle_runtime::EMarketKeyOracleMismatch)]
fun assert_key_matches_oracle_id_mismatch_aborts() {
    let mut test = begin(ALICE);
    let oracle_id_1 = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        10_000,
        true,
        &mut test,
    );
    let oracle_id_2 = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        10_000,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id_2);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let key = market_key::up(oracle_id_1, oracle::expiry(&oracle_state), 100 * float!());

        oracle_runtime::assert_key_matches(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            &key,
        );
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EMarketKeyExpiryMismatch)]
fun assert_key_matches_expiry_mismatch_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        0,
        1_000_000,
        10_000,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let key = market_key::up(oracle_id, oracle::expiry(&oracle_state) + 1, 100 * float!());

        oracle_runtime::assert_key_matches(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            &key,
        );
    };

    abort
}

#[test]
fun assert_operational_oracle_fresh() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_simple_shared_oracle(
        ALICE,
        50 * float!(),
        50 * float!(),
        1_000_000,
        10_000,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(15_000, &mut test);

        oracle_runtime::assert_operational_oracle(&oracle_state, &test_clock);

        destroy(test_clock);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = oracle_runtime::EOracleSettled)]
fun assert_operational_oracle_settled_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_settled_shared_oracle(ALICE, 75 * float!(), &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(100_001, &mut test);

        oracle_runtime::assert_operational_oracle(&oracle_state, &test_clock);
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EOracleInactive)]
fun assert_operational_oracle_inactive_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_simple_shared_oracle(
        ALICE,
        50 * float!(),
        50 * float!(),
        1_000_000,
        10_000,
        false,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(15_000, &mut test);

        oracle_runtime::assert_operational_oracle(&oracle_state, &test_clock);
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EOracleStale)]
fun assert_operational_oracle_stale_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_simple_shared_oracle(
        ALICE,
        50 * float!(),
        50 * float!(),
        1_000_000,
        10_000,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(
            10_000 + constants::staleness_threshold_ms!() + 1,
            &mut test,
        );

        oracle_runtime::assert_operational_oracle(&oracle_state, &test_clock);
    };

    abort
}

#[test, expected_failure(abort_code = oracle_runtime::EOracleExpired)]
fun assert_mintable_oracle_at_expiry_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_simple_shared_oracle(
        ALICE,
        50 * float!(),
        50 * float!(),
        1_000_000,
        999_999,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(1_000_000, &mut test);

        oracle_runtime::assert_mintable_oracle(&oracle_state, &test_clock);
    };

    abort
}

// ============================================================
// build_curve
// ============================================================

#[test]
fun build_curve_settled_oracle() {
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
    oracle_helper::settle_shared_oracle(ALICE, oracle_id, 100 * float!(), 100_001, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        assert_eq!(curve.length(), 2);
        assert_eq!(oracle_runtime::strike(&curve[0]), 100 * float!() - 1);
        assert_eq!(oracle_runtime::up_price(&curve[0]), float!());
        assert_eq!(oracle_runtime::dn_price(&curve[0]), 0);
        assert_eq!(oracle_runtime::strike(&curve[1]), 100 * float!());
        assert_eq!(oracle_runtime::up_price(&curve[1]), 0);
        assert_eq!(oracle_runtime::dn_price(&curve[1]), float!());

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test, expected_failure(abort_code = oracle_runtime::EInvalidCurveRange)]
fun build_curve_invalid_range_aborts() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);

        oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            150 * float!(),
            50 * float!(),
            &test_clock,
        );
    };

    abort
}

#[test]
fun build_curve_settled_at_75() {
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
    oracle_helper::settle_shared_oracle(ALICE, oracle_id, 75 * float!(), 100_001, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        assert_eq!(curve.length(), 2);
        assert_eq!(oracle_runtime::strike(&curve[0]), 75 * float!() - 1);
        assert_eq!(oracle_runtime::up_price(&curve[0]), float!());
        assert_eq!(oracle_runtime::dn_price(&curve[0]), 0);
        assert_eq!(oracle_runtime::strike(&curve[1]), 75 * float!());
        assert_eq!(oracle_runtime::up_price(&curve[1]), 0);
        assert_eq!(oracle_runtime::dn_price(&curve[1]), float!());

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_settled_below_live_range_single_point() {
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
    oracle_helper::settle_shared_oracle(ALICE, oracle_id, 25 * float!(), 100_001, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        assert_eq!(curve.length(), 1);
        assert_eq!(oracle_runtime::strike(&curve[0]), 50 * float!());
        assert_eq!(oracle_runtime::up_price(&curve[0]), 0);
        assert_eq!(oracle_runtime::dn_price(&curve[0]), float!());

        let mut exposure = treap::new(test.ctx());
        exposure.insert(75 * float!(), 3 * float!(), false);
        exposure.insert(125 * float!(), 2 * float!(), true);
        let value = exposure.evaluate(&curve);
        // DN wins everywhere; UP loses everywhere.
        assert_eq!(value, 3 * float!());

        destroy(exposure);
        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_settled_above_live_range_single_point() {
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
    oracle_helper::settle_shared_oracle(ALICE, oracle_id, 175 * float!(), 100_001, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        assert_eq!(curve.length(), 1);
        assert_eq!(oracle_runtime::strike(&curve[0]), 50 * float!());
        assert_eq!(oracle_runtime::up_price(&curve[0]), float!());
        assert_eq!(oracle_runtime::dn_price(&curve[0]), 0);

        let mut exposure = treap::new(test.ctx());
        exposure.insert(75 * float!(), 3 * float!(), false);
        exposure.insert(125 * float!(), 2 * float!(), true);
        let value = exposure.evaluate(&curve);
        // UP wins everywhere; DN loses everywhere.
        assert_eq!(value, 2 * float!());

        destroy(exposure);
        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_single_strike() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            100 * float!(),
            100 * float!(),
            &test_clock,
        );

        assert_eq!(curve.length(), 1);
        assert_eq!(oracle_runtime::strike(&curve[0]), 100 * float!());
        assert_eq!(
            oracle_runtime::up_price(&curve[0]) + oracle_runtime::dn_price(&curve[0]),
            float!(),
        );

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_live_sorted_and_complement() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        let len = curve.length();
        assert!(len >= 3);

        let mut i = 0;
        while (i < len - 1) {
            assert!(oracle_runtime::strike(&curve[i]) < oracle_runtime::strike(&curve[i + 1]));
            assert!(oracle_runtime::up_price(&curve[i]) >= oracle_runtime::up_price(&curve[i + 1]));
            i = i + 1;
        };

        i = 0;
        while (i < len) {
            assert_eq!(
                oracle_runtime::up_price(&curve[i]) + oracle_runtime::dn_price(&curve[i]),
                float!(),
            );
            i = i + 1;
        };

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_includes_forward_when_in_range() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        let mut found = false;
        curve.do_ref!(|pt| {
            if (oracle_runtime::strike(pt) == 100 * float!()) found = true;
        });
        assert!(found);

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_no_duplicate_when_forward_at_boundary() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            100 * float!(),
            150 * float!(),
            &test_clock,
        );

        let len = curve.length();
        let mut i = 0;
        while (i < len - 1) {
            assert!(oracle_runtime::strike(&curve[i]) < oracle_runtime::strike(&curve[i + 1]));
            i = i + 1;
        };

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_endpoints_match_min_max() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_std_shared_oracle(ALICE, true, &mut test);

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let min_strike = 50 * float!();
        let max_strike = 150 * float!();
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            min_strike,
            max_strike,
            &test_clock,
        );

        assert_eq!(oracle_runtime::strike(&curve[0]), min_strike);
        assert_eq!(oracle_runtime::strike(&curve[curve.length() - 1]), max_strike);

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_forward_outside_range() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        200 * float!(),
        200 * float!(),
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
        let test_predict = new_predict_with_grid(
            &mut test,
            &oracle_state,
            50 * float!(),
            1_000_000,
        );
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        assert!(curve.length() >= 2);
        assert_eq!(oracle_runtime::strike(&curve[0]), 50 * float!());
        assert_eq!(oracle_runtime::strike(&curve[curve.length() - 1]), 150 * float!());

        let len = curve.length();
        let mut i = 0;
        while (i < len - 1) {
            assert!(oracle_runtime::strike(&curve[i]) < oracle_runtime::strike(&curve[i + 1]));
            i = i + 1;
        };

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}

#[test]
fun build_curve_with_positive_rate_complement() {
    let mut test = begin(ALICE);
    let oracle_id = oracle_helper::setup_flat_vol_shared_oracle(
        ALICE,
        100 * float!(),
        100 * float!(),
        RATE_5_PCT,
        constants::ms_per_year!(),
        0,
        true,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let oracle_state = test.take_shared_by_id<OracleSVI>(oracle_id);
        let test_clock = new_test_clock(0, &mut test);
        let test_predict = new_std_predict(&mut test, &oracle_state);
        let curve = oracle_runtime::build_curve(
            predict::oracle_runtime(&test_predict),
            &oracle_state,
            50 * float!(),
            150 * float!(),
            &test_clock,
        );

        let mut i = 0;
        while (i < curve.length()) {
            let sum = oracle_runtime::up_price(&curve[i]) + oracle_runtime::dn_price(&curve[i]);
            precision::assert_approx(sum, DISCOUNT_5PCT_1YR);
            i = i + 1;
        };

        destroy(test_clock);
        destroy(test_predict);
        return_shared(oracle_state);
    };

    end(test);
}
