// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Vault-level flow coverage for the async LP layer: the genesis `lock_capital` mint,
/// the bootstrap precondition on the flush, and the request-attempt count that
/// `finish_flush` reads from `ProtocolConfig`.
///
/// The fixture shares an empty `sui::accumulator::AccumulatorRoot` through
/// `accumulator_support` (the framework exposes `create_for_testing`, callable as
/// `@0x0`), so the attempt-count tests drive the production `plp::request_supply`
/// against a real `AccountBundle` and cover the account-custody pull and the queue
/// write on the same path as the flush's refund-or-carry decision. Not covered here: the
/// vault-level `cancel_*` entrypoints, and `request_withdraw` — a unit-test root carries
/// no settlement funds (`packages/account/ACCUMULATOR_TESTING_STATUS.md`), so a flush
/// fill's PLP never reaches account custody to be withdrawn. Flush valuation is
/// covered in `pool_valuation_flow_tests`, while the drain economics (proportional
/// shares, FIFO-until-dry, per-queue budgets, frozen mark) and the cancel refund +
/// recipient check are covered root-free against a standalone `LpBook` in
/// `lp_book_tests`.
#[test_only]
module deepbook_predict::lp_flow_tests;

use deepbook_predict::{
    constants::{min_bootstrap_liquidity as min_bootstrap, min_supply_request as min_supply},
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    test_constants
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

/// Account funding for the LP staging the request; well above `min_supply_request`.
const LP_DEPOSIT: u64 = 1_000_000_000;
/// No fill limit, so only pool capacity can stop the request.
const NO_MIN_OUT: u64 = 0;

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
/// compiled constant. Staged through the production `request_supply` + flush path
/// because the drain-level tests pass the value in by hand and so structurally cannot
/// see a disconnected knob. Runs on a pool with no live markets, so the mark is simply
/// idle over supply and the request can only leave the queue by missing its limit.
#[test]
fun flush_refunds_limit_miss_at_the_default_attempt_count() {
    let (mut fx, mut account) = setup_pool_with_lp();
    queue_unfillable_supply(&mut fx, &mut account);
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    flush(&mut fx);

    // Refunded on its first miss: queue empty, and the genesis lock is all that exists.
    assert_pending_and_supply(&mut fx, 0, min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The same request against a raised attempt count survives its first two flushes,
/// which is only possible if the flush actually reads the configured value.
#[test]
fun flush_carries_limit_miss_when_admin_raises_the_attempt_count() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_attempts(&mut fx, 3);
    queue_unfillable_supply(&mut fx, &mut account);

    flush(&mut fx);
    // Still queued after one miss, because the admin allowed three attempts.
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 1, min_supply!());

    // The third miss exhausts the allowance and refunds it.
    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 0, min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Pool-value cap is read from config by the flush ===

/// The cap must reach the drain from `ProtocolConfig`, not a constant. The genesis
/// lock puts pool value at 10 DUSDC; a 20 DUSDC cap leaves 10 of headroom, which the
/// first deposit exactly fills, so the next identical deposit finds no room and waits.
#[test]
fun flush_holds_a_supply_that_would_breach_the_configured_pool_cap() {
    let (mut fx, mut account) = setup_pool_with_lp();
    set_max_pool_value(&mut fx, 20_000_000);
    // Consume the whole 10 DUSDC of headroom first.
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);
    flush(&mut fx);
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    // Held for capacity: the second deposit minted nothing and is still queued.
    assert_pending_and_supply(&mut fx, 1, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

/// The control: the identical deposit fills when the pool is uncapped, so the test
/// above is measuring the cap rather than some other refund path.
#[test]
fun flush_fills_the_same_supply_when_the_pool_is_uncapped() {
    let (mut fx, mut account) = setup_pool_with_lp();
    queue_supply(&mut fx, &mut account, NO_MIN_OUT);

    flush(&mut fx);

    // 10 DUSDC minted 1:1 against the 10 DUSDC genesis lock at a 1.0 mark.
    assert_pending_and_supply(&mut fx, 0, 2 * min_supply!());

    helpers::return_account_bundle(account);
    fx.finish();
}

// === Helpers ===

/// A bootstrapped pool (no live markets) plus a funded LP account.
fun setup_pool_with_lp(): (helpers::Fixture, helpers::AccountBundle) {
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(min_supply!());
    let trader = fx.create_funded_manager(LP_DEPOSIT);
    let account = fx.take_account_bundle(&trader);
    (fx, account)
}

/// Queue a minimum-sized supply asking for an output no mark can quote, through the
/// production entrypoint.
fun queue_unfillable_supply(fx: &mut helpers::Fixture, account: &mut helpers::AccountBundle) {
    queue_supply(fx, account, unattainable_min_out());
}

/// Queue a minimum-sized supply at `min_plp_out` through the production entrypoint.
fun queue_supply(
    fx: &mut helpers::Fixture,
    account: &mut helpers::AccountBundle,
    min_plp_out: u64,
) {
    fx.scenario_mut().next_tx(test_constants::alice());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    fx.request_supply_direct(&mut vault, &config, account, min_supply!(), min_plp_out);
    return_shared(vault);
    return_shared(config);
}

fun set_attempts(fx: &mut helpers::Fixture, attempts: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_lp_request_limit_flush_attempts(&mut config, attempts);
    return_shared(config);
}

fun set_max_pool_value(fx: &mut helpers::Fixture, max_pool_value: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    fx.set_max_lp_pool_value(&mut config, max_pool_value);
    return_shared(config);
}

fun assert_pending_and_supply(fx: &mut helpers::Fixture, pending: u64, total_supply: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.supply_requests_pending(), pending);
    assert_eq!(vault.plp_total_supply(), total_supply);
    return_shared(vault);
}

/// No executable mark can quote this, so a request carrying it misses every flush.
fun unattainable_min_out(): u64 { std::u64::max_value!() }

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
