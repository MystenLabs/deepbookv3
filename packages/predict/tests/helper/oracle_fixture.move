// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minimal production-valid feed bring-up for `pricing` error-path and exact-pricing
/// tests.
///
/// Stands up the standalone propbook feeds — `PythFeed`, BS spot, BS forward, and
/// BS SVI — and an `ExpiryMarket` for one expiry through the production
/// `registry::create_expiry_market` path. This reaches the pricing/freshness guards
/// more cheaply than the full `flow_test_helpers` market: no manager setup or
/// expiry-cash seeding. The Pyth spot is seeded through
/// `pyth_feed::record_raw_for_testing` because a real `pyth_lazer::Update` has no
/// public Move constructor; the BS feeds use the stub verifier's split public update
/// constructors. `ProtocolConfig`/`Registry`/`OracleRegistry` are taken
/// per-transaction (never held), mirroring `flow_test_helpers`.
#[test_only]
module deepbook_predict::oracle_fixture;

use block_scholes_oracle::update;
use deepbook_predict::{
    admin::AdminCap,
    block_scholes_feed::{Self as bs_feed, BlockScholesFeed},
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    plp::{Self, PoolVault},
    pricing::{Self, Pricer},
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
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
    bs_spot_id: ID,
    bs_forward_id: ID,
    bs_svi_id: ID,
    expiry_id: ID,
    expiry: u64,
}

/// Transaction-local oracle/config objects used by pricing tests.
public struct OracleBundle {
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    config: ProtocolConfig,
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

    // tx1: register the underlying and create the pricing feeds.
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
        test_constants::default_admission_tick_size(),
        test_constants::default_max_expiry_allocation(),
        test_constants::default_initial_expiry_cash(),
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
    let bs_spot_id = propbook_registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    let bs_forward_id = propbook_registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    let bs_svi_id = propbook_registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: bind all pricing feeds to the canonical underlying.
    scenario.next_tx(test_constants::admin());
    test_helpers::bind_feeds_to_underlying(
        &scenario,
        pyth_id,
        bs_spot_id,
        bs_forward_id,
        bs_svi_id,
    );

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

    OracleFixture {
        scenario,
        admin_cap,
        lifecycle_cap,
        clock,
        pyth_id,
        bs_spot_id,
        bs_forward_id,
        bs_svi_id,
        expiry_id,
        expiry,
    }
}

/// `setup_oracle` with the default tick and the default (far) expiry.
public fun setup_oracle_default(): OracleFixture {
    setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::default_expiry_ms(),
    )
}

/// Take oracle/config objects as one named bundle to avoid wide tuple plumbing.
public fun take_oracle_bundle(self: &mut OracleFixture): OracleBundle {
    OracleBundle {
        pyth: self.scenario.take_shared_by_id<PythFeed>(self.pyth_id),
        bs: bs_feed::new(
            self.scenario.take_shared_by_id<BlockScholesSpotFeed>(self.bs_spot_id),
            self.scenario.take_shared_by_id<BlockScholesForwardFeed>(self.bs_forward_id),
            self.scenario.take_shared_by_id<BlockScholesSVIFeed>(self.bs_svi_id),
        ),
        oracle_registry: self.scenario.take_shared<OracleRegistry>(),
        config: self.scenario.take_shared<ProtocolConfig>(),
    }
}

/// Return the shared objects taken by `take_oracle_bundle`.
public fun return_oracle_bundle(bundle: OracleBundle) {
    let OracleBundle { pyth, bs, oracle_registry, config } = bundle;
    bs.return_feed();
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
        self.expiry_id,
        test_constants::propbook_underlying_id(),
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        self.expiry,
        &self.clock,
    )
}

/// Load a live pricer from an oracle bundle.
public fun load_pricer_bundle(self: &OracleFixture, oracle: &OracleBundle): Pricer {
    self.load_pricer(&oracle.config, &oracle.oracle_registry, &oracle.pyth, &oracle.bs)
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

/// Seed a fresh live oracle through an oracle bundle.
public fun prepare_live_oracle_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    live_price: u64,
) {
    self.prepare_live_oracle(&mut oracle.bs, &mut oracle.pyth, live_price);
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
    bs
        .spot_mut()
        .update(
            update::new_spot_update(test_constants::pyth_feed_id(), live_ts, spot),
            &self.clock,
        );
    bs
        .forward_mut()
        .update(
            update::new_forward_update(
                test_constants::pyth_feed_id(),
                self.expiry,
                live_ts,
                forward,
            ),
            &self.clock,
            self.scenario.ctx(),
        );
    bs
        .svi_mut()
        .update(
            update::new_svi_update(
                test_constants::pyth_feed_id(),
                self.expiry,
                live_ts,
                svi_a,
                svi_b,
                svi_sigma,
                svi_rho_magnitude,
                svi_rho_is_negative,
                svi_m_magnitude,
                svi_m_is_negative,
            ),
            &self.clock,
            self.scenario.ctx(),
        );
}

