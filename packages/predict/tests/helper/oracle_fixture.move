// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minimal production-valid oracle bring-up for `market_oracle` + `pricing`
/// error-path tests.
///
/// Stands up a real `MarketOracle` + `PythSource` through the production
/// `registry::create_expiry_market` path, with only the PLP idle funding required
/// to back the expiry allocation invariant. This reaches the oracle/pricing
/// guards more cheaply than the full `flow_test_helpers` market: no per-expiry
/// sync or manager setup. It is the legitimate home of `set_state_for_testing`
/// for tests that don't need a funded expiry market.
///
/// The fixture exposes the `MarketOracleWriterCap` so error-path tests can call the
/// guarded oracle setters (`update_block_scholes_prices`, `update_svi`) directly
/// with adversarial inputs to trigger `EZeroSpot`/`EZeroForward`/stale/future/
/// deviation aborts. `ProtocolConfig`/`Registry` are taken per-transaction (never
/// held), mirroring `flow_test_helpers`.
#[test_only]
module deepbook_predict::oracle_fixture;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    market_lifecycle_cap::MarketLifecycleCap,
    market_oracle::{Self, MarketOracle, SVIParams},
    market_oracle_writer_cap::{Self, MarketOracleWriterCap},
    plp::{Self, PLP, PoolVault},
    protocol_config::ProtocolConfig,
    pyth_source::{Self, PythSource},
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use predict_math::i64;
use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Self as test, Scenario, return_shared}
};

/// Scenario-local oracle objects. `Registry`/`ProtocolConfig`/`PoolVault` are real
/// shared objects taken per-transaction, not held here.
public struct OracleFixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    cap: MarketOracleWriterCap,
    lifecycle_cap: MarketLifecycleCap,
    clock: Clock,
    pyth_id: ID,
    oracle_id: ID,
    expiry_id: ID,
    initial_plp: Coin<PLP>,
}

/// Stand up a registry + config + a registered Pyth source (spot seeded to `spot`)
/// + a `MarketOracle`/`ExpiryMarket` for `expiry`, with grid centered on `spot`
/// and a `tick`-sized grid. PLP is supplied only to back the registration
/// allocation; no expiry sync runs. `spot/tick` must satisfy the `new_centered`
/// window (the defaults do).
public fun setup_oracle(spot: u64, tick: u64, expiry: u64): OracleFixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());

    // tx1: register the real Pyth source.
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        &admin_cap,
        test_constants::pyth_feed_id(),
        tick,
        scenario.ctx(),
    );
    return_shared(registry);
    let cap = market_oracle_writer_cap::create(&admin_cap, scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: seed the Pyth spot, then create the expiry market + oracle on the
    // unfunded vault through the production registry path.
    scenario.next_tx(test_constants::admin());
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(spot, live_ts, live_ts);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut registry = scenario.take_shared<Registry>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let initial_plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(test_constants::default_initial_supply(), scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    let lifecycle_cap = vault.mint_lifecycle_cap(&admin_cap, scenario.ctx());
    let (expiry_id, oracle_id) = registry::create_expiry_market(
        &mut registry,
        &mut vault,
        &mut config,
        &pyth,
        &lifecycle_cap,
        vector[cap.id()],
        expiry,
        &clock,
        scenario.ctx(),
    );
    return_shared(config);
    return_shared(registry);
    return_shared(vault);
    return_shared(pyth);

    scenario.next_tx(test_constants::admin());

    OracleFixture {
        scenario,
        admin_cap,
        cap,
        lifecycle_cap,
        clock,
        pyth_id,
        oracle_id,
        expiry_id,
        initial_plp,
    }
}

/// `setup_oracle` with the default creation spot / tick and the default (far)
/// expiry.
public fun setup_oracle_default(): OracleFixture {
    setup_oracle(
        test_constants::default_creation_spot(),
        test_constants::default_tick_size(),
        test_constants::default_expiry_ms(),
    )
}

/// Take the oracle + pyth source + protocol config for an error-path test. Pair
/// with `return_oracle`.
public fun take_oracle(self: &mut OracleFixture): (PythSource, MarketOracle, ProtocolConfig) {
    (
        self.scenario.take_shared_by_id<PythSource>(self.pyth_id),
        self.scenario.take_shared_by_id<MarketOracle>(self.oracle_id),
        self.scenario.take_shared<ProtocolConfig>(),
    )
}

/// Return the three shared objects taken by `take_oracle`.
public fun return_oracle(pyth: PythSource, oracle: MarketOracle, config: ProtocolConfig) {
    return_shared(oracle);
    return_shared(pyth);
    return_shared(config);
}

/// Seed fresh live Block Scholes prices + SVI so quotes are available, at the
/// fixture's default live source timestamp. `live_price` is used as both spot and
/// forward (basis = 1.0).
public fun prepare_live_oracle(
    self: &OracleFixture,
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
        test_constants::default_svi_b(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        constants::svi_sigma_min!(),
    );
    oracle.update_svi(config, &self.cap, svi, live_ts, &self.clock);
}

/// Seed fresh live Block Scholes prices + arbitrary SVI through the production cap
/// path, for exact-pricing tests over real on-chain scenarios. `spot`/`forward` are
/// the real (1e9) Block Scholes spot/forward; on the fresh-Pyth path pricing derives
/// the live forward as `mul(spot, div(forward, spot))`. The grid was already centered
/// on the fixture creation spot, so callers pass real strikes valid for that grid.
public fun prepare_real_oracle(
    self: &OracleFixture,
    config: &ProtocolConfig,
    oracle: &mut MarketOracle,
    pyth: &mut PythSource,
    spot: u64,
    forward: u64,
    svi: SVIParams,
) {
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(spot, live_ts, live_ts);
    oracle.update_block_scholes_prices(config, &self.cap, spot, forward, live_ts, &self.clock);
    oracle.update_svi(config, &self.cap, svi, live_ts, &self.clock);
}

/// Overwrite the Pyth spot directly (for staleness and pricing-source tests),
/// keeping the fixture clock as the update timestamp.
public fun set_pyth(
    self: &OracleFixture,
    pyth: &mut PythSource,
    price: u64,
    source_timestamp_ms: u64,
) {
    pyth.set_state_for_testing(price, source_timestamp_ms, self.clock.timestamp_ms());
}

// === Accessors ===

/// The authorized cap, so error-path tests can drive the guarded oracle setters
/// directly with adversarial inputs.
public fun cap(self: &OracleFixture): &MarketOracleWriterCap { &self.cap }

/// The allow-listed lifecycle cap, for tests driving the lifecycle-gated flows
/// (`create_expiry_market` / `plp::compact_storage`) directly.
public fun lifecycle_cap(self: &OracleFixture): &MarketLifecycleCap { &self.lifecycle_cap }

public fun clock(self: &OracleFixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut OracleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun scenario_mut(self: &mut OracleFixture): &mut Scenario { &mut self.scenario }

public fun oracle_id(self: &OracleFixture): ID { self.oracle_id }

public fun pyth_id(self: &OracleFixture): ID { self.pyth_id }

public fun expiry_id(self: &OracleFixture): ID { self.expiry_id }

/// Tear down the fixture and all owned objects. Shared objects are released via
/// `return_oracle` in the test and reclaimed by `end`.
public fun finish(self: OracleFixture) {
    let OracleFixture {
        scenario,
        admin_cap,
        cap,
        lifecycle_cap,
        clock,
        pyth_id: _,
        oracle_id: _,
        expiry_id: _,
        initial_plp,
    } = self;
    destroy(initial_plp);
    cap.destroy();
    lifecycle_cap.destroy();
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}
