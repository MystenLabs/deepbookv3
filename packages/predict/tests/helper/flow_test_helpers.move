// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared bring-up for production-valid Predict trade-flow tests.
///
/// Stands up a tradeable market through the real creation path, with explicit
/// test-only expiry cash seeding while pool funding is absent, and exposes thin
/// wrappers for the trade flows.
///
/// The `Registry`, `ProtocolConfig`, and propbook `OracleRegistry` are real shared
/// objects (created via the production-mirroring `init_for_testing`s). They are NOT
/// held as `Fixture` fields: a `take_shared` object cannot cross a `next_tx`
/// boundary, so each method takes the config/registry it needs as a local and
/// returns it before the next transaction. The market reads two standalone propbook
/// feeds — a `PythFeed` (global spot) and a `BlockScholesFeed` (per-expiry
/// surface). The Pyth spot is seeded through `pyth_feed::record_raw_for_testing`
/// because a real `pyth_lazer::Update` has no public Move constructor; the BS
/// surface uses the stub verifier's public `update::new_update`. Exact settlement
/// spots are inserted through the same Pyth testing seam; production settlement is
/// passive inside the normal redeem and pool-rebalance flows.
#[test_only]
module deepbook_predict::flow_test_helpers;

use block_scholes_oracle::update;
use deepbook_predict::{
    admin::AdminCap,
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    plp::{Self, PoolVault, PoolValuation},
    predict_manager::PredictManager,
    pricing,
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use dusdc::dusdc::DUSDC;
use propbook::{
    block_scholes_feed::BlockScholesFeed,
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, test_scenario::{Self as test, Scenario, return_shared}};

const PYTH_EXPONENT_NEG_9: u16 = 9;

/// A representative finite strike tick the flow tests mint against. Re-exported
/// from `test_constants` so existing call sites keep one source of truth.
public fun strike_tick(): u64 { test_constants::default_strike_tick() }

/// Scenario-local objects shared across one flow test. `Registry`/`ProtocolConfig`/
/// `OracleRegistry` are real shared objects taken per-transaction, not held here.
public struct Fixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    lifecycle_cap: MarketLifecycleCap,
    clock: Clock,
    vault_id: ID,
    pyth_id: ID,
    bs_id: ID,
    tick_size: u64,
}

/// Stand up a registry + protocol config + an empty PLP vault + the two propbook
/// feeds (a `PythFeed` and a `BlockScholesFeed`) for the admin-approved `tick`
/// size. base_fee is floored to 1 and min_ask to 0 so small test quantities are
/// admissible. Creation reads no spot (strikes are absolute ticks), so no spot is
/// seeded here — `prepare_live_oracle` seeds the live spot + surface for pricing.
public fun setup_market(tick: u64): Fixture {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());

    // tx1: configure protocol params, register the underlying, create feeds.
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_min_ask_price(&admin_cap, 0);
    return_shared(config);
    let mut registry = scenario.take_shared<Registry>();
    registry::register_underlying(
        &mut registry,
        &admin_cap,
        test_constants::propbook_underlying_id(),
        tick,
    );
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

    // tx2: bind both feeds to the canonical underlying, mint the lifecycle cap,
    // and capture the vault id.
    scenario.next_tx(test_constants::admin());
    test_helpers::bind_feeds_to_underlying(&scenario, pyth_id, bs_id);
    let mut registry = scenario.take_shared<Registry>();
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut registry, &admin_cap, scenario.ctx());
    return_shared(registry);
    let vault = scenario.take_shared<PoolVault>();
    let vault_id = vault.id();
    return_shared(vault);

    scenario.next_tx(test_constants::admin());

    Fixture { scenario, admin_cap, lifecycle_cap, clock, vault_id, pyth_id, bs_id, tick_size: tick }
}

/// `setup_market` with the default tick size.
public fun setup_market_default(): Fixture {
    setup_market(test_constants::default_tick_size())
}

/// Back-compat alias for the default bring-up.
public fun setup_pool_with_pyth(): Fixture { setup_market_default() }

/// One-shot composite bring-up over `(expiry_ms, live_price)`: a default market
/// already past `create_expiry` + `prepare_live_oracle` + test-only cash seeding,
/// plus a funded alice manager, so a flow test starts at the first interesting
/// line. The market objects are returned to the shared pool; the caller
/// `take_market`s them. Returns `(fixture, expiry_id, manager)`.
public fun setup_live_market(expiry_ms: u64, live_price: u64): (Fixture, ID, PredictManager) {
    setup_funded_live_market(expiry_ms, live_price, test_constants::mint_deposit())
}

