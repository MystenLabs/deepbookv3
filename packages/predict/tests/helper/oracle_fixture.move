// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minimal production-valid feed bring-up for `pricing` error-path and exact-pricing
/// tests.
///
/// Stands up the standalone propbook oracles — `PythFeed` plus the per-underlying Block
/// Scholes store pair — and an `ExpiryMarket` for one expiry through the production
/// `registry::create_and_share_expiry_market` path. This reaches the pricing/freshness guards
/// more cheaply than the full `flow_test_helpers` market: no manager setup or
/// expiry-cash seeding. The Pyth spot is seeded through
/// `pyth_feed::record_raw_for_testing` because a real `pyth_lazer::Update` has no
/// public Move constructor; the stores are seeded through the verifier's test-only
/// batch constructors, driving the same batch entries a relayer calls.
/// `ProtocolConfig`/`Registry`/`OracleRegistry` are taken per-transaction (never
/// held), mirroring `flow_test_helpers`.
#[test_only]
module deepbook_predict::oracle_fixture;

use bs_oracle::verify;
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
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    test_scenario::{Self as test, Scenario, return_shared},
    tx_context::{Self, TxContext}
};

const PYTH_EXPONENT_NEG_9: u16 = 9;

/// Scenario-local fixture objects. `Registry`/`ProtocolConfig`/`OracleRegistry` are
/// real shared objects taken per-transaction, not held here.
public struct OracleFixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    propbook_admin_cap: RegistryAdminCap,
    lifecycle_cap: MarketLifecycleCap,
    clock: Clock,
    pyth_id: ID,
    bs_values_id: ID,
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

