// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the genesis-lock + bootstrap gates of the async LP layer.
///
/// The async LP request/cancel entrypoints (`request_supply` / `request_withdraw` /
/// `cancel_*`) pull from / refund to the manager's internal custody and therefore
/// auto-settle from a `sui::accumulator::AccumulatorRoot`, which a Move unit test
/// cannot construct (private `create`, `@0x0`-only). So the vault-level
/// request / flush / circuit-breaker paths live in the untested outer layer; the
/// flush DRAIN economics (proportional shares, FIFO-until-dry, per-queue budgets,
/// frozen mark) and the manager-routed cancel refund + recipient check are re-covered
/// root-free against a standalone `LpBook` in `lp_book_tests`. This file keeps only
/// the root-free vault gates: the genesis `lock_capital` mint and the bootstrap
/// precondition on the flush.
#[test_only]
module deepbook_predict::lp_flow_tests;

use deepbook_predict::{
    constants::{
        min_bootstrap_liquidity as min_bootstrap,
        min_supply_request as min_supply,
        min_withdraw_request as min_withdraw
    },
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    test_constants
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

// === Genesis lock + bootstrapped gates ===

#[test]
fun lock_capital_mints_locked_liquidity_and_funds_idle() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // The lock mints `amount` permanent PLP (held by the book, delivered to no one) and
    // joins the DUSDC into idle, so total_supply == idle == amount at a 1.0 mark.
    assert_eq!(vault.plp_total_supply(), min_supply!());
    assert_eq!(vault.idle_balance(), min_supply!());
    assert_eq!(vault.supply_requests_pending(), 0);

    return_shared(vault);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EAlreadyBootstrapped)]
fun lock_capital_twice_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    fx.bootstrap_lock(min_supply!()); // total_supply is already > 0
    abort 999
}

#[test, expected_failure(abort_code = plp::EBelowMinBootstrapLiquidity)]
fun lock_capital_below_floor_aborts() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_bootstrap!() - 1); // below the genesis floor
    abort 999
}

#[test]
fun min_bootstrap_liquidity_covers_withdraw_dust_band() {
    // The genesis floor must keep total_supply at or above the withdraw dust band, so the
    // (deleted) EPlpSupplyDust band is structurally unreachable once the pool is locked.
    assert!(min_bootstrap!() >= min_withdraw!());
}

#[test, expected_failure(abort_code = plp::ENotBootstrapped)]
fun flush_before_bootstrap_aborts() {
    let mut fx = helpers::setup_market_default();
    flush(&mut fx); // start_pool_valuation requires total_supply > 0
    abort 999
}

// === Helpers ===

/// Run one flush over the empty market set (pool NAV == idle), draining both queues
/// fully, and discard the result.
fun flush(fx: &mut helpers::Fixture) {
    flush_with_budgets(fx, option::none(), option::none());
}

/// Run one flush bounding how many supply / withdraw requests each queue may fill.
/// Started through the sole flush authority, the market-deployer `MarketLifecycleCap`.
fun flush_with_budgets(
    fx: &mut helpers::Fixture,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let val = fx.start_flush(&mut config, &vault);
    let _ = val.finish_flush(
        &mut vault,
        &mut config,
        supply_budget,
        withdraw_budget,
        fx.scenario_mut().ctx(),
    );
    return_shared(config);
    return_shared(vault);
}
