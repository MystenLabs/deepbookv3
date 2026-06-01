// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::market_oracle_getters_tests;

use deepbook_predict::{admin, constants, i64, market_oracle};
use std::unit_test::{assert_eq, destroy};
use sui::clock;

const EXPIRY_MS: u64 = 100_000;
const BEFORE_EXPIRY: u64 = 10_000;
const AT_EXPIRY: u64 = 100_000;
const AFTER_EXPIRY: u64 = 200_000;

// === Constructor + identity ===

#[test]
fun id_round_trips_through_object() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    let id = market.id();
    assert_eq!(id, market.id()); // second read matches the first

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

#[test]
fun cap_id_round_trips() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);

    let cap_id_first = cap.cap_id();
    assert_eq!(cap.cap_id(), cap_id_first);

    destroy(cap);
    destroy(admin_cap);
}

#[test]
fun expiry_returns_constructor_value() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    assert_eq!(market.expiry(), EXPIRY_MS);

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

#[test]
fun allowed_versions_seeded_with_current() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    let versions = market.allowed_versions();
    assert!(versions.contains(&constants::current_version!()));
    assert_eq!(versions.length(), 1);

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

#[test]
fun pyth_source_id_is_persisted() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    // Stable binding identity (same value across reads).
    assert_eq!(market.pyth_source_id(), market.pyth_source_id());

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

// === is_settled / raw_settlement_price ===

#[test]
fun is_settled_false_on_fresh_market() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    assert!(!market.is_settled());
    assert!(market.raw_settlement_price().is_none());

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

// === status state machine ===

#[test]
fun status_is_active_before_expiry() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(BEFORE_EXPIRY);

    assert_eq!(market.status(&clock), market_oracle::status_active());

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
}

#[test]
fun status_pending_at_and_after_expiry() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);
    let mut clock = clock::create_for_testing(ctx);

    // Exactly at expiry: status flips to pending_settlement.
    clock.set_for_testing(AT_EXPIRY);
    assert_eq!(market.status(&clock), market_oracle::status_pending_settlement());

    // After expiry: stays pending until settle_if_possible runs.
    clock.set_for_testing(AFTER_EXPIRY);
    assert_eq!(market.status(&clock), market_oracle::status_pending_settlement());

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
}

// === Status / source code accessors ===

#[test]
fun status_constants_are_distinct() {
    // Other modules switch on these codes; they must be pairwise distinct.
    assert!(market_oracle::status_active() != market_oracle::status_pending_settlement());
    assert!(market_oracle::status_active() != market_oracle::status_settled());
    assert!(market_oracle::status_pending_settlement() != market_oracle::status_settled());
}

#[test]
fun source_constants_are_distinct() {
    assert!(market_oracle::source_pyth() != market_oracle::source_block_scholes());
}

// === Block Scholes default getters ===

#[test]
fun default_block_scholes_state_is_zero() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let cap = market_oracle::create_cap(&admin_cap, ctx);
    let market = market_oracle::create_test_market_oracle(EXPIRY_MS, &cap, ctx);

    assert_eq!(market.block_scholes_spot(), 0);
    assert_eq!(market.block_scholes_forward(), 0);
    assert_eq!(market.block_scholes_price_source_timestamp_ms(), 0);
    assert_eq!(market.block_scholes_price_update_timestamp_ms(), 0);
    assert_eq!(market.block_scholes_svi_source_timestamp_ms(), 0);
    assert_eq!(market.block_scholes_svi_update_timestamp_ms(), 0);

    let svi = market.block_scholes_svi();
    assert_eq!(svi.a(), 0);
    assert_eq!(svi.b(), 0);
    assert!(svi.rho().is_zero());
    assert!(svi.m().is_zero());
    assert_eq!(svi.sigma(), 0);

    destroy(market);
    destroy(cap);
    destroy(admin_cap);
}

// === new_svi_params constructor ===

#[test]
fun new_svi_params_round_trips_all_five_fields() {
    let rho = i64::from_parts(123_456_789, true); // negative non-zero
    let m = i64::from_u64(987_654_321);
    let svi = market_oracle::new_svi_params(11, 22, rho, m, 33);

    assert_eq!(svi.a(), 11);
    assert_eq!(svi.b(), 22);
    let svi_rho = svi.rho();
    assert_eq!(svi_rho.magnitude(), 123_456_789);
    assert!(svi_rho.is_negative());
    let svi_m = svi.m();
    assert_eq!(svi_m.magnitude(), 987_654_321);
    assert!(!svi_m.is_negative());
    assert_eq!(svi.sigma(), 33);
}

#[test]
fun new_svi_params_accepts_zero_fields() {
    let svi = market_oracle::new_svi_params(0, 0, i64::zero(), i64::zero(), 0);
    assert_eq!(svi.a(), 0);
    assert_eq!(svi.b(), 0);
    assert!(svi.rho().is_zero());
    assert!(svi.m().is_zero());
    assert_eq!(svi.sigma(), 0);
}
