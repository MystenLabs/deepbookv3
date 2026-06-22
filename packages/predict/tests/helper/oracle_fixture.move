// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minimal production-valid feed bring-up for `pricing` error-path and exact-pricing
/// tests.
///
/// Stands up the two standalone propbook feeds — a `PythFeed` (global spot) and a
/// `BlockScholesFeed` (per-expiry surface) — and an `ExpiryMarket` for one expiry
/// through the production `registry::create_expiry_market` path. This reaches the
/// pricing/freshness guards more cheaply than the full `flow_test_helpers` market:
/// no manager setup or expiry-cash seeding. The Pyth spot is seeded through
/// `pyth_feed::record_raw_for_testing` because a real `pyth_lazer::Update` has no
/// public Move constructor; the BS surface uses the stub verifier's public
/// `update::new_update`. `ProtocolConfig`/`Registry`/`OracleRegistry` are taken
/// per-transaction (never held), mirroring `flow_test_helpers`.
#[test_only]
module deepbook_predict::oracle_fixture;

use block_scholes_oracle::update;
use deepbook_predict::{
    admin::AdminCap,
    market_lifecycle_cap::MarketLifecycleCap,
    plp::{Self, PoolVault},
    pricing::{Self, Pricer},
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::destroy;
use sui::{clock::{Self, Clock}, test_scenario::{Self as test, Scenario, return_shared}};

const PYTH_EXPONENT_NEG_9: u16 = 9;

/// Scenario-local fixture objects. `Registry`/`ProtocolConfig`/`OracleRegistry` are
/// real shared objects taken per-transaction, not held here.
public struct OracleFixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    lifecycle_cap: MarketLifecycleCap,
    clock: Clock,
    pyth_id: ID,
    bs_id: ID,
    expiry_id: ID,
    expiry: u64,
}

/// Stand up a registry + config + the two propbook feeds + an `ExpiryMarket` for
/// `expiry`, using the default cadence with the supplied `tick` size. No live spot
/// is read at creation (absolute ticks); seed live data with
/// `prepare_live_oracle`/`prepare_real_oracle`.
public fun setup_oracle(_spot: u64, tick: u64, expiry: u64): OracleFixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());

    // tx1: register the underlying and create the two feeds.
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let config = scenario.take_shared<ProtocolConfig>();
    registry.register_underlying(&config, &admin_cap, test_constants::propbook_underlying_id());
    registry.set_cadence_config(
        &config,
        &admin_cap,
        test_constants::default_cadence_id(),
        tick,
        test_constants::default_max_expiry_allocation(),
        test_constants::default_cadence_window_size(),
    );
    return_shared(config);
    return_shared(registry);
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    let bs_id = propbook_registry::create_and_share_block_scholes_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: bind both feeds to the canonical underlying.
    scenario.next_tx(test_constants::admin());
    test_helpers::bind_feeds_to_underlying(&scenario, pyth_id, bs_id);

    // tx3: create the expiry market on the unfunded vault through the registry.
    scenario.next_tx(test_constants::admin());
    let mut vault = scenario.take_shared<PoolVault>();
    let mut registry = scenario.take_shared<Registry>();
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let mut creation_clock = clock::create_for_testing(scenario.ctx());
    creation_clock.set_for_testing(expiry - test_constants::default_cadence_period_ms());
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        scenario.ctx(),
    );
    let expiry_id = registry.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        &creation_clock,
        scenario.ctx(),
    );
    creation_clock.destroy_for_testing();
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(registry);
    return_shared(vault);

    scenario.next_tx(test_constants::admin());

    OracleFixture { scenario, admin_cap, lifecycle_cap, clock, pyth_id, bs_id, expiry_id, expiry }
}

/// `setup_oracle` with the default tick and the default (far) expiry.
public fun setup_oracle_default(): OracleFixture {
    setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::default_expiry_ms(),
    )
}

/// Take the two feeds + the protocol config for a pricing test. Pair with
/// `return_oracle`.
public fun take_oracle(
    self: &mut OracleFixture,
): (PythFeed, BlockScholesFeed, OracleRegistry, ProtocolConfig) {
    (
        self.scenario.take_shared_by_id<PythFeed>(self.pyth_id),
        self.scenario.take_shared_by_id<BlockScholesFeed>(self.bs_id),
        self.scenario.take_shared<OracleRegistry>(),
        self.scenario.take_shared<ProtocolConfig>(),
    )
}

/// Return the three shared objects taken by `take_oracle`.
public fun return_oracle(
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    config: ProtocolConfig,
) {
    return_shared(bs);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
}

public fun load_pricer(
    self: &OracleFixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        oracle_registry,
        test_constants::propbook_underlying_id(),
        pyth,
        bs,
        self.expiry,
        &self.clock,
    )
}

/// Seed a fresh live Pyth spot + Block Scholes surface so quotes are available, at
/// the fixture's default live source timestamp. `live_price` is used as both spot
/// and forward (basis = 1.0).
public fun prepare_live_oracle(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    pyth: &mut PythFeed,
    live_price: u64,
) {
    self.prepare_real_oracle(
        bs,
        pyth,
        live_price,
        live_price,
        test_constants::default_svi_a(),
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
}

/// Seed a fresh Pyth spot + an explicit Block Scholes surface (real spot/forward +
/// SVI) for exact-pricing tests over real on-chain scenarios. On the fresh-Pyth
/// path pricing derives the live forward as `mul(spot, forward/spot)`.
public fun prepare_real_oracle(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    pyth: &mut PythFeed,
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    let live_ts = test_constants::live_source_timestamp_ms();
    store_pyth_spot(pyth, spot, live_ts, live_ts);
    let bs_update = update::new_update(
        test_constants::pyth_feed_id(),
        self.expiry,
        live_ts,
        spot,
        forward,
        svi_a,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
    bs.update(bs_update, &self.clock, self.scenario.ctx());
}

/// Overwrite the Pyth spot directly (for staleness / pricing-source tests), keeping
/// the fixture clock as the on-chain landing timestamp.
public fun set_pyth(
    self: &OracleFixture,
    pyth: &mut PythFeed,
    price: u64,
    source_timestamp_ms: u64,
) {
    store_pyth_spot(pyth, price, source_timestamp_ms, self.clock.timestamp_ms());
}

// === Accessors ===

public fun lifecycle_cap(self: &OracleFixture): &MarketLifecycleCap { &self.lifecycle_cap }

public fun clock(self: &OracleFixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut OracleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun scenario_mut(self: &mut OracleFixture): &mut Scenario { &mut self.scenario }

public fun pyth_id(self: &OracleFixture): ID { self.pyth_id }

public fun bs_id(self: &OracleFixture): ID { self.bs_id }

public fun expiry_id(self: &OracleFixture): ID { self.expiry_id }

public fun expiry(self: &OracleFixture): u64 { self.expiry }

/// Tear down the fixture and all owned objects. Shared objects are released via
/// `return_oracle` in the test and reclaimed by `end`.
public fun finish(self: OracleFixture) {
    let OracleFixture {
        scenario,
        admin_cap,
        lifecycle_cap,
        clock,
        pyth_id: _,
        bs_id: _,
        expiry_id: _,
        expiry: _,
    } = self;
    lifecycle_cap.destroy();
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}

fun store_pyth_spot(
    pyth: &mut PythFeed,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    pyth_feed::record_raw_for_testing(
        pyth,
        spot,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        source_timestamp_ms * 1000,
        update_timestamp_ms,
        false,
    );
}
