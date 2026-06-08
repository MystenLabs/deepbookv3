// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared bring-up for production-valid Predict trade-flow tests.
///
/// Stands up a funded, tradeable market through the real creation + PLP funding
/// paths (`registry::create_expiry_market`, `plp::supply` + sync rebalance) and
/// exposes thin wrappers for the trade flows.
///
/// The `Registry` and `ProtocolConfig` are real shared objects (created via
/// `registry::init_for_testing`, which mirrors the production `init`). They are
/// NOT held as `Fixture` fields: a `take_shared` object cannot cross a `next_tx`
/// boundary, so each method takes the config/registry it needs as a local and
/// returns it before the next transaction (setup-phase methods), or the flow
/// test takes the config once via `take_market` and threads it as a `&`/`&mut`
/// parameter (flow-phase methods). This keeps every take/return non-nested and
/// avoids owned config/registry fields entirely. Oracle spot is seeded via the
/// test-only `set_state_for_testing` because a real `pyth_lazer::Update` has no
/// Move-side test constructor.
#[test_only]
module deepbook_predict::flow_test_helpers;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    expiry_market::{Self, ExpiryMarket},
    i64,
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::{Self, PLP, PoolSync, PoolVault},
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
    random,
    sui::SUI,
    test_scenario::{Self as test, Scenario, return_shared}
};
use token::deep::DEEP;

/// The grid's minimum finite strike for the default tick/grid (a valid lower
/// boundary). Re-exported from `test_constants` so existing `helpers::min_strike()`
/// callers keep working through the one source of truth.
public fun min_strike(): u64 { test_constants::min_finite_strike() }

/// Scenario-local objects shared across one flow test. `Registry`/`ProtocolConfig`
/// are real shared objects taken per-transaction, not held here (see module doc).
public struct Fixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    cap: MarketOracleCap,
    clock: Clock,
    vault_id: ID,
    pyth_id: ID,
    initial_plp: Coin<PLP>,
}

/// Stand up a registry + protocol config (via the production-mirroring
/// `init_for_testing`) + a registered Pyth source + a bootstrapped PLP pool, with
/// the oracle grid centered on `spot`, a `tick`-sized strike grid, and `supply`
/// DUSDC of initial PLP. base_fee is floored to 1 and min_ask to 0 so small test
/// quantities are admissible. The real Pyth source is created BEFORE `supply` so
/// it can serve as the incentive-valuation source (no placeholder seam needed).
///
/// `spot/tick` must land in `(grid_ticks/2, grid_ticks]` for `new_centered` to
/// accept it (the defaults satisfy this — see `test_constants`).
public fun setup_market(spot: u64, tick: u64, supply: u64): Fixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());

    // tx1: configure protocol params + register the real Pyth source.
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    config.set_protocol_reserve_profit_share(&admin_cap, test_constants::protocol_reserve_share());
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_min_ask_price(&admin_cap, 0);
    return_shared(config);
    let mut registry = scenario.take_shared<Registry>();
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        test_constants::pyth_feed_id(),
        tick,
        scenario.ctx(),
    );
    return_shared(registry);
    let cap = market_oracle::create_cap(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: seed Pyth spot, then bootstrap the PLP pool through the real supply
    // path using the registered source as both incentive valuation sources.
    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(spot, live_ts, live_ts);
    let mut config = scenario.take_shared<ProtocolConfig>();
    let mut vault = scenario.take_shared<PoolVault>();
    let vault_id = vault.id();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let initial_plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(supply, scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    return_shared(vault);
    return_shared(config);
    return_shared(pyth);

    scenario.next_tx(test_constants::admin());

    Fixture {
        scenario,
        admin_cap,
        cap,
        clock,
        vault_id,
        pyth_id,
        initial_plp,
    }
}

/// `setup_market` with the default creation spot / tick / initial supply.
public fun setup_market_default(): Fixture {
    setup_market(
        test_constants::default_creation_spot(),
        test_constants::default_tick_size(),
        test_constants::default_initial_supply(),
    )
}

/// Back-compat alias for the default bring-up (the pre-parameterization name used
/// across the existing suite).
public fun setup_pool_with_pyth(): Fixture { setup_market_default() }

/// One-shot composite bring-up over `(expiry_ms, live_price)`: a default funded
/// pool already past `create_expiry` + `prepare_live_oracle` + a full single-expiry
/// `sync_expiry`, plus a funded alice manager (`mint_deposit`), so a flow test
/// starts at the first interesting line. The market objects are returned to the
/// shared pool; the caller `take_market`s them. Returns
/// `(fixture, expiry_id, oracle_id, manager)`.
public fun setup_live_market(expiry_ms: u64, live_price: u64): (Fixture, ID, ID, PredictManager) {
    setup_funded_live_market(expiry_ms, live_price, test_constants::mint_deposit())
}

/// `setup_live_market` at the far default expiry / live price with the large
/// default manager deposit (used by the smoke + gate tests).
public fun setup_everything(): (Fixture, ID, ID, PredictManager) {
    setup_funded_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
        test_constants::default_manager_deposit(),
    )
}