/// `setup_live_market` at the far default expiry / live price with the large
/// default manager deposit (used by the smoke + gate tests).
public fun setup_everything(): (Fixture, ID, PredictManager) {
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
): (Fixture, ID, PredictManager) {
    let mut fx = setup_market_default();
    let expiry_id = fx.create_expiry(expiry_ms);
    let manager = fx.create_funded_manager(deposit);
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, live_price);
    fx.seed_market_cash(&mut market, test_constants::default_seeded_expiry_cash());
    return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.scenario.next_tx(test_constants::admin());
    (fx, expiry_id, manager)
}

/// Create the market for `expiry` through the production path, returning its id.
public fun create_expiry(self: &mut Fixture, expiry: u64): ID {
    self.scenario.next_tx(test_constants::admin());
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut registry = self.scenario.take_shared<Registry>();
    let oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let config = self.scenario.take_shared<ProtocolConfig>();
    let expiry_id = registry::create_expiry_market(
        &mut registry,
        &mut vault,
        &config,
        &oracle_registry,
        &self.lifecycle_cap,
        test_constants::propbook_underlying_id(),
        expiry,
        self.tick_size,
        &self.clock,
        self.scenario.ctx(),
    );
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(registry);
    return_shared(vault);
    self.scenario.next_tx(test_constants::admin());
    expiry_id
}

public fun set_trade_liquidation_budget(self: &Fixture, config: &mut ProtocolConfig, budget: u64) {
    config.set_trade_liquidation_budget(&self.admin_cap, budget);
}

/// Pause / unpause global trading through the real admin path.
public fun set_trading_paused(self: &Fixture, config: &mut ProtocolConfig, paused: bool) {
    config.set_trading_paused(&self.admin_cap, paused);
}

/// Pause / unpause minting for one expiry market through the real admin path.
public fun set_expiry_mint_paused(self: &Fixture, market: &mut ExpiryMarket, paused: bool) {
    market.set_mint_paused(&self.admin_cap, paused);
}

public fun set_template_zero_min_fee(self: &mut Fixture) {
    self.scenario.next_tx(test_constants::admin());
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    config.set_template_min_fee(&self.admin_cap, 0);
    return_shared(config);
    self.scenario.next_tx(test_constants::admin());
}

public fun set_template_backing_buffer_lambda(self: &mut Fixture, value: u64) {
    self.scenario.next_tx(test_constants::admin());
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    config.set_template_backing_buffer_lambda(&self.admin_cap, value);
    return_shared(config);
    self.scenario.next_tx(test_constants::admin());
}

/// Take the four shared market objects + the protocol config a flow test mutates.
/// The config is threaded into the flow-phase methods as a parameter (it cannot be
/// a `Fixture` field — see module doc) and returned by the test.
public fun take_market(
    self: &mut Fixture,
    expiry_id: ID,
): (PythFeed, BlockScholesFeed, OracleRegistry, PoolVault, ExpiryMarket, ProtocolConfig) {
    (
        self.scenario.take_shared_by_id<PythFeed>(self.pyth_id),
        self.scenario.take_shared_by_id<BlockScholesFeed>(self.bs_id),
        self.scenario.take_shared<OracleRegistry>(),
        self.scenario.take_shared_by_id<PoolVault>(self.vault_id),
        self.scenario.take_shared_by_id<ExpiryMarket>(expiry_id),
        self.scenario.take_shared<ProtocolConfig>(),
    )
}

/// Return the five shared objects taken by `take_market` (pairs 1:1 with it).
public fun return_market(
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    vault: PoolVault,
    market: ExpiryMarket,
    config: ProtocolConfig,
) {
    return_shared(market);
    return_shared(vault);
    return_shared(bs);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
}

/// Create a fresh trader manager (owned by alice) and fund it with DUSDC. The
/// scenario sender is left as alice so the caller's next mint/redeem generates a
/// valid owner proof.
public fun create_funded_manager(self: &mut Fixture, deposit: u64): PredictManager {
    self.create_funded_manager_as(test_constants::alice(), deposit)
}

/// `create_funded_manager` for an arbitrary owner, for multi-trader flows.
public fun create_funded_manager_as(
    self: &mut Fixture,
    owner: address,
    deposit: u64,
): PredictManager {
    self.scenario.next_tx(owner);
    let mut registry = self.scenario.take_shared<Registry>();
    let mut manager = registry::create_manager(&mut registry, self.scenario.ctx());
    return_shared(registry);
    manager.deposit(
        coin::mint_for_testing<DUSDC>(deposit, self.scenario.ctx()),
        self.scenario.ctx(),
    );
    manager
}

