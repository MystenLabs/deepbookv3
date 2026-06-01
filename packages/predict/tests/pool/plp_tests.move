// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_tests;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    constants::{Self, float_scaling as float},
    expiry_market::ExpiryMarket,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::{Self, PLP, PoolVault},
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario, return_shared}
};

const PYTH_FEED_ID: u32 = 1;
const NOW_MS: u64 = 100_000;
const EXPIRY_MS: u64 = 200_000;
const SECOND_EXPIRY_MS: u64 = 400_000;
const TICK_SIZE: u64 = 1_000_000_000;
const CREATION_SPOT: u64 = 50_100_000_000_000;
const SETTLEMENT_PRICE: u64 = 100_000_000_000;
const LIVE_SOURCE_TIMESTAMP_MS: u64 = 99_000;

const INITIAL_SUPPLY: u64 = 300_000_000_000;
const PROTOCOL_RESERVE_SHARE: u64 = 400_000_000;
const EXTRA_EXPIRY_CASH: u64 = 100_000_000_000;
const PARTIAL_LOSS: u64 = 20_000_000_000;
const SECOND_EXPIRY_PROFIT: u64 = 90_000_000_000;
const NAV_TEST_SUPPLY: u64 = 36_000_000_000;
const NAV_TEST_EXPECTED_SHARES: u64 = 30_000_000_000;
const REGISTERED_EXPIRY_ID: address = @0xA11C;

/// Scenario-local objects shared by the PLP tests.
public struct Fixture {
    scenario: Scenario,
    registry: Registry,
    admin_cap: AdminCap,
    config: ProtocolConfig,
    cap: MarketOracleCap,
    clock: Clock,
    vault_id: ID,
    pyth_id: ID,
    initial_plp: Coin<PLP>,
}

// === Expiry Registration ===

#[test]
fun register_expiry_market_adds_zero_flow_with_default_funding() {
    let fixture = setup_pool_with_pyth();
    let expiry_id = REGISTERED_EXPIRY_ID.to_id();

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    vault.register_expiry_market(expiry_id);

    assert_eq!(vault.idle_balance(), INITIAL_SUPPLY);
    assert_eq!(vault.active_expiry_markets().length(), 1);
    assert_eq!(vault.active_expiry_markets()[0], expiry_id);
    let (sent_to_expiry, received_from_expiry) = vault.expiry_flow_amounts(expiry_id);
    assert_eq!(sent_to_expiry, 0);
    assert_eq!(received_from_expiry, 0);
    assert_eq!(
        vault.max_expiry_funding(expiry_id),
        config_constants::default_max_expiry_funding!(),
    );
    assert_eq!(vault.profit_basis_debits(), 0);
    assert_eq!(vault.profit_basis_credits(), 0);

    return_shared(vault);
    finish(fixture);
}

// === Max Expiry Funding ===

#[test]
fun set_max_expiry_funding_updates_registered_expiry() {
    let fixture = setup_pool_with_pyth();
    let expiry_id = REGISTERED_EXPIRY_ID.to_id();

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    vault.register_expiry_market(expiry_id);

    vault.set_max_expiry_funding(&fixture.admin_cap, &fixture.config, expiry_id, 100_000_000_000);
    assert_eq!(vault.max_expiry_funding(expiry_id), 100_000_000_000);

    vault.set_max_expiry_funding(
        &fixture.admin_cap,
        &fixture.config,
        expiry_id,
        constants::expiry_cash_floor!(),
    );
    assert_eq!(vault.max_expiry_funding(expiry_id), constants::expiry_cash_floor!());

    return_shared(vault);
    finish(fixture);
}

// === Pool Sync Rebalancing ===

#[test]
fun pool_sync_tops_up_expiry_below_floor() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    assert_eq!(market.cash_balance(), constants::expiry_cash_floor!());
    assert_eq!(vault.idle_balance(), INITIAL_SUPPLY - constants::expiry_cash_floor!());
    let (sent_to_expiry, received_from_expiry) = vault.expiry_flow_amounts(expiry_id);
    assert_eq!(sent_to_expiry, constants::expiry_cash_floor!());
    assert_eq!(received_from_expiry, 0);
    assert_eq!(vault.profit_basis_debits(), constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_credits(), 0);

    return_shared(pyth);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    finish(fixture);
}