/// Seed a fresh explicit oracle surface through an oracle bundle.
public fun prepare_real_oracle_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
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
    self.prepare_real_oracle(
        &mut oracle.bs,
        &mut oracle.pyth,
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
}

/// Overwrite only the BS spot row through the real ingest path.
public fun set_bs_spot_for_testing(
    self: &OracleFixture,
    bs: &mut BlockScholesFeed,
    source_timestamp_ms: u64,
    spot: u64,
) {
    bs
        .spot_mut()
        .update(
            update::new_spot_update(test_constants::pyth_feed_id(), source_timestamp_ms, spot),
            &self.clock,
        );
}

/// Overwrite only the BS spot row through an oracle bundle.
public fun set_bs_spot_for_testing_bundle(
    self: &OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    spot: u64,
) {
    self.set_bs_spot_for_testing(&mut oracle.bs, source_timestamp_ms, spot);
}

/// Overwrite only the BS forward row for this fixture's expiry through the real
/// ingest path. Used by stale-surface guard tests that need fresh prices but a
/// stale SVI row.
public fun set_bs_forward_for_testing(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    source_timestamp_ms: u64,
    forward: u64,
) {
    bs
        .forward_mut()
        .update(
            update::new_forward_update(
                test_constants::pyth_feed_id(),
                self.expiry,
                source_timestamp_ms,
                forward,
            ),
            &self.clock,
            self.scenario.ctx(),
        );
}

/// Overwrite only the BS forward row through an oracle bundle.
public fun set_bs_forward_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    forward: u64,
) {
    self.set_bs_forward_for_testing(&mut oracle.bs, source_timestamp_ms, forward);
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

/// Overwrite the bundled Pyth spot directly.
public fun set_pyth_bundle(
    self: &OracleFixture,
    oracle: &mut OracleBundle,
    price: u64,
    source_timestamp_ms: u64,
) {
    self.set_pyth(&mut oracle.pyth, price, source_timestamp_ms);
}

/// Insert an exact historical Pyth spot keyed by `source_timestamp_ms`.
public fun insert_exact_pyth(
    _self: &OracleFixture,
    pyth: &mut PythFeed,
    price: u64,
    source_timestamp_ms: u64,
) {
    pyth_feed::record_raw_for_testing(
        pyth,
        price,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        source_timestamp_ms * 1000,
        source_timestamp_ms,
        true,
    );
}

/// Insert an exact historical Pyth spot into a bundle.
public fun insert_exact_pyth_bundle(
    self: &OracleFixture,
    oracle: &mut OracleBundle,
    price: u64,
    source_timestamp_ms: u64,
) {
    self.insert_exact_pyth(&mut oracle.pyth, price, source_timestamp_ms);
}

/// Take this fixture's expiry market for direct market-boundary tests.
public fun take_expiry_market(self: &mut OracleFixture): ExpiryMarket {
    let expiry_id = self.expiry_id;
    self.scenario.take_shared_by_id<ExpiryMarket>(expiry_id)
}

/// Return the expiry market taken by `take_expiry_market`.
public fun return_expiry_market(market: ExpiryMarket) {
    return_shared(market);
}

// === Accessors ===

public fun pyth(oracle: &OracleBundle): &PythFeed { &oracle.pyth }

public fun bs(oracle: &OracleBundle): &BlockScholesFeed { &oracle.bs }

public fun oracle_registry(oracle: &OracleBundle): &OracleRegistry { &oracle.oracle_registry }

public fun config(oracle: &OracleBundle): &ProtocolConfig { &oracle.config }

public fun lifecycle_cap(self: &OracleFixture): &MarketLifecycleCap { &self.lifecycle_cap }

public fun clock(self: &OracleFixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut OracleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun scenario_mut(self: &mut OracleFixture): &mut Scenario { &mut self.scenario }

public fun pyth_id(self: &OracleFixture): ID { self.pyth_id }

public fun bs_spot_id(self: &OracleFixture): ID { self.bs_spot_id }

public fun bs_forward_id(self: &OracleFixture): ID { self.bs_forward_id }

public fun bs_svi_id(self: &OracleFixture): ID { self.bs_svi_id }

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
        bs_spot_id: _,
        bs_forward_id: _,
        bs_svi_id: _,
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