public fun seed_market_cash(self: &mut Fixture, market: &mut ExpiryMarket, amount: u64) {
    market.receive_cash_for_testing(coin::mint_for_testing<DUSDC>(amount, self.scenario.ctx()));
}

/// Seed a fresh live Pyth spot + Block Scholes surface for `market`'s expiry so
/// quotes are available. `live_price` is used as spot and forward (basis = 1.0).
public fun prepare_live_oracle(
    self: &mut Fixture,
    market: &ExpiryMarket,
    pyth: &mut PythFeed,
    bs: &mut BlockScholesFeed,
    live_price: u64,
) {
    self.prepare_live_oracle_at(
        market,
        pyth,
        bs,
        live_price,
        test_constants::live_source_timestamp_ms(),
    );
}

/// `prepare_live_oracle` at an explicit source timestamp (for staleness tests).
public fun prepare_live_oracle_at(
    self: &mut Fixture,
    market: &ExpiryMarket,
    pyth: &mut PythFeed,
    bs: &mut BlockScholesFeed,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    // The Pyth feed and BS surface both reject non-advancing source timestamps, so a
    // re-seed (a second market sharing this Pyth feed, or a price change for one
    // market) must use a strictly-newer timestamp. Bump past the current Pyth row
    // when the requested timestamp would not advance; the freshness window is wide
    // enough to absorb the handful of re-seeds a test performs.
    let latest = pyth.normalized_spot();
    let ts = if (latest.is_some()) {
        source_timestamp_ms.max(latest.borrow().read_source_timestamp_ms() + 1)
    } else {
        source_timestamp_ms
    };
    store_pyth_spot(pyth, live_price, ts, ts);
    self.seed_bs_surface(market, bs, live_price, live_price, ts);
}

/// Overwrite the Pyth spot directly (for staleness / pricing-source tests), keeping
/// the fixture clock as the on-chain landing timestamp.
public fun set_pyth_price_for_testing(
    self: &Fixture,
    pyth: &mut PythFeed,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    store_pyth_spot(pyth, live_price, source_timestamp_ms, self.clock.timestamp_ms());
}

/// Write a Block Scholes surface row for `market`'s expiry through the real ingest
/// path (`spot`/`forward` give the basis; default SVI), at `source_timestamp_ms`.
public fun seed_bs_surface(
    self: &mut Fixture,
    market: &ExpiryMarket,
    bs: &mut BlockScholesFeed,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
) {
    let bs_update = update::new_update(
        test_constants::pyth_feed_id(),
        market.expiry(),
        source_timestamp_ms,
        spot,
        forward,
        test_constants::default_svi_a(),
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    bs.update(bs_update, &self.clock, self.scenario.ctx());
}

/// Mint one order for `manager` over the tick range `(lower_tick, higher_tick]` and
/// return its packed order id.
public fun mint(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
): u256 {
    let proof = manager.generate_proof_as_owner(self.scenario.ctx());
    let order_id = market.mint(
        manager,
        &proof,
        config,
        oracle_registry,
        pyth,
        bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        &self.clock,
        self.scenario.ctx(),
    );
    order_id
}

/// Close (or partially close) a live order. Returns `(closed_id, replacement_id)`.
public fun redeem(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let proof = manager.generate_proof_as_owner(self.scenario.ctx());
    let (closed_id, replacement_id) = market.redeem(
        manager,
        proof,
        config,
        oracle_registry,
        pyth,
        bs,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    );
    (closed_id, replacement_id)
}

/// Permissionless redeem (no proof): clears an already-liquidated order or a
/// passively settled order.
public fun redeem_settled(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let (closed_id, replacement_id) = market.redeem_settled(
        manager,
        config,
        oracle_registry,
        pyth,
        bs,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    );
    (closed_id, replacement_id)
}

/// Run the passive settlement gate against the fixture clock and return whether the
/// market is settled after the attempt.
public fun ensure_settled(
    self: &Fixture,
    market: &mut ExpiryMarket,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
): bool {
    market.ensure_settled(oracle_registry, pyth, &self.clock)
}

/// Run a budgeted liquidation pass over the market's active leveraged orders.
/// Returns the number of orders liquidated.
public fun liquidate(
    self: &Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    budget: u64,
): u64 {
    market.liquidate(config, oracle_registry, pyth, bs, budget, &self.clock)
}

/// Try to liquidate one active leveraged order by ID. Returns whether it was
/// liquidated.
public fun liquidate_order(
    self: &Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
): bool {
    market.liquidate_order(config, oracle_registry, pyth, bs, order_id, &self.clock)
}

public fun value_expiry(
    self: &Fixture,
    valuation: &mut PoolValuation,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
) {
    valuation.value_expiry(vault, market, config, oracle_registry, pyth, bs, &self.clock);
}

public fun rebalance_expiry_cash(
    self: &Fixture,
    vault: &mut PoolVault,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
) {
    vault.rebalance_expiry_cash(market, config, oracle_registry, pyth, &self.clock);
}

public fun current_nav(
    self: &Fixture,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): u64 {
    market.current_nav(config, oracle_registry, pyth, bs, &self.clock)
}

public fun load_pricer(
    self: &Fixture,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): pricing::Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        oracle_registry,
        market.propbook_underlying_id(),
        pyth,
        bs,
        market.expiry(),
        &self.clock,
    )
}

