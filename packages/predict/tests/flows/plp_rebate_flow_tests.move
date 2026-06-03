// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::plp_rebate_flow_tests;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    constants::{Self, float_scaling as float},
    expiry_market::{Self, ExpiryMarket},
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    order,
    plp::{Self, PLP, PoolVault},
    predict_manager::PredictManager,
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
const TICK_SIZE: u64 = 1_000_000_000;
const CREATION_SPOT: u64 = 50_100_000_000_000;
const LIVE_PRICE: u64 = 100_000_000_000;
const SETTLEMENT_PRICE: u64 = 99_000_000_000;
const LIVE_SOURCE_TIMESTAMP_MS: u64 = 99_000;
const MIN_FEE_LOWER_STRIKE: u64 = 100_000_000_000;

const INITIAL_SUPPLY: u64 = 300_000_000_000;
const PROTOCOL_RESERVE_SHARE: u64 = 400_000_000;
const MIN_FEE_MINT_QUANTITY: u64 = 1_000_000_000;
const MIN_FEE_MINT_DEPOSIT: u64 = 1_000_000_000;
const MIN_FEE_MINT_FEE: u64 = 5_000_000;
const MIN_FEE_REBATE_RESERVE: u64 = 2_500_000;
const MIN_FEE_PROTOCOL_PROFIT: u64 = 1_000_000;
const MIN_FEE_TERMINAL_MATERIALIZED_PROFIT: u64 = 502_500_000;
const MIN_FEE_TERMINAL_PROTOCOL_PROFIT: u64 = 201_000_000;

/// Scenario-local objects shared by the PLP rebate flow tests.
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

