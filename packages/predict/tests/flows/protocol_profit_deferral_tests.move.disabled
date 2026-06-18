// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for the protocol-cut materialization deferral.
///
/// A market's terminal profit is recognized at its settled sweep, but the cash
/// backing the protocol's cut may have been swept to idle earlier and redeployed to
/// fund another active market before the profitable market settles. The cut is split
/// from idle, so an unguarded split would underflow and brick the settled sweep (and,
/// inside the flush, the whole pool valuation). These tests pin that the cut is
/// instead realized up to available idle and the remainder carried in
/// `pending_protocol_profit` — excluded from LP value until a later sweep drains it.
///
/// All cash here moves through production paths (rebalance sweep / top-up, settled
/// sweep, materialize). `seed_market_cash` stands in for premiums a market collected,
/// the only test-only seam, so a market can return more than the pool funded it
/// (= terminal profit).
#[test_only]
module deepbook_predict::protocol_profit_deferral_tests;

use deepbook_predict::{
    admin,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    test_constants
};
use fixed_math::math::float_scaling as float;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

#[test]
/// Permissionless settled sweep when idle < the protocol cut: the cut is realized up
/// to idle, the remainder carried, and a later live sweep drains the carried cut.
fun settled_sweep_defers_protocol_cut_then_drains_on_later_sweep() {
    let f = constants::expiry_cash_floor!();
    let mut fx = helpers::setup_market_default();
    // 0.9 of profit to the protocol: high but sub-100%, so a small idle redeploy makes
    // the cut exceed available idle at materialization.
    set_profit_share(&mut fx, 9 * float!() / 10);
    let e_a = fx.create_expiry(test_constants::default_expiry_ms());
    let e_b = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);

    // Phase 1: market A holds 5x the cash floor (collected premiums); the live sweep
    // returns the 4x surplus above its (no-order) cash-floor target to idle. None of
    // it was funded by the pool, so it is pure terminal profit waiting to materialize.
    let (idle1, _, _, _) = rebalance_with_seed(&mut fx, e_a, 5 * f);
    assert_eq!(idle1, 4 * f);

    // Phase 2: fund empty market B to its cash floor, redeploying part of that idle.
    let (idle2, pending2, _, _) = rebalance_with_seed(&mut fx, e_b, 0);
    assert_eq!(idle2, 3 * f);
    assert_eq!(pending2, 0);

    // Phase 3: settle A. profit = 5f, cut = 0.9 * 5f = 4.5f, but idle at materialize is
    // only 4f (3f + the 1f A releases back). Old code's bare split underflowed here;
    // now 4f is realized to the reserve and 0.5f is carried.
    fx.set_clock_for_testing(test_constants::default_expiry_ms());
    let (idle3, pending3, reserve3, active3) = settle_market(&mut fx, e_a);
    assert_eq!(pending3, f / 2);
    assert_eq!(reserve3, 4 * f);
    assert_eq!(idle3, 0);
    assert_eq!(active3, 1);

    // Phase 4: B sweeps a fresh 0.5f surplus to idle; the sweep drains the carried cut,
    // so the reserve finally holds the full 4.5f cut and nothing is pending.
    let (_, pending4, reserve4, _) = rebalance_with_seed(&mut fx, e_b, f / 2);
    assert_eq!(pending4, 0);
    assert_eq!(reserve4, 9 * f / 2);

    fx.finish();
}