/// Feed IDs for a transaction-local oracle bundle.
public struct OracleBundleIds has copy, drop {
    pyth_id: ID,
    bs_values_id: ID,
    bs_svi_id: ID,
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
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_constants::propbook_underlying_id(),
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
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: bind Pyth and create the canonical Block Scholes store pair for the underlying.
    scenario.next_tx(test_constants::admin());
    let propbook_admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let (bs_values_id, bs_svi_id) = test_helpers::bind_feeds_to_underlying(
        &mut scenario,
        &propbook_admin_cap,
        pyth_id,
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
    let expiry_id = registry.create_and_share_expiry_market(
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
        propbook_admin_cap,
        lifecycle_cap,
        clock,
        pyth_id,
        bs_values_id,
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
    let ids = OracleBundleIds {
        pyth_id: self.pyth_id,
        bs_values_id: self.bs_values_id,
        bs_svi_id: self.bs_svi_id,
    };
    self.take_oracle_bundle_by_ids(ids)
}

/// Take oracle/config objects for explicit feed IDs. Used by binding-replacement
/// tests where the market stays fixed but Propbook's current feed objects change.
public fun take_oracle_bundle_by_ids(self: &mut OracleFixture, ids: OracleBundleIds): OracleBundle {
    let OracleBundleIds { pyth_id, bs_values_id, bs_svi_id } = ids;
    OracleBundle {
        pyth: self.scenario.take_shared_by_id<PythFeed>(pyth_id),
        bs: bs_feed::new(
            self.scenario.take_shared_by_id<BlockScholesValueStore>(bs_values_id),
            self.scenario.take_shared_by_id<BlockScholesSVIStore>(bs_svi_id),
        ),
        oracle_registry: self.scenario.take_shared<OracleRegistry>(),
        config: self.scenario.take_shared<ProtocolConfig>(),
    }
}

/// Create replacement Propbook feeds for `source_id` and atomically rebind the
/// fixture's underlying to them. The existing market stores only the underlying
/// ID, so later `take_oracle_bundle_by_ids` calls can prove Predict follows the
/// new current binding without recreating the market.
/// Only the Pyth binding is replaced: a Block Scholes store pair is created canonical for its
/// underlying and never rebound, so the returned ids keep the fixture's original stores.
public fun create_and_rebind_oracle(self: &mut OracleFixture, source_id: u32): OracleBundleIds {
    self.scenario.next_tx(test_constants::admin());
    let mut oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        source_id,
        self.scenario.ctx(),
    );
    return_shared(oracle_registry);

    self.scenario.next_tx(test_constants::admin());
    let mut oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let pyth = self.scenario.take_shared_by_id<PythFeed>(pyth_id);
    propbook_registry::replace_pyth_binding_for_underlying(
        &mut oracle_registry,
        &self.propbook_admin_cap,
        &pyth,
        test_constants::propbook_underlying_id(),
    );
    return_shared(pyth);
    return_shared(oracle_registry);

    self.scenario.next_tx(test_constants::admin());
    OracleBundleIds { pyth_id, bs_values_id: self.bs_values_id, bs_svi_id: self.bs_svi_id }
}

/// Create a Block Scholes store pair bound to a different underlying, for tests proving Predict
/// rejects a store that is not the one bound to the market's underlying.
public fun create_foreign_block_scholes_stores(
    self: &mut OracleFixture,
    propbook_underlying_id: u32,
): propbook_registry::BlockScholesStorePair {
    self.scenario.next_tx(test_constants::admin());
    let mut oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let pair = propbook_registry::create_and_share_block_scholes_stores(
        &mut oracle_registry,
        &self.propbook_admin_cap,
        propbook_underlying_id,
        test_constants::foreign_block_scholes_base_asset(),
        self.scenario.ctx(),
    );
    return_shared(oracle_registry);
    self.scenario.next_tx(test_constants::admin());
    pair
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
    self: &mut OracleFixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): Pricer {
    self.load_pricer_with_stores(config, oracle_registry, pyth, bs.values(), bs.svi())
}

/// Load a live pricer while substituting explicit BS stores (binding-guard tests).
public fun load_pricer_with_stores(
    self: &mut OracleFixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
): Pricer {
    let expiry_market_id = self.expiry_id;
    self.load_pricer_bound_to(
        config,
        oracle_registry,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
    )
}

/// Load a live pricer bound to an explicit `expiry_market_id` (wrong-pricer tests).
public fun load_pricer_bound_to(
    self: &mut OracleFixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry_market_id: ID,
): Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        oracle_registry,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
        test_constants::propbook_underlying_id(),
        self.expiry,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Load a live pricer from an oracle bundle.
public fun load_pricer_bundle(self: &mut OracleFixture, oracle: &OracleBundle): Pricer {
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
    self.prepare_real_oracle_with_svi_source(
        bs,
        pyth,
        live_price,
        live_price,
        test_constants::default_svi_a(),
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
        test_constants::live_source_timestamp_ms(),
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
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    let svi_source_timestamp_ms = self.clock.timestamp_ms();
    self.prepare_real_oracle_with_svi_source(
        bs,
        pyth,
        spot,
        forward,
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
        svi_source_timestamp_ms,
    );
}

fun prepare_real_oracle_with_svi_source(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    pyth: &mut PythFeed,
    spot: u64,
    forward: u64,
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
    svi_source_timestamp_ms: u64,
) {
    let live_ts = test_constants::live_source_timestamp_ms();
    store_pyth_spot(&mut self.scenario, pyth, spot, live_ts, live_ts);
    apply_spot_batch(
        &mut self.scenario,
        bs,
        live_ts,
        live_ts,
        spot,
        &self.clock,
    );
    apply_forward_batch(
        &mut self.scenario,
        bs,
        self.expiry,
        live_ts,
        live_ts,
        forward,
        &self.clock,
    );
    self.apply_svi_batch(
        bs,
        svi_source_timestamp_ms,
        svi_source_timestamp_ms,
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

/// Seed a fresh explicit oracle surface through an oracle bundle.
public fun prepare_real_oracle_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    spot: u64,
    forward: u64,
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
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
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

/// Overwrite only the BS spot row through the real ingest path.
/// `source_timestamp_ms` stamps both provider clocks — the series moved, so its model time and the
/// envelope carrying it are the same. Use `retransmit_bs_svi_for_testing` for the case where they
/// differ.
public fun set_bs_spot_for_testing(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    source_timestamp_ms: u64,
    spot: u64,
) {
    apply_spot_batch(
        &mut self.scenario,
        bs,
        source_timestamp_ms,
        source_timestamp_ms,
        spot,
        &self.clock,
    );
}

/// Overwrite only the BS spot row through an oracle bundle.
public fun set_bs_spot_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    spot: u64,
) {
    self.set_bs_spot_for_testing(&mut oracle.bs, source_timestamp_ms, spot);
}

/// Overwrite only the BS spot row with its provider-native width. Used to pin the named width
/// boundary that production pricing applies after the verified store read.
public fun set_bs_spot_raw_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    spot: u128,
) {
    let sid = oracle.bs.values().spot_sid();
    let batch = verify::new_value_batch_for_testing(
        source_timestamp_ms,
        vector[verify::new_value_update_for_testing(sid, source_timestamp_ms, spot)],
    );
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    oracle.bs.values_mut().apply_spot_batch(batch, &self.clock, &ctx);
    end_seed_tx(restore);
}

/// Overwrite only the BS forward row with its provider-native width. Used to pin the same named
/// width boundary independently from the spot row.
public fun set_bs_forward_raw_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    forward: u128,
) {
    let sid = oracle.bs.values().forward_sid(self.expiry);
    let batch = verify::new_value_batch_for_testing(
        source_timestamp_ms,
        vector[verify::new_value_update_for_testing(sid, source_timestamp_ms, forward)],
    );
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    oracle.bs.values_mut().apply_forward_batch(batch, vector[self.expiry], &self.clock, &ctx);
    end_seed_tx(restore);
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
    apply_forward_batch(
        &mut self.scenario,
        bs,
        self.expiry,
        source_timestamp_ms,
        source_timestamp_ms,
        forward,
        &self.clock,
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

/// Retransmit the BS spot pinned to its original model time inside a newer envelope.
public fun retransmit_bs_spot_for_testing(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    spot: u64,
) {
    apply_spot_batch(
        &mut self.scenario,
        &mut oracle.bs,
        model_timestamp_ms,
        published_at_ms,
        spot,
        &self.clock,
    );
}

/// Retransmit the BS forward for this fixture's expiry pinned to its original model time inside a
/// newer envelope.
public fun retransmit_bs_forward_for_testing(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    forward: u64,
) {
    apply_forward_batch(
        &mut self.scenario,
        &mut oracle.bs,
        self.expiry,
        model_timestamp_ms,
        published_at_ms,
        forward,
        &self.clock,
    );
}

/// Overwrite only the BS SVI row for this fixture's expiry through the real
/// ingest path.
public fun set_bs_svi_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    self.apply_svi_batch(
        &mut oracle.bs,
        source_timestamp_ms,
        source_timestamp_ms,
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

/// Overwrite the BS SVI row with provider-native widths. Callers vary one field at a time while
/// keeping the others at production-valid defaults to pin every Predict narrowing boundary.
public fun set_bs_svi_raw_for_testing_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    source_timestamp_ms: u64,
    svi_a_magnitude: u128,
    svi_b: u128,
    svi_sigma: u128,
    svi_rho_magnitude: u128,
    svi_m_magnitude: u128,
) {
    let sid = oracle.bs.svi().svi_sid(self.expiry);
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    oracle
        .bs
        .svi_mut()
        .apply_svi_batch(
            verify::new_svi_batch_for_testing(
                source_timestamp_ms,
                vector[
                    verify::new_svi_for_testing(
                        sid,
                        source_timestamp_ms,
                        svi_a_magnitude,
                        false,
                        svi_b,
                        svi_sigma,
                        svi_rho_magnitude,
                        false,
                        svi_m_magnitude,
                        false,
                    ),
                ],
            ),
            vector[self.expiry],
            &self.clock,
            &ctx,
        );
    end_seed_tx(restore);
}

/// Re-send an unchanged SVI tuple in a later batch: the envelope advances while the tuple keeps the
/// model time it was first calibrated at. This is what a provider retransmission looks like, and it
/// is the sequence the roll-down anchors on.
public fun retransmit_bs_svi_for_testing(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    self.apply_svi_batch(
        &mut oracle.bs,
        model_timestamp_ms,
        published_at_ms,
        svi_a_magnitude,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
}

/// Overwrite the Pyth spot directly (for staleness / pricing-source tests), keeping
/// the fixture clock as the on-chain landing timestamp.
public fun set_pyth(
    self: &mut OracleFixture,
    pyth: &mut PythFeed,
    price: u64,
    source_timestamp_ms: u64,
) {
    store_pyth_spot(
        &mut self.scenario,
        pyth,
        price,
        source_timestamp_ms,
        self.clock.timestamp_ms(),
    );
}

/// Overwrite the bundled Pyth spot directly.
public fun set_pyth_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    price: u64,
    source_timestamp_ms: u64,
) {
    self.set_pyth(&mut oracle.pyth, price, source_timestamp_ms);
}

/// Deliver `price` under an envelope stamped `envelope_timestamp_ms` while Pyth
/// generated it at `feed_update_timestamp_ms` — a price Pyth carried forward
/// because it had no fresh aggregate for this feed.
public fun carry_pyth_bundle(
    self: &mut OracleFixture,
    oracle: &mut OracleBundle,
    price: u64,
    feed_update_timestamp_ms: u64,
    envelope_timestamp_ms: u64,
) {
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    pyth_feed::record_raw_for_testing(
        &mut oracle.pyth,
        price,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        feed_update_timestamp_ms * 1000,
        envelope_timestamp_ms * 1000,
        self.clock.timestamp_ms(),
        false,
        &ctx,
    );
    end_seed_tx(restore);
}

/// Insert an exact historical Pyth spot keyed by `source_timestamp_ms`.
public fun insert_exact_pyth(
    self: &mut OracleFixture,
    pyth: &mut PythFeed,
    price: u64,
    source_timestamp_ms: u64,
) {
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    pyth_feed::record_raw_for_testing(
        pyth,
        price,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        source_timestamp_ms * 1000,
        source_timestamp_ms * 1000,
        source_timestamp_ms,
        true,
        &ctx,
    );
    end_seed_tx(restore);
}

/// Insert an exact historical Pyth spot into a bundle.
public fun insert_exact_pyth_bundle(
    self: &mut OracleFixture,
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

/// Flip the live-forward source selector through the real admin entrypoint.
public fun set_use_pyth_spot_for_forward_bundle(
    self: &OracleFixture,
    oracle: &mut OracleBundle,
    enabled: bool,
) {
    oracle.config.set_use_pyth_spot_for_forward(&self.admin_cap, enabled);
}

// === Accessors ===

public fun pyth(oracle: &OracleBundle): &PythFeed { &oracle.pyth }

public fun bs(oracle: &OracleBundle): &BlockScholesFeed { &oracle.bs }

public fun oracle_registry(oracle: &OracleBundle): &OracleRegistry { &oracle.oracle_registry }

public fun config(oracle: &OracleBundle): &ProtocolConfig { &oracle.config }

/// Tighten the live Pyth freshness window below the Block Scholes price window, restoring the
/// stale-Pyth/fresh-BS gap that the equal production defaults no longer provide.
public fun set_pyth_spot_freshness_for_testing(
    self: &OracleFixture,
    oracle: &mut OracleBundle,
    value: u64,
) {
    oracle.config.set_pyth_spot_freshness_ms(&self.admin_cap, value);
}

public fun lifecycle_cap(self: &OracleFixture): &MarketLifecycleCap { &self.lifecycle_cap }

public fun clock(self: &OracleFixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut OracleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

public fun scenario_mut(self: &mut OracleFixture): &mut Scenario { &mut self.scenario }

public fun pyth_id(self: &OracleFixture): ID { self.pyth_id }

public fun bs_values_id(self: &OracleFixture): ID { self.bs_values_id }

public fun bs_svi_id(self: &OracleFixture): ID { self.bs_svi_id }

public fun expiry_id(self: &OracleFixture): ID { self.expiry_id }

public fun expiry(self: &OracleFixture): u64 { self.expiry }

/// Tear down the fixture and all owned objects. Shared objects are released via
/// `return_oracle_bundle` in the test and reclaimed by `end`.
public fun finish(self: OracleFixture) {
    let OracleFixture {
        scenario,
        admin_cap,
        propbook_admin_cap,
        lifecycle_cap,
        clock,
        pyth_id: _,
        bs_values_id: _,
        bs_svi_id: _,
        expiry_id: _,
        expiry: _,
    } = self;
    lifecycle_cap.destroy();
    destroy(propbook_admin_cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}

/// Land one spot observation through the real verified-batch path.
fun apply_spot_batch(
    scenario: &mut Scenario,
    bs: &mut BlockScholesFeed,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    value: u64,
    clock: &Clock,
) {
    let sid = bs.values().spot_sid();
    let batch = verify::new_value_batch_for_testing(
        published_at_ms,
        vector[verify::new_value_update_for_testing(sid, model_timestamp_ms, value as u128)],
    );
    let (ctx, restore) = begin_seed_tx(scenario);
    bs.values_mut().apply_spot_batch(batch, clock, &ctx);
    end_seed_tx(restore);
}

/// Land one forward observation through the real verified-batch path.
fun apply_forward_batch(
    scenario: &mut Scenario,
    bs: &mut BlockScholesFeed,
    expiry_ms: u64,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    value: u64,
    clock: &Clock,
) {
    let sid = bs.values().forward_sid(expiry_ms);
    let batch = verify::new_value_batch_for_testing(
        published_at_ms,
        vector[verify::new_value_update_for_testing(sid, model_timestamp_ms, value as u128)],
    );
    let (ctx, restore) = begin_seed_tx(scenario);
    bs.values_mut().apply_forward_batch(batch, vector[expiry_ms], clock, &ctx);
    end_seed_tx(restore);
}

/// Land one SVI observation through the real verified-batch path.
fun apply_svi_batch(
    self: &mut OracleFixture,
    bs: &mut BlockScholesFeed,
    model_timestamp_ms: u64,
    published_at_ms: u64,
    svi_a_magnitude: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
) {
    let sid = bs.svi().svi_sid(self.expiry);
    let (ctx, restore) = begin_seed_tx(&mut self.scenario);
    bs
        .svi_mut()
        .apply_svi_batch(
            verify::new_svi_batch_for_testing(
                published_at_ms,
                vector[
                    verify::new_svi_for_testing(
                        sid,
                        model_timestamp_ms,
                        svi_a_magnitude as u128,
                        svi_a_is_negative,
                        svi_b as u128,
                        svi_sigma as u128,
                        svi_rho_magnitude as u128,
                        svi_rho_is_negative,
                        svi_m_magnitude as u128,
                        svi_m_is_negative,
                    ),
                ],
            ),
            vector[self.expiry],
            &self.clock,
            &ctx,
        );
    end_seed_tx(restore);
}

/// Snapshot of native TxContext fields. `tx_context::dummy()`/`create()` call
/// native `replace()`, which rewrites the process-global sender used by
/// `ctx.sender()` — so seed writes must restore afterwards.
public struct SeedTxRestore has drop {
    sender: address,
    tx_hash: vector<u8>,
    epoch: u64,
    epoch_timestamp_ms: u64,
    ids_created: u64,
    rgp: u64,
    gas_price: u64,
    gas_budget: u64,
    sponsor: Option<address>,
}

/// Begin a seed write stamped with a digest distinct from any `test_scenario`
/// transaction. Pair with `end_seed_tx`. Attack tests that need a real same-tx
/// write pass `scenario.ctx()` explicitly instead.
fun begin_seed_tx(scenario: &mut Scenario): (TxContext, SeedTxRestore) {
    let restore = SeedTxRestore {
        sender: test::sender(scenario),
        tx_hash: *scenario.ctx().digest(),
        epoch: scenario.ctx().epoch(),
        epoch_timestamp_ms: scenario.ctx().epoch_timestamp_ms(),
        ids_created: scenario.ctx().ids_created(),
        rgp: scenario.ctx().reference_gas_price(),
        gas_price: scenario.ctx().gas_price(),
        gas_budget: scenario.ctx().gas_budget(),
        sponsor: scenario.ctx().sponsor(),
    };
    (tx_context::dummy(), restore)
}

fun end_seed_tx(restore: SeedTxRestore) {
    let SeedTxRestore {
        sender,
        tx_hash,
        epoch,
        epoch_timestamp_ms,
        ids_created,
        rgp,
        gas_price,
        gas_budget,
        sponsor,
    } = restore;
    let _ctx = tx_context::create(
        sender,
        tx_hash,
        epoch,
        epoch_timestamp_ms,
        ids_created,
        rgp,
        gas_price,
        gas_budget,
        sponsor,
    );
}

fun store_pyth_spot(
    scenario: &mut Scenario,
    pyth: &mut PythFeed,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    let (ctx, restore) = begin_seed_tx(scenario);
    pyth_feed::record_raw_for_testing(
        pyth,
        spot,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        source_timestamp_ms * 1000,
        source_timestamp_ms * 1000,
        update_timestamp_ms,
        false,
        &ctx,
    );
    end_seed_tx(restore);
}
