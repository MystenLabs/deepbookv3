// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Flow coverage for the async LP layer: request minimums, manager-routed
/// cancellation (refund deposits straight back into the requesting manager), and
/// the flush drain (`finish_flush`) — bootstrap 1:1, proportional supply/withdraw at
/// a frozen mark, per-request refund-and-continue isolation, the per-flush cap with
/// carry-over, FIFO-until-idle-dry, and epoch-snapshot consistency (two withdrawals
/// in one flush price at the SAME frozen mark). Flushes run over an empty market set
/// so `pool_nav == idle` exactly; every expected share/payout is hand-computed
/// independently of the contract. Solvency invariants (PLP supply and idle deltas)
/// are asserted, not just returns.
///
/// The minted PLP / paid DUSDC are delivered to the recipient's balance accumulator,
/// which a Move unit test cannot read back without an `AccumulatorRoot`. So
/// withdraw-side tests escrow a `coin::mint_for_testing<PLP>` stand-in for the
/// accumulator-delivered shares (the vault's `total_supply` is set consistently by a
/// real bootstrap supply first), and delivery/settle of fills is asserted only
/// indirectly (queue drained, escrow consumed, supply minted/burned). See
/// TODO(test-accumulator-root).
#[test_only]
module deepbook_predict::lp_flow_tests;

use deepbook_predict::{
    constants::{min_supply_request as min_supply, min_withdraw_request as min_withdraw},
    flow_test_helpers as helpers,
    plp::{Self, PoolVault, PLP},
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario::return_shared};

const BOB: address = @0xB0B;

// === Request minimums ===

#[test, expected_failure(abort_code = plp::EBelowMinSupplyRequest)]
fun request_supply_below_min_aborts() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let payment = coin::mint_for_testing<DUSDC>(min_supply!() - 1, fx.scenario_mut().ctx());
    vault.request_supply(&manager, payment);
    abort 999
}

#[test, expected_failure(abort_code = plp::EBelowMinWithdrawRequest)]
fun request_withdraw_below_min_aborts() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let lp = coin::mint_for_testing<PLP>(min_withdraw!() - 1, fx.scenario_mut().ctx());
    vault.request_withdraw(&manager, lp);
    abort 999
}

// === Cancellation refunds into the requesting manager ===