#[test]
fun same_expiry_residual_rebate_cash_materializes_new_terminal_profit() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);
    let mut manager = create_manager_for_testing(&mut fixture);

    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let mut oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);

    prepare_live_oracle_for_trading(&fixture, &mut oracle, &mut pyth);
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    manager.deposit(
        coin::mint_for_testing<DUSDC>(MIN_FEE_MINT_DEPOSIT, fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );
    let proof = manager.generate_proof_as_owner(fixture.scenario.ctx());
    let order_id = market.mint(
        &mut manager,
        &proof,
        &fixture.config,
        &oracle,
        &pyth,
        MIN_FEE_LOWER_STRIKE,
        constants::pos_inf!(),
        MIN_FEE_MINT_QUANTITY,
        order::leverage_one_x(),
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(manager.trading_fees_paid(expiry_id), MIN_FEE_MINT_FEE);

    settle_oracle(&mut fixture, &mut oracle, &mut pyth);
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    assert_eq!(vault.protocol_reserve_balance(), MIN_FEE_TERMINAL_PROTOCOL_PROFIT);
    assert_eq!(
        vault.profit_basis_debits(),
        constants::expiry_cash_floor!() + MIN_FEE_TERMINAL_MATERIALIZED_PROFIT,
    );
    assert_eq!(
        vault.profit_basis_credits(),
        constants::expiry_cash_floor!() + MIN_FEE_TERMINAL_MATERIALIZED_PROFIT,
    );

    // Settled redeem is permissionless, so it takes no trade proof.
    let (closed_order_id, replacement_order_id) = market.redeem_settled(
        &mut manager,
        &fixture.config,
        &oracle,
        &pyth,
        order_id,
        MIN_FEE_MINT_QUANTITY,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(closed_order_id, order_id);
    assert!(replacement_order_id.is_none());

    plp::claim_trading_loss_rebate(
        &mut vault,
        &mut market,
        &mut manager,
        &fixture.config,
        &oracle,
        fixture.scenario.ctx(),
    );

    assert_eq!(
        vault.protocol_reserve_balance(),
        MIN_FEE_TERMINAL_PROTOCOL_PROFIT + MIN_FEE_PROTOCOL_PROFIT,
    );
    assert_eq!(
        vault.profit_basis_debits(),
        constants::expiry_cash_floor!()
            + MIN_FEE_TERMINAL_MATERIALIZED_PROFIT
            + MIN_FEE_REBATE_RESERVE,
    );
    assert_eq!(
        vault.profit_basis_credits(),
        constants::expiry_cash_floor!()
            + MIN_FEE_TERMINAL_MATERIALIZED_PROFIT
            + MIN_FEE_REBATE_RESERVE,
    );
    assert_eq!(market.cash_balance(), 0);

    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    destroy(manager);
    finish(fixture);
}

#[test, expected_failure(abort_code = expiry_market::EProofRequiredForLiveRedeem)]
fun redeem_settled_on_live_order_aborts() {
    let mut fixture = setup_pool_with_pyth();
    let (expiry_id, oracle_id) = create_expiry(&mut fixture, EXPIRY_MS);
    let mut manager = create_manager_for_testing(&mut fixture);

    let mut pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
    let mut market = fixture.scenario.take_shared_by_id<ExpiryMarket>(expiry_id);
    let mut oracle = fixture.scenario.take_shared_by_id<MarketOracle>(oracle_id);

    prepare_live_oracle_for_trading(&fixture, &mut oracle, &mut pyth);
    sync_expiry_for_testing(&mut fixture, &mut vault, &mut market, &oracle, &pyth);

    manager.deposit(
        coin::mint_for_testing<DUSDC>(MIN_FEE_MINT_DEPOSIT, fixture.scenario.ctx()),
        fixture.scenario.ctx(),
    );
    let proof = manager.generate_proof_as_owner(fixture.scenario.ctx());
    let order_id = market.mint(
        &mut manager,
        &proof,
        &fixture.config,
        &oracle,
        &pyth,
        MIN_FEE_LOWER_STRIKE,
        constants::pos_inf!(),
        MIN_FEE_MINT_QUANTITY,
        order::leverage_one_x(),
        &fixture.clock,
        fixture.scenario.ctx(),
    );

    // Oracle is not settled, so the order is still live: the permissionless
    // redeem_settled path must reject it (closing live risk requires a proof).
    market.redeem_settled(
        &mut manager,
        &fixture.config,
        &oracle,
        &pyth,
        order_id,
        MIN_FEE_MINT_QUANTITY,
        &fixture.clock,
        fixture.scenario.ctx(),
    );

    abort 999
}

fun setup_pool_with_pyth(): Fixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    let (mut registry, admin_cap) = registry::new_for_testing(scenario.ctx());
    let mut config = protocol_config::new_for_testing(scenario.ctx());
    config.set_protocol_reserve_profit_share(&admin_cap, PROTOCOL_RESERVE_SHARE);
    config.set_base_fee(&admin_cap, 1);
    config.set_min_ask_price(&admin_cap, 0);
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
    let pyth = fixture.scenario.take_shared_by_id<PythSource>(fixture.pyth_id);
    let mut vault = fixture.scenario.take_shared_by_id<PoolVault>(fixture.vault_id);
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

fun create_manager_for_testing(fixture: &mut Fixture): PredictManager {
    fixture.scenario.next_tx(test_constants::alice());
    registry::create_manager(&mut fixture.registry, fixture.scenario.ctx())
}

fun prepare_live_oracle_for_trading(
    fixture: &Fixture,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
) {
    pyth.set_state_for_testing(
        LIVE_PRICE,
        LIVE_SOURCE_TIMESTAMP_MS,
        LIVE_SOURCE_TIMESTAMP_MS,
    );
    oracle.update_block_scholes_prices(
        &fixture.config,
        pyth,
        &fixture.cap,
        LIVE_PRICE,
        LIVE_PRICE,
        LIVE_SOURCE_TIMESTAMP_MS,
        &fixture.clock,
    );
    let svi = market_oracle::new_svi_params(1, 2, i64::zero(), i64::zero(), 3);
    oracle.update_svi(
        &fixture.config,
        &fixture.cap,
        svi,
        LIVE_SOURCE_TIMESTAMP_MS,
        &fixture.clock,
    );
}

fun settle_oracle(fixture: &mut Fixture, oracle: &mut MarketOracle, pyth: &mut PythSource) {
    let settlement_source_timestamp_ms = EXPIRY_MS + 1_000;
    let settlement_update_timestamp_ms = EXPIRY_MS + 2_000;
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