/// Start a privileged pool-NAV flush as the operator `AdminCap`. The returned hot
/// potato is threaded through `plp::value_expiry` × N then `plp::finish_flush`.
public fun start_flush(
    self: &Fixture,
    config: &mut ProtocolConfig,
    vault: &PoolVault,
): PoolValuation {
    plp::start_pool_valuation(config, vault, &self.admin_cap)
}

/// Start a privileged pool-NAV flush as a market deployer (`MarketLifecycleCap`).
public fun start_flush_as_deployer(
    self: &Fixture,
    registry: &Registry,
    config: &mut ProtocolConfig,
    vault: &PoolVault,
): PoolValuation {
    let proof = registry.generate_lifecycle_proof(&self.lifecycle_cap);
    plp::start_pool_valuation_as_deployer(config, vault, proof)
}

// === Invariant assertions (rule 17 one-call checks) ===

/// S1 — expiry cash backing: the market's DUSDC custody covers its payout
/// liability plus the unresolved rebate reserve. Assert after every cash-mutating
/// flow (mint / redeem / liquidate / sync / rebate).
public fun assert_market_backed(market: &ExpiryMarket) {
    assert!(market.cash_balance() >= market.payout_liability() + market.rebate_reserve());
}

/// Expected snapshot of one expiry market's cash-side accounting, asserted in one
/// call by `check_market_cash`.
public struct ExpectedMarketCash has copy, drop {
    /// DUSDC held by the expiry (`market.cash_balance()`).
    cash_balance: u64,
    /// Conservative payout backing owed to open + settled orders.
    payout_liability: u64,
    /// Cash reserved for unresolved trading-loss rebates.
    rebate_reserve: u64,
}

public fun expected_market_cash(
    cash_balance: u64,
    payout_liability: u64,
    rebate_reserve: u64,
): ExpectedMarketCash {
    ExpectedMarketCash { cash_balance, payout_liability, rebate_reserve }
}

/// Assert an expiry market's full cash sheet. Each field is an exact `assert_eq!`,
/// and the S1 backing inequality is checked on top.
public fun check_market_cash(market: &ExpiryMarket, expected: ExpectedMarketCash) {
    assert_eq!(market.cash_balance(), expected.cash_balance);
    assert_eq!(market.payout_liability(), expected.payout_liability);
    assert_eq!(market.rebate_reserve(), expected.rebate_reserve);
    assert_market_backed(market);
}

// === Manager state-sheet assertions ===

/// A full expected snapshot of one manager's scalar state plus its per-expiry
/// trading state, asserted in one call by `check_manager`.
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

/// Assert a manager's full state sheet against `expected` for `expiry_id`.
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

public fun insert_exact_settlement_spot(
    self: &Fixture,
    pyth: &mut PythFeed,
    expiry_ms: u64,
    spot: u64,
) {
    pyth_feed::record_raw_for_testing(
        pyth,
        spot,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        expiry_ms * 1000,
        self.clock.timestamp_ms(),
        true,
    );
}

public fun vault_id(self: &Fixture): ID { self.vault_id }

public fun pyth_id(self: &Fixture): ID { self.pyth_id }

public fun bs_id(self: &Fixture): ID { self.bs_id }

/// Tear down the fixture and all owned objects. The shared Registry/ProtocolConfig/
/// OracleRegistry are returned by the flow test and reclaimed by `end`.
public fun finish(self: Fixture) {
    let Fixture {
        scenario,
        admin_cap,
        lifecycle_cap,
        clock,
        vault_id: _,
        pyth_id: _,
        bs_id: _,
        tick_size: _,
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