#[test]
fun cancel_supply_refunds_dusdc_into_manager() {
    let mut fx = helpers::setup_market_default();
    let mut manager = fx.create_funded_manager(0);
    let index = enqueue_supply(&mut fx, &manager, min_supply!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    vault.cancel_supply_request(&mut manager, index, fx.scenario_mut().ctx());

    // Escrow returned straight to the manager's internal DUSDC custody; the queue is
    // empty again and holds no escrow.
    assert_eq!(manager.internal_balance<DUSDC>(), min_supply!());
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.supply_queue().escrow_value(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

#[test]
fun cancel_withdraw_refunds_plp_into_manager() {
    let mut fx = helpers::setup_market_default();
    let mut manager = fx.create_funded_manager(0);
    let index = enqueue_withdraw(&mut fx, &manager, min_withdraw!());

    fx.scenario_mut().next_tx(test_constants::alice());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    vault.cancel_withdraw_request(&mut manager, index, fx.scenario_mut().ctx());

    assert_eq!(manager.internal_balance<PLP>(), min_withdraw!());
    assert_eq!(vault.withdraw_requests_pending(), 0);
    assert_eq!(vault.withdraw_queue().escrow_value(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::ENotRequestOwner)]
fun cancel_with_non_recipient_manager_aborts() {
    let mut fx = helpers::setup_market_default();
    let manager_a = fx.create_funded_manager(0);
    let mut manager_b = fx.create_funded_manager_as(BOB, 0);
    // Alice's manager owns the request...
    let index = enqueue_supply(&mut fx, &manager_a, min_supply!());

    // ...so Bob's manager (a different recipient) cannot cancel it.
    fx.scenario_mut().next_tx(BOB);
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    vault.cancel_supply_request(&mut manager_b, index, fx.scenario_mut().ctx());
    abort 999
}

// === Bootstrap supply ===

#[test]
fun bootstrap_supply_mints_one_to_one_and_joins_idle() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    enqueue_supply(&mut fx, &manager, min_supply!());

    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // First-ever supply: empty pool, so 1:1. Escrow joined idle, shares minted.
    assert_eq!(vault.plp_total_supply(), min_supply!());
    assert_eq!(vault.idle_balance(), min_supply!());
    assert_eq!(vault.supply_requests_pending(), 0);
    assert_eq!(vault.supply_queue().escrow_value(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

#[test, expected_failure(abort_code = plp::EBootstrapNavNotEmpty)]
fun bootstrap_supply_with_nonempty_nav_aborts() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // Idle exists but no PLP has ever been minted: bootstrap pricing is undefined,
    // so the flush aborts rather than mint mispriced shares.
    seed_idle(&mut fx, 50_000_000);
    enqueue_supply(&mut fx, &manager, min_supply!());

    flush(&mut fx);
    abort 999
}

// === Priced supply / withdraw at a frozen mark of 2.0 ===

#[test]
fun priced_supply_mints_proportional_shares() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // Bootstrap 30 DUSDC -> 30e6 PLP, idle 30e6. Then double idle to mark 2.0.
    let bootstrap = 30_000_000;
    enqueue_supply(&mut fx, &manager, bootstrap);
    flush(&mut fx);
    seed_idle(&mut fx, bootstrap); // idle 60e6, supply 30e6 -> mark 2.0

    // Supply 20e6 at mark 2.0: shares = 20e6 * 30e6 / 60e6 = 10e6.
    let supply = 20_000_000;
    enqueue_supply(&mut fx, &manager, supply);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.plp_total_supply(), 40_000_000); // 30e6 + 10e6
    assert_eq!(vault.idle_balance(), 80_000_000); // 60e6 + 20e6 escrow joined
    assert_eq!(vault.supply_requests_pending(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

#[test]
fun priced_withdraw_burns_and_pays_from_idle() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    let bootstrap = 30_000_000;
    enqueue_supply(&mut fx, &manager, bootstrap);
    flush(&mut fx);
    seed_idle(&mut fx, bootstrap); // idle 60e6, supply 30e6 -> mark 2.0

    // Withdraw 10e6 PLP at mark 2.0: dusdc = 10e6 * 60e6 / 30e6 = 20e6.
    let withdraw = 10_000_000;
    enqueue_withdraw(&mut fx, &manager, withdraw);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.plp_total_supply(), 20_000_000); // 30e6 - 10e6 burned
    assert_eq!(vault.idle_balance(), 40_000_000); // 60e6 - 20e6 paid out
    assert_eq!(vault.withdraw_requests_pending(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

// === Per-request failure isolation ===

#[test]
fun zero_share_supply_refunds_and_drain_continues() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // Bootstrap 10e6 PLP, then raise idle to 2e14 so the mark is 2e7 per share.
    enqueue_supply(&mut fx, &manager, min_supply!());
    flush(&mut fx);
    let high_pool_value = 200_000_000_000_000; // 2e14
    seed_idle(&mut fx, high_pool_value - min_supply!()); // idle -> 2e14

    // First a dust supply that prices to 0 shares (10e6 * 10e6 / 2e14 = 0), then a
    // large supply that fills (2e14 * 10e6 / 2e14 = 10e6 shares). The drain must
    // refund the first and still fill the second.
    enqueue_supply(&mut fx, &manager, min_supply!());
    enqueue_supply(&mut fx, &manager, high_pool_value);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // Only the large supply minted (10e6) and joined idle; the dust supply was
    // refunded (its escrow neither minted nor joined idle). Both were processed.
    assert_eq!(vault.plp_total_supply(), 20_000_000); // 10e6 + 10e6
    assert_eq!(vault.idle_balance(), high_pool_value + high_pool_value); // 4e14
    assert_eq!(vault.supply_requests_pending(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

// === Per-flush cap and carry-over ===

#[test]
fun flush_caps_at_max_requests_and_carries_rest() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // 101 bootstrap supplies (empty pool, total_supply 0 -> all mint 1:1).
    let total = 101u64;
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut i = 0;
    while (i < total) {
        let coin = coin::mint_for_testing<DUSDC>(min_supply!(), fx.scenario_mut().ctx());
        vault.request_supply(&manager, coin);
        i = i + 1;
    };
    return_shared(vault);

    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // Exactly 100 of 101 filled; the last carries with the tail untouched.
    assert_eq!(vault.plp_total_supply(), 100 * min_supply!());
    assert_eq!(vault.idle_balance(), 100 * min_supply!());
    assert_eq!(vault.supply_requests_pending(), 1);
    assert_eq!(vault.supply_queue().head(), 100);
    assert_eq!(vault.supply_queue().tail(), 101);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

// === FIFO-until-dry ===

#[test]
fun withdrawals_stop_when_idle_is_dry_and_carry() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // Bootstrap 30e6 PLP, idle 30e6, mark 1.0.
    let bootstrap = 30_000_000;
    enqueue_supply(&mut fx, &manager, bootstrap);
    flush(&mut fx);

    // Two 20e6 withdrawals: the first fills (idle 30e6 -> 10e6); the second needs
    // 20e6 but idle is only 10e6, so the pass stops and carries it.
    let withdraw = 20_000_000;
    enqueue_withdraw(&mut fx, &manager, withdraw);
    enqueue_withdraw(&mut fx, &manager, withdraw);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    assert_eq!(vault.plp_total_supply(), 10_000_000); // only the first 20e6 burned
    assert_eq!(vault.idle_balance(), 10_000_000); // only the first 20e6 paid
    assert_eq!(vault.withdraw_requests_pending(), 1); // second carried
    assert_eq!(vault.withdraw_queue().head(), 1); // advanced only past the first
    assert_eq!(vault.withdraw_queue().tail(), 2);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

// === Epoch-snapshot consistency ===

#[test]
fun two_withdrawals_share_one_frozen_mark() {
    let mut fx = helpers::setup_market_default();
    let manager = fx.create_funded_manager(0);
    // Bootstrap 30e6 PLP, then idle -> 50e6 so the mark is 5/3 (a fraction that rounds).
    enqueue_supply(&mut fx, &manager, 30_000_000);
    flush(&mut fx);
    seed_idle(&mut fx, 20_000_000); // idle 50e6, supply 30e6 -> mark 5/3

    // Two identical 10e6 withdrawals. Each prices at the FROZEN (50e6, 30e6) mark:
    //   floor(10e6 * 50e6 / 30e6) = floor(16_666_666.67) = 16_666_666 each.
    // If the second repriced against post-first state it would round to 16_666_667,
    // so the idle-after value distinguishes frozen from repriced.
    enqueue_withdraw(&mut fx, &manager, 10_000_000);
    enqueue_withdraw(&mut fx, &manager, 10_000_000);
    flush(&mut fx);

    fx.scenario_mut().next_tx(test_constants::admin());
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    // 50_000_000 - 2 * 16_666_666 = 16_666_668 (frozen). Repriced would leave 16_666_667.
    assert_eq!(vault.idle_balance(), 16_666_668);
    assert_eq!(vault.plp_total_supply(), 10_000_000); // 30e6 - 2 * 10e6 burned
    assert_eq!(vault.withdraw_requests_pending(), 0);

    return_shared(vault);
    destroy(manager);
    fx.finish();
}

// === Helpers ===

/// Seed pool idle DUSDC directly (no PLP minted), to set a non-trivial mark.
fun seed_idle(fx: &mut helpers::Fixture, amount: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    vault.receive_idle_for_testing(coin::mint_for_testing<DUSDC>(amount, fx.scenario_mut().ctx()));
    return_shared(vault);
}

/// Queue one supply request for `manager`, escrowing freshly minted DUSDC.
fun enqueue_supply(fx: &mut helpers::Fixture, manager: &PredictManager, amount: u64): u64 {
    fx.scenario_mut().next_tx(manager.owner());
    let coin = coin::mint_for_testing<DUSDC>(amount, fx.scenario_mut().ctx());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let index = vault.request_supply(manager, coin);
    return_shared(vault);
    index
}

/// Queue one withdraw request for `manager`, escrowing a `mint_for_testing` PLP
/// stand-in for accumulator-delivered shares (the vault's `total_supply` is set
/// consistently by a prior bootstrap supply, so the burn never underflows).
fun enqueue_withdraw(fx: &mut helpers::Fixture, manager: &PredictManager, amount: u64): u64 {
    fx.scenario_mut().next_tx(manager.owner());
    let lp = coin::mint_for_testing<PLP>(amount, fx.scenario_mut().ctx());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let index = vault.request_withdraw(manager, lp);
    return_shared(vault);
    index
}

/// Run one flush over the empty market set (pool NAV == idle) and discard the result.
fun flush(fx: &mut helpers::Fixture) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let val = plp::start_pool_valuation(&mut config, &vault);
    let _ = val.finish_flush(&mut vault, &mut config, fx.scenario_mut().ctx());
    return_shared(config);
    return_shared(vault);
}