#[test]
fun pool_sync_sweeps_live_excess_without_materializing_profit() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    add_expiry_cash_for_accounting_test(&mut market, EXTRA_EXPIRY_CASH, fixture.scenario.ctx());

    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    assert_eq!(market.cash_balance(), constants::expiry_cash_floor!());
    // Live sweep returns 50b above the zero-liability floor, but live cash is
    // not terminal profit. It remains in pricing basis until the expiry settles.
    assert_eq!(vault.idle_balance(), 350_000_000_000);
    assert_eq!(vault.protocol_reserve_balance(), 0);
    let (sent_to_expiry, received_from_expiry) = vault.expiry_flow_amounts(expiry_id);
    assert_eq!(sent_to_expiry, 0);
    assert_eq!(received_from_expiry, constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_debits(), 0);
    assert_eq!(vault.profit_basis_credits(), constants::expiry_cash_floor!());

    return_shared(pyth);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    finish(fixture);
}

#[test]
fun settled_break_even_expiry_does_not_materialize_prior_live_sweep_profit() {
    let mut fixture = setup_pool_with_pyth();
    let (live_expiry_id, live_oracle_id) = create_expiry(&mut fixture, SECOND_EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut live_market = fixture.scenario.take_shared_by_id<ExpiryMarket>(live_expiry_id);
    let live_oracle = fixture.scenario.take_shared_by_id<MarketOracle>(live_oracle_id);
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    add_expiry_cash_for_accounting_test(
        &mut live_market,
        EXTRA_EXPIRY_CASH,
        fixture.scenario.ctx(),
    );
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut live_market, &live_oracle, &pyth);
    assert_eq!(vault.protocol_reserve_balance(), 0);

    return_shared(pyth);
    return_shared(live_oracle);
    return_shared(live_market);
    return_shared(vault);

    let (settled_expiry_id, settled_oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut live_market = fixture.scenario.take_shared_by_id<ExpiryMarket>(live_expiry_id);
    let live_oracle = fixture.scenario.take_shared_by_id<MarketOracle>(live_oracle_id);
    let mut settled_market = fixture.scenario.take_shared_by_id<ExpiryMarket>(settled_expiry_id);
    let mut settled_oracle = fixture.scenario.take_shared_by_id<MarketOracle>(settled_oracle_id);
    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    let mut sync = plp::start_pool_sync(&mut fixture.config, &vault);
    sync.sync_expiry(
        &mut vault,
        &mut live_market,
        &fixture.config,
        &live_oracle,
        &pyth,
        &fixture.clock,
    );
    sync.sync_expiry(
        &mut vault,
        &mut settled_market,
        &fixture.config,
        &settled_oracle,
        &pyth,
        &fixture.clock,
    );
    let _pool_value = vault.finish_pool_sync(&mut fixture.config, sync);

    settle_oracle(&mut fixture, &mut settled_oracle, &mut pyth, EXPIRY_MS);
    let mut sync = plp::start_pool_sync(&mut fixture.config, &vault);
    sync.sync_expiry(
        &mut vault,
        &mut live_market,
        &fixture.config,
        &live_oracle,
        &pyth,
        &fixture.clock,
    );
    sync.sync_expiry(
        &mut vault,
        &mut settled_market,
        &fixture.config,
        &settled_oracle,
        &pyth,
        &fixture.clock,
    );
    let _pool_value = vault.finish_pool_sync(&mut fixture.config, sync);

    assert_eq!(vault.protocol_reserve_balance(), 0);
    assert_eq!(vault.profit_basis_debits(), constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_credits(), 2 * constants::expiry_cash_floor!());

    return_shared(settled_oracle);
    return_shared(settled_market);
    return_shared(live_oracle);
    return_shared(live_market);
    return_shared(vault);
    return_shared(pyth);
    finish(fixture);
}

// === Settled Sync and Profit Materialization ===

#[test]
fun pool_sync_settled_expiry_deactivates_and_materializes_profit() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let mut oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);

    add_expiry_cash_for_accounting_test(&mut market, EXTRA_EXPIRY_CASH, fixture.scenario.ctx());
    settle_oracle(&mut fixture, &mut oracle, &mut pyth, EXPIRY_MS);

    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    assert_eq!(market.cash_balance(), 0);
    assert_eq!(vault.active_expiry_markets().length(), 0);
    // Settlement returns 100b. With no prior funding, all 100b is profit split
    // 60b LP / 40b protocol at 40%.
    assert_eq!(vault.idle_balance(), 360_000_000_000);
    assert_eq!(vault.protocol_reserve_balance(), 40_000_000_000);
    let (sent_to_expiry, received_from_expiry) = vault.expiry_flow_amounts(expiry_id);
    assert_eq!(sent_to_expiry, 0);
    assert_eq!(received_from_expiry, EXTRA_EXPIRY_CASH);
    assert_eq!(vault.profit_basis_debits(), EXTRA_EXPIRY_CASH);
    assert_eq!(vault.profit_basis_credits(), EXTRA_EXPIRY_CASH);

    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    finish(fixture);
}

