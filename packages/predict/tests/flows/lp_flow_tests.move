// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the genesis-lock + bootstrap gates of the async LP layer.
///
/// The async LP request/cancel entrypoints (`request_supply` / `request_withdraw` /
/// `cancel_*`) pull from / refund to the manager's internal custody and therefore
/// auto-settle from a `sui::accumulator::AccumulatorRoot`, which a Move unit test
/// cannot construct (private `create`, `@0x0`-only). So the vault-level
/// request / cancel custody paths live in the accumulator-bound outer layer. Flush
/// valuation is covered in `pool_valuation_flow_tests`, while the drain economics
/// (proportional shares, FIFO-until-dry, per-queue budgets, frozen mark) and the
/// manager-routed cancel refund + recipient check are re-covered root-free against
/// a standalone `LpBook` in `lp_book_tests`. This file keeps only the root-free
/// vault gates: the genesis `lock_capital` mint and the bootstrap precondition on
/// the flush.
#[test_only]
module deepbook_predict::lp_flow_tests;

use deepbook_predict::{
    constants::{min_bootstrap_liquidity as min_bootstrap, min_supply_request as min_supply},
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::assert_eq;
use sui::{coin, test_scenario::return_shared};

/// No executable mark can quote this, so a request carrying it misses every flush.
const UNATTAINABLE_MIN_OUT: u64 = 18_446_744_073_709_551_615;

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

#[test, expected_failure(abort_code = plp::ENotBootstrapped)]
fun flush_before_bootstrap_aborts() {
    let mut fx = helpers::setup_market_default();
    flush(&mut fx); // start_pool_valuation requires total_supply > 0
    abort 999
}

// === Attempt count is read from config by the flush ===

/// `finish_flush` must take the attempt count from `ProtocolConfig`, not from a
/// compiled constant. Staged end-to-end because the drain-level tests pass the value
/// in by hand and so cannot see a disconnected knob: at the shipped default of one
/// attempt, a limit-missing request is refunded by the flush that reaches it.
#[test]
fun flush_refunds_limit_miss_at_the_default_attempt_count() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    queue_unfillable_supply(&mut fx);

    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // Refunded on its first miss: queue empty, and the genesis lock is all that was minted.
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.plp_total_supply(), min_supply!());
    return_shared(vault);

    fx.finish();
}

/// The same request against a raised attempt count survives its first flush instead,
/// which is only possible if the flush actually reads the configured value.
#[test]
fun flush_carries_limit_miss_when_admin_raises_the_attempt_count() {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    set_attempts(&mut fx, 3);
    queue_unfillable_supply(&mut fx);

    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // Still queued after one miss, because the admin allowed three attempts.
    assert_eq!(vault.supply_requests_pending(), 1);
    return_shared(vault);

    // Two more flushes exhaust the allowance; the third miss refunds it.
    flush(&mut fx);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.plp_total_supply(), min_supply!());
    return_shared(vault);

    fx.finish();
}

// === Helpers ===

/// Queue a minimum-sized supply asking for an output no mark can quote, so it misses
/// its limit on every flush regardless of pool NAV.
fun queue_unfillable_supply(fx: &mut helpers::Fixture) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
    plp::queue_supply_for_testing(
        &mut vault,
        payment,
        test_constants::admin().to_id(),
        test_constants::admin(),
        UNATTAINABLE_MIN_OUT,
    );
    return_shared(vault);
}

fun set_attempts(fx: &mut helpers::Fixture, attempts: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_lp_request_limit_flush_attempts(&mut config, attempts);
    return_shared(config);
}

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