#[test]
/// The flush valuing a settled market whose cut exceeds idle must complete, not brick:
/// the deferral happens inside `value_expiry` and `finish_flush` still returns. With the
/// pool genesis-locked, the carried protocol cut is excluded from LP value separately, so
/// pricing nets idle (f) minus the pending cut (f-l) to exactly the locked liquidity (l).
fun flush_completes_when_settled_cut_exceeds_idle() {
    let f = constants::expiry_cash_floor!();
    let l = constants::min_bootstrap_liquidity!();
    let mut fx = helpers::setup_market_default();
    fx.bootstrap_lock(l); // genesis lock so the flush is reachable (total_supply > 0)
    // Full cut (boundary of the allowed share): the entire 5f profit is the protocol's.
    set_profit_share(&mut fx, float!());
    let e_a = fx.create_expiry(test_constants::default_expiry_ms());
    let e_b = fx.create_expiry(test_constants::default_expiry_ms() + 86_400_000);

    rebalance_with_seed(&mut fx, e_a, 5 * f);
    let (idle, _, _, _) = rebalance_with_seed(&mut fx, e_b, 0);
    assert_eq!(idle, 3 * f + l); // 4f swept from A, f redeployed to B, atop the genesis lock

    // Both markets past expiry; the flush settles A (deferring its cut under low idle)
    // then B (break-even, no cut) and prices the pool.
    fx.set_clock_for_testing(test_constants::default_expiry_ms() + 86_400_000);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let bs = fx.scenario_mut().take_shared_by_id<BlockScholesFeed>(fx.bs_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut m_a = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e_a);
    let mut m_b = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(e_b);
    fx.insert_exact_settlement_spot(&mut pyth, m_a.expiry(), test_constants::default_live_price());
    fx.insert_exact_settlement_spot(&mut pyth, m_b.expiry(), test_constants::default_live_price());

    let mut val = fx.start_flush(&mut config, &vault);
    fx.value_expiry(&mut val, &mut vault, &mut m_a, &config, &oracle_registry, &pyth, &bs);
    fx.value_expiry(&mut val, &mut vault, &mut m_b, &config, &oracle_registry, &pyth, &bs);
    // Reaching here proves the flush did not brick on A's under-idle materialize.
    let pool_nav = val.finish_flush(
        &mut vault,
        &mut config,
        option::none(),
        option::none(),
        fx.scenario_mut().ctx(),
    );

    // cut = 5f, idle at A's materialize = l+4f -> l+4f realized, f-l carried. B releases
    // its f funding back, so idle ends at f with f-l still pending (excluded from value).
    // LP value = idle (f) - pending (f-l) = l, the genesis-locked liquidity priced at 1.0.
    assert_eq!(pool_nav, l);
    assert_eq!(vault.pending_protocol_profit(), f - l);
    assert_eq!(vault.protocol_reserve_balance(), 4 * f + l);
    assert_eq!(vault.idle_balance(), f);
    assert_eq!(vault.active_expiry_markets().length(), 0);

    return_shared(config);
    return_shared(pyth);
    return_shared(bs);
    return_shared(oracle_registry);
    return_shared(vault);
    return_shared(m_a);
    return_shared(m_b);
    fx.finish();
}

// === Helpers ===

/// Set the protocol reserve profit share through the real admin path.
fun set_profit_share(fx: &mut helpers::Fixture, share: u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let admin_cap = admin::new(fx.scenario_mut().ctx());
    config.set_protocol_reserve_profit_share(&admin_cap, share);
    destroy(admin_cap);
    return_shared(config);
}

/// Seed `extra` cash into a live market, then rebalance it (top-up toward the cash
/// floor when under-funded, sweep the surplus to idle when over-funded). Returns the
/// post-op `(idle, pending_protocol_profit, protocol_reserve, active_market_count)`.
fun rebalance_with_seed(
    fx: &mut helpers::Fixture,
    expiry_id: ID,
    extra: u64,
): (u64, u64, u64, u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    if (extra > 0) {
        fx.seed_market_cash(&mut market, extra);
    };
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);
    let (idle, pending, reserve, active) = vault_snapshot(&vault);
    return_shared(market);
    return_shared(vault);
    return_shared(oracle_registry);
    return_shared(pyth);
    return_shared(config);
    (idle, pending, reserve, active)
}

/// Drive a past-expiry market through its passive settled sweep via the permissionless
/// standalone rebalance (the path that materializes terminal profit). Returns the same
/// post-op vault snapshot as `rebalance_with_seed`.
fun settle_market(fx: &mut helpers::Fixture, expiry_id: ID): (u64, u64, u64, u64) {
    fx.scenario_mut().next_tx(test_constants::admin());
    let config = fx.scenario_mut().take_shared<ProtocolConfig>();
    let mut pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(fx.pyth_id());
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut market = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_id);
    fx.insert_exact_settlement_spot(
        &mut pyth,
        market.expiry(),
        test_constants::default_live_price(),
    );
    fx.rebalance_expiry_cash(&mut vault, &mut market, &config, &oracle_registry, &pyth);
    let (idle, pending, reserve, active) = vault_snapshot(&vault);
    return_shared(market);
    return_shared(vault);
    return_shared(oracle_registry);
    return_shared(pyth);
    return_shared(config);
    (idle, pending, reserve, active)
}

/// `(idle, pending_protocol_profit, protocol_reserve, active_market_count)`.
fun vault_snapshot(vault: &PoolVault): (u64, u64, u64, u64) {
    (
        vault.idle_balance(),
        vault.pending_protocol_profit(),
        vault.protocol_reserve_balance(),
        vault.active_expiry_markets().length(),
    )
}