#[test]
fun aggregate_loss_carry_forward_blocks_protocol_profit_until_recovered() {
    let mut fixture = setup_pool_with_pyth();
    let (loss_expiry_id, loss_oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut loss_market = fixture.scenario.take_shared_by_id<ExpiryMarket>(loss_expiry_id);
    let mut loss_oracle = fixture.scenario.take_shared_by_id<MarketOracle>(loss_oracle_id);

    sync_expiry_for_testing(&mut fixture, &mut vault, &mut loss_market, &loss_oracle, &pyth);
    let lost_cash = loss_market.release_pool_cash(PARTIAL_LOSS);
    destroy(lost_cash);
    settle_oracle(&mut fixture, &mut loss_oracle, &mut pyth, EXPIRY_MS);
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut loss_market, &loss_oracle, &pyth);

    assert_eq!(vault.profit_basis_debits(), constants::expiry_cash_floor!());
    assert_eq!(vault.profit_basis_credits(), constants::expiry_cash_floor!() - PARTIAL_LOSS);
    assert_eq!(vault.protocol_reserve_balance(), 0);

    return_shared(loss_oracle);
    return_shared(loss_market);
    return_shared(vault);
    return_shared(pyth);

    fixture.clock.set_for_testing(SECOND_EXPIRY_MS - 100_000);
    let (profit_expiry_id, profit_oracle_id) = create_expiry(&mut fixture, SECOND_EXPIRY_MS);

    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut profit_market = fixture.scenario.take_shared_by_id<ExpiryMarket>(profit_expiry_id);
    let mut profit_oracle = fixture.scenario.take_shared_by_id<MarketOracle>(profit_oracle_id);

    add_expiry_cash_for_accounting_test(
        &mut profit_market,
        SECOND_EXPIRY_PROFIT,
        fixture.scenario.ctx(),
    );
    settle_oracle(
        &mut fixture,
        &mut profit_oracle,
        &mut pyth,
        SECOND_EXPIRY_MS,
    );
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut profit_market, &profit_oracle, &pyth);

    // First expiry lost 20b; second expiry produced 90b. Only the net 70b is
    // materialized, so protocol reserve receives 28b and LP idle keeps 42b.
    assert_eq!(vault.protocol_reserve_balance(), 28_000_000_000);
    assert_eq!(vault.idle_balance(), 342_000_000_000);
    assert_eq!(vault.profit_basis_debits(), 120_000_000_000);
    assert_eq!(vault.profit_basis_credits(), 120_000_000_000);

    return_shared(profit_oracle);
    return_shared(profit_market);
    return_shared(vault);
    return_shared(pyth);
    finish(fixture);
}

// === Valuation Pricing ===

#[test]
fun supply_prices_active_unrealized_profit_net_of_protocol_share() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    add_expiry_cash_for_accounting_test(&mut market, EXTRA_EXPIRY_CASH, fixture.scenario.ctx());

    let mut sync = plp::start_pool_sync(&mut fixture.config, &vault);
    sync.sync_expiry(
        &mut vault,
        &mut market,
        &fixture.config,
        &oracle,
        &pyth,
        &fixture.clock,
    );
    // No incentives in this pool, so supply's incentive sources/clock are unused;
    // a local clock keeps the call from borrowing both config and clock off `fixture`.
    let payment = coin::mint_for_testing<DUSDC>(NAV_TEST_SUPPLY, fixture.scenario.ctx());
    let nav_clock = clock::create_for_testing(fixture.scenario.ctx());
    let new_plp = vault.supply(
        &mut fixture.config,
        sync,
        payment,
        &pyth,
        &pyth,
        &nav_clock,
        fixture.scenario.ctx(),
    );
    nav_clock.destroy_for_testing();

    // Pool value used for pricing is 360b:
    // idle 330b + active expiry NAV 50b - pending protocol share 20b.
    // 36b supply against 300b existing shares therefore mints 30b shares.
    assert_eq!(new_plp.value(), NAV_TEST_EXPECTED_SHARES);
    assert_eq!(vault.total_supply(), INITIAL_SUPPLY + NAV_TEST_EXPECTED_SHARES);

    destroy(new_plp);
    return_shared(pyth);
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    finish(fixture);
}

// === Pool Sync Failures ===