fun setup_funded_live_market(
    expiry_ms: u64,
    live_price: u64,
    deposit: u64,
): (Fixture, ID, ID, PredictManager) {
    let mut fx = setup_market_default();
    let (expiry_id, oracle_id) = fx.create_expiry(expiry_ms);
    let manager = fx.create_funded_manager(deposit);
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, live_price);
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);
    return_market(pyth, vault, market, oracle, config);
    fx.scenario.next_tx(test_constants::admin());
    (fx, expiry_id, oracle_id, manager)
}

/// Create the market + oracle for `expiry` through the production path.
public fun create_expiry(self: &mut Fixture, expiry: u64): (ID, ID) {
    self.scenario.next_tx(test_constants::admin());
    let pyth = self.scenario.take_shared_by_id<PythSource>(self.pyth_id);
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut registry = self.scenario.take_shared<Registry>();
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    let (expiry_id, oracle_id) = registry::create_expiry_market(
        &mut registry,
        &mut vault,
        &mut config,
        &pyth,
        &self.cap,
        expiry,
        &self.clock,
        self.scenario.ctx(),
    );
    return_shared(config);
    return_shared(registry);
    return_shared(vault);
    return_shared(pyth);
    self.scenario.next_tx(test_constants::admin());
    (expiry_id, oracle_id)
}

public fun set_protocol_reserve_profit_share(
    self: &Fixture,
    config: &mut ProtocolConfig,
    share: u64,
) {
    config.set_protocol_reserve_profit_share(&self.admin_cap, share);
}

public fun set_valuation_liquidation_budget(
    self: &Fixture,
    config: &mut ProtocolConfig,
    budget: u64,
) {
    config.set_valuation_liquidation_budget(&self.admin_cap, budget);
}

public fun set_trade_liquidation_budget(self: &Fixture, config: &mut ProtocolConfig, budget: u64) {
    config.set_trade_liquidation_budget(&self.admin_cap, budget);
}

public fun set_template_zero_min_fee(self: &mut Fixture) {
    self.scenario.next_tx(test_constants::admin());
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    config.set_template_min_fee(&self.admin_cap, 0);
    return_shared(config);
    self.scenario.next_tx(test_constants::admin());
}

/// Take the four shared market objects + the protocol config a flow test
/// mutates. The config is threaded into the flow-phase methods as a parameter
/// (it cannot be a `Fixture` field — see module doc) and returned by the test.
public fun take_market(
    self: &mut Fixture,
    expiry_id: ID,
    oracle_id: ID,
): (PythSource, PoolVault, ExpiryMarket, MarketOracle, ProtocolConfig) {
    (
        self.scenario.take_shared_by_id<PythSource>(self.pyth_id),
        self.scenario.take_shared_by_id<PoolVault>(self.vault_id),
        self.scenario.take_shared_by_id<ExpiryMarket>(expiry_id),
        self.scenario.take_shared_by_id<MarketOracle>(oracle_id),
        self.scenario.take_shared<ProtocolConfig>(),
    )
}

/// Return the five shared objects taken by `take_market` (pairs 1:1 with it so
/// flow tests don't hand-roll five `return_shared` calls).
public fun return_market(
    pyth: PythSource,
    vault: PoolVault,
    market: ExpiryMarket,
    oracle: MarketOracle,
    config: ProtocolConfig,
) {
    return_shared(oracle);
    return_shared(market);
    return_shared(vault);
    return_shared(pyth);
    return_shared(config);
}

