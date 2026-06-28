// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the pool-level cap on active pre-expiry markets that can
/// require live NAV valuation in a full-pool flush.
#[test_only]
module deepbook_predict::live_market_cap_tests;

use deepbook_predict::{constants, plp::{Self, PoolVault}, test_constants};
use std::unit_test::assert_eq;
use sui::{clock::{Self as clock, Clock}, test_scenario::{Self as test, Scenario, return_shared}};

const NOW_MS: u64 = 1_000;
const EXPIRED_EXPIRY_MS: u64 = NOW_MS;
const FUTURE_EXPIRY_MS: u64 = NOW_MS + 1;
const MAX_EXPIRY_ALLOCATION: u64 = 1_000;
const INITIAL_EXPIRY_CASH: u64 = 100;
const FIRST_ID_INDEX: u64 = 0;

#[test, expected_failure(abort_code = plp::EMaxLiveExpiryMarketsExceeded)]
fun register_expiry_above_live_market_cap_aborts() {
    let (_scenario, mut vault, clock) = begin_vault_test();

    let mut i = 0;
    while (i < constants::max_live_expiry_markets!()) {
        register_expiry(&mut vault, synthetic_expiry_id(i), FUTURE_EXPIRY_MS, &clock);
        i = i + 1;
    };
    register_expiry(&mut vault, synthetic_expiry_id(i), FUTURE_EXPIRY_MS, &clock);

    abort 999
}

#[test]
fun expired_active_markets_do_not_consume_live_market_cap() {
    let (scenario, mut vault, clock) = begin_vault_test();

    let mut i = 0;
    while (i < constants::max_live_expiry_markets!()) {
        register_expiry(&mut vault, synthetic_expiry_id(i), EXPIRED_EXPIRY_MS, &clock);
        i = i + 1;
    };
    register_expiry(&mut vault, synthetic_expiry_id(i), FUTURE_EXPIRY_MS, &clock);

    assert_eq!(vault.active_live_expiry_count(&clock), 1);
    assert_eq!(vault.active_expiry_markets().length(), constants::max_live_expiry_markets!() + 1);
    finish_vault_test(scenario, vault, clock);
}

fun begin_vault_test(): (Scenario, PoolVault, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    let vault_id = plp::init_for_testing(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);
    let vault = scenario.take_shared_by_id<PoolVault>(vault_id);
    (scenario, vault, clock)
}

fun finish_vault_test(scenario: Scenario, vault: PoolVault, clock: Clock) {
    clock.destroy_for_testing();
    return_shared(vault);
    scenario.end();
}

fun register_expiry(vault: &mut PoolVault, expiry_market_id: ID, expiry_ms: u64, clock: &Clock) {
    vault.register_expiry(
        expiry_market_id,
        expiry_ms,
        MAX_EXPIRY_ALLOCATION,
        INITIAL_EXPIRY_CASH,
        clock,
    );
}

fun synthetic_expiry_id(index: u64): ID {
    let addresses = vector[
        @0x100,
        @0x101,
        @0x102,
        @0x103,
        @0x104,
        @0x105,
        @0x106,
        @0x107,
        @0x108,
        @0x109,
        @0x10A,
        @0x10B,
        @0x10C,
        @0x10D,
        @0x10E,
        @0x10F,
        @0x110,
        @0x111,
        @0x112,
        @0x113,
        @0x114,
        @0x115,
        @0x116,
        @0x117,
        @0x118,
    ];
    object::id_from_address(addresses[FIRST_ID_INDEX + index])
}