#[test, expected_failure(abort_code = plp::EMissingExpirySync)]
fun finish_pool_sync_with_missing_expiry_aborts() {
    let mut fixture = setup_pool_with_pyth();
    let (_expiry_id, _oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let sync = plp::start_pool_sync(&mut fixture.config, &vault);
    let _pool_value = vault.finish_pool_sync(&mut fixture.config, sync);
    abort 999
}

#[test, expected_failure(abort_code = plp::EExpiryMarketAlreadySynced)]
fun sync_same_expiry_twice_aborts() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);

    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);

    let mut sync = plp::start_pool_sync(&mut fixture.config, &vault);
    sync.sync_expiry(
        &mut vault,
        &mut market,
        &fixture.config,
        &oracle,
        &pyth,
        &fixture.clock,
    );
    sync.sync_expiry(
        &mut vault,
        &mut market,
        &fixture.config,
        &oracle,
        &pyth,
        &fixture.clock,
    );
    abort 999
}

// === Helpers ===

fun setup_pool_with_pyth(): Fixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_protocol_reserve_profit_share(&admin_cap, PROTOCOL_RESERVE_SHARE);
    let cap = market_oracle::create_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    scenario.next_tx(test_constants::admin());
    let mut vault = scenario.take_shared<PoolVault>();
    let vault_id = vault.id();
    let sync = plp::start_pool_sync(&mut config, &vault);
    // Bootstrap supply: no incentives exist yet, so the sources are ignored.
    let placeholder = pyth_source::new_for_testing(scenario.ctx());
    let initial_plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(INITIAL_SUPPLY, scenario.ctx()),
        &placeholder,
        &placeholder,
        &clock,
        scenario.ctx(),
    );
    destroy(placeholder);
    return_shared(vault);

    scenario.next_tx(test_constants::admin());
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        PYTH_FEED_ID,
        TICK_SIZE,
        config_constants::default_expiry_fee_window_ms!(),
        float!(),
        scenario.ctx(),
    );
    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    pyth.set_state_for_testing(CREATION_SPOT, LIVE_SOURCE_TIMESTAMP_MS, LIVE_SOURCE_TIMESTAMP_MS);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());

    Fixture {
        scenario,
        registry,
        admin_cap,
        config,
        cap,
        clock,
        vault_id,
        pyth_id,
        initial_plp,
    }
}

fun create_expiry(fixture: &mut Fixture, expiry: u64): (ID, ID) {
    fixture.scenario.next_tx(test_constants::admin());
    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    pyth.set_state_for_testing(
        CREATION_SPOT,
        fixture.clock.timestamp_ms(),
        fixture.clock.timestamp_ms(),
    );
    let (expiry_id, oracle_id) = registry::create_expiry_market(
        &mut fixture.registry,
        &mut vault,
        &fixture.config,
        &pyth,
        &fixture.cap,
        expiry,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    return_shared(vault);
    return_shared(pyth);
    fixture.scenario.next_tx(test_constants::admin());
    (expiry_id, oracle_id)
}

fun add_expiry_cash_for_accounting_test(
    market: &mut ExpiryMarket,
    amount: u64,
    ctx: &mut TxContext,
) {
    market.receive_pool_cash(coin::mint_for_testing<DUSDC>(amount, ctx).into_balance());
}

fun settle_oracle(
    fixture: &mut Fixture,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    expiry: u64,
) {
    let settlement_source_timestamp_ms = expiry + 1_000;
    let settlement_update_timestamp_ms = expiry + 2_000;
    fixture.clock.set_for_testing(settlement_update_timestamp_ms);
    pyth.set_state_for_testing(
        SETTLEMENT_PRICE,
        settlement_source_timestamp_ms,
        settlement_update_timestamp_ms,
    );
    assert!(oracle.settle_if_possible(&fixture.config, pyth, &fixture.cap, &fixture.clock));
}

fun sync_expiry_for_testing(
    fixture: &mut Fixture,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
) {
    let mut sync = plp::start_pool_sync(&mut fixture.config, vault);
    sync.sync_expiry(
        vault,
        market,
        &fixture.config,
        oracle,
        pyth,
        &fixture.clock,
    );
    let _pool_value = vault.finish_pool_sync(&mut fixture.config, sync);
}

fun finish(fixture: Fixture) {
    let Fixture {
        scenario,
        registry,
        admin_cap,
        config,
        cap,
        clock,
        vault_id: _,
        pyth_id: _,
        initial_plp,
    } = fixture;
    destroy(initial_plp);
    market_oracle::destroy_cap(cap);
    destroy(config);
    destroy(admin_cap);
    registry::destroy_registry_drop_for_testing(registry);
    clock.destroy_for_testing();
    scenario.end();
}