/// Create a fresh trader manager (owned by alice) and fund it with DUSDC. The
/// scenario sender is left as alice so the caller's next mint/redeem generates a
/// valid owner proof.
public fun create_funded_manager(self: &mut Fixture, deposit: u64): PredictManager {
    self.scenario.next_tx(test_constants::alice());
    let mut registry = self.scenario.take_shared<Registry>();
    let mut manager = registry::create_manager(&mut registry, self.scenario.ctx());
    return_shared(registry);
    manager.deposit(
        coin::mint_for_testing<DUSDC>(deposit, self.scenario.ctx()),
        self.scenario.ctx(),
    );
    manager
}

/// Seed fresh live Block Scholes prices + SVI so quotes are available.
/// `live_price` is used as both spot and forward (basis = 1.0).
public fun prepare_live_oracle(
    self: &Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    live_price: u64,
) {
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(live_price, live_ts, live_ts);
    oracle.update_block_scholes_prices(
        config,
        &self.cap,
        live_price,
        live_price,
        live_ts,
        &self.clock,
    );
    let svi = market_oracle::new_svi_params(
        test_constants::default_svi_a(),
        constants::svi_b_min!(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    );
    oracle.update_svi(config, &self.cap, svi, live_ts, &self.clock);
}

public fun prepare_live_oracle_at(
    self: &Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    pyth.set_state_for_testing(live_price, source_timestamp_ms, source_timestamp_ms);
    oracle.update_block_scholes_prices(
        config,
        &self.cap,
        live_price,
        live_price,
        source_timestamp_ms,
        &self.clock,
    );
    let svi = market_oracle::new_svi_params(
        test_constants::default_svi_a(),
        constants::svi_b_min!(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    );
    oracle.update_svi(config, &self.cap, svi, source_timestamp_ms, &self.clock);
}

public fun set_pyth_price_for_testing(
    self: &Fixture,
    pyth: &mut PythSource,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    pyth.set_state_for_testing(live_price, source_timestamp_ms, self.clock.timestamp_ms());
}

/// Run one full pool sync over a single active expiry (rebalances idle cash into
/// the expiry up to the cash floor and accumulates its NAV).
public fun sync_expiry(
    self: &Fixture,
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
) {
    let mut sync = plp::start_pool_sync(config, vault);
    sync.sync_expiry(vault, market, config, oracle, pyth, &self.clock);
    let _pool_value = vault.finish_pool_sync(config, sync);
}

public fun sync_expiry_value(
    self: &Fixture,
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): u64 {
    let mut sync = plp::start_pool_sync(config, vault);
    sync.sync_expiry(vault, market, config, oracle, pyth, &self.clock);
    vault.finish_pool_sync(config, sync)
}

public fun supply(
    self: &mut Fixture,
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    sync: PoolSync,
    pyth: &PythSource,
    amount: u64,
): Coin<PLP> {
    vault.supply(
        config,
        sync,
        coin::mint_for_testing<DUSDC>(amount, self.scenario.ctx()),
        pyth,
        pyth,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Add idle PLP supply before tests create additional active expiries. This is
/// only for tests that need allocation headroom but do not need the extra PLP
/// coin for later withdraw accounting.
public fun add_idle_supply_before_expiries(self: &mut Fixture, amount: u64) {
    self.scenario.next_tx(test_constants::admin());
    let pyth = self.scenario.take_shared_by_id<PythSource>(self.pyth_id);
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let extra_plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(amount, self.scenario.ctx()),
        &pyth,
        &pyth,
        &self.clock,
        self.scenario.ctx(),
    );
    destroy(extra_plp);
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    self.scenario.next_tx(test_constants::admin());
}

public fun withdraw(
    self: &mut Fixture,
    config: &mut ProtocolConfig,
    vault: &mut PoolVault,
    sync: PoolSync,
    lp_coin: Coin<PLP>,
): (Coin<DUSDC>, Coin<SUI>, Coin<DEEP>) {
    vault.withdraw(config, sync, lp_coin, &self.clock, self.scenario.ctx())
}

/// Settle the oracle via the test-only generator wrapper using a fresh
/// post-expiry Pyth spot and an insufficient sample buffer, so settlement latches
/// and takes the single-spot fallback at `settlement_price`. Advances the clock
/// past expiry.
public fun settle_oracle(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    settlement_price: u64,
) {
    let expiry = oracle.expiry();
    let source_timestamp_ms = expiry + 1_000;
    let update_timestamp_ms = expiry + 2_000;
    self.clock.set_for_testing(update_timestamp_ms);
    pyth.set_state_for_testing(settlement_price, source_timestamp_ms, update_timestamp_ms);
    let mut generator = random::new_generator_for_testing();
    oracle.settle_with_generator_for_testing(config, pyth, &mut generator, &self.clock);
    assert!(oracle.is_settled());
}

/// Mint one order for `manager` and return its packed order id.
public fun mint(
    self: &mut Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
): u256 {
    let proof = manager.generate_proof_as_owner(self.scenario.ctx());
    market.mint(
        manager,
        &proof,
        config,
        oracle,
        pyth,
        lower,
        higher,
        quantity,
        leverage,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Close (or partially close) a live order. Returns `(closed_id, replacement_id)`.
public fun redeem(
    self: &mut Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let proof = manager.generate_proof_as_owner(self.scenario.ctx());
    market.redeem(
        manager,
        proof,
        config,
        oracle,
        pyth,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Permissionless settled redeem (no proof). Requires a full close.
public fun redeem_settled(
    self: &mut Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    market.redeem_settled(
        manager,
        config,
        oracle,
        pyth,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    )
}

// === Manager state-sheet assertions (ExpectedBalances analog) ===

/// A full expected snapshot of one manager's scalar state plus its per-expiry
/// trading state, asserted in one call by `check_manager`. Mirrors deepbook
/// core's `ExpectedBalances` pattern so flow tests read as state sheets rather
/// than scattered getter assertions.
public struct ExpectedManagerState has copy, drop {
    /// Free DUSDC balance (`manager.balance()`).
    balance: u64,
    /// Cumulative trading fees paid into the checked expiry.
    fees_paid: u64,
    /// Open position count in the checked expiry.
    position_count: u64,
    /// Active (this-epoch-effective) DEEP stake.
    active_stake: u64,
    /// Inactive (next-epoch) DEEP stake.
    inactive_stake: u64,
}

public fun expected_manager_state(
    balance: u64,
    fees_paid: u64,
    position_count: u64,
    active_stake: u64,
    inactive_stake: u64,
): ExpectedManagerState {
    ExpectedManagerState { balance, fees_paid, position_count, active_stake, inactive_stake }
}

/// Assert a manager's full state sheet against `expected` for `expiry_id`. Each
/// field is an exact `assert_eq!`, so a single wrong field fails the test with
/// both values printed.
public fun check_manager(manager: &PredictManager, expiry_id: ID, expected: ExpectedManagerState) {
    assert_eq!(manager.balance(), expected.balance);
    assert_eq!(manager.trading_fees_paid(expiry_id), expected.fees_paid);
    assert_eq!(manager.expiry_position_count(expiry_id), expected.position_count);
    assert_eq!(manager.active_stake(), expected.active_stake);
    assert_eq!(manager.inactive_stake(), expected.inactive_stake);
}

// === Accessors ===

public fun scenario_mut(self: &mut Fixture): &mut Scenario { &mut self.scenario }

public fun clock(self: &Fixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut Fixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun update_block_scholes_prices_for_testing(
    self: &Fixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
) {
    oracle.update_block_scholes_prices(
        config,
        &self.cap,
        spot,
        forward,
        source_timestamp_ms,
        &self.clock,
    );
}

public fun vault_id(self: &Fixture): ID { self.vault_id }

public fun pyth_id(self: &Fixture): ID { self.pyth_id }

/// Tear down the fixture and all owned objects. The shared Registry/ProtocolConfig
/// are returned by the flow test (via `return_shared`) and reclaimed by `end`.
public fun finish(self: Fixture) {
    let Fixture {
        scenario,
        admin_cap,
        cap,
        clock,
        vault_id: _,
        pyth_id: _,
        initial_plp,
    } = self;
    destroy(initial_plp);
    market_oracle::destroy_cap(cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}
