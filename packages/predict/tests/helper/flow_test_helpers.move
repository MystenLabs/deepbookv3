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
/// surface) — both seeded through their real ingest paths (the Pyth spot via the
/// one irreducible `store_tick_for_testing` seam, since a real `pyth_lazer::Update`
/// has no Move constructor; the BS surface via the stub verifier's public
/// `update::new_update`). Settlement is deferred to settlement-v2, so there is no
/// settle helper here.
#[test_only]
module deepbook_predict::flow_test_helpers;

use block_scholes_oracle::update;
use deepbook_predict::{
    admin::AdminCap,
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    plp::{Self, PoolVault},
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    range_codec,
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use propbook::{
    block_scholes_feed::{Self, BlockScholesFeed},
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, coin, test_scenario::{Self as test, Scenario, return_shared}};

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

    // tx1: configure protocol params, register the feed tick size, create feeds.
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_min_ask_price(&admin_cap, 0);
    return_shared(config);
    let mut registry = scenario.take_shared<Registry>();
    registry::register_pyth_feed(&mut registry, &admin_cap, test_constants::pyth_feed_id(), tick);
    return_shared(registry);
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth_id = pyth_feed::create_and_share(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    let bs_id = block_scholes_feed::create_and_share(
        &mut oracle_registry,
        test_constants::pyth_feed_id(),
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());

    // tx2: mint the lifecycle cap and capture the vault id.
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<Registry>();
    let lifecycle_cap = registry::mint_lifecycle_cap(&mut registry, &admin_cap, scenario.ctx());
    return_shared(registry);
    let vault = scenario.take_shared<PoolVault>();
    let vault_id = vault.id();
    return_shared(vault);

    scenario.next_tx(test_constants::admin());

    Fixture { scenario, admin_cap, lifecycle_cap, clock, vault_id, pyth_id, bs_id }
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
    let (mut pyth, mut bs, vault, mut market, config) = fx.take_market(expiry_id);
    fx.prepare_live_oracle(&market, &mut pyth, &mut bs, live_price);
    fx.seed_market_cash(&mut market, test_constants::default_seeded_expiry_cash());
    return_market(pyth, bs, vault, market, config);
    fx.scenario.next_tx(test_constants::admin());
    (fx, expiry_id, manager)
}

/// Create the market for `expiry` through the production path, returning its id.
public fun create_expiry(self: &mut Fixture, expiry: u64): ID {
    self.scenario.next_tx(test_constants::admin());
    let pyth = self.scenario.take_shared_by_id<PythFeed>(self.pyth_id);
    let bs = self.scenario.take_shared_by_id<BlockScholesFeed>(self.bs_id);
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut registry = self.scenario.take_shared<Registry>();
    let config = self.scenario.take_shared<ProtocolConfig>();
    let expiry_id = registry::create_expiry_market(
        &mut registry,
        &mut vault,
        &config,
        &pyth,
        &bs,
        &self.lifecycle_cap,
        expiry,
        &self.clock,
        self.scenario.ctx(),
    );
    return_shared(config);
    return_shared(registry);
    return_shared(vault);
    return_shared(bs);
    return_shared(pyth);
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
): (PythFeed, BlockScholesFeed, PoolVault, ExpiryMarket, ProtocolConfig) {
    (
        self.scenario.take_shared_by_id<PythFeed>(self.pyth_id),
        self.scenario.take_shared_by_id<BlockScholesFeed>(self.bs_id),
        self.scenario.take_shared_by_id<PoolVault>(self.vault_id),
        self.scenario.take_shared_by_id<ExpiryMarket>(expiry_id),
        self.scenario.take_shared<ProtocolConfig>(),
    )
}

/// Return the five shared objects taken by `take_market` (pairs 1:1 with it).
public fun return_market(
    pyth: PythFeed,
    bs: BlockScholesFeed,
    vault: PoolVault,
    market: ExpiryMarket,
    config: ProtocolConfig,
) {
    return_shared(market);
    return_shared(vault);
    return_shared(bs);
    return_shared(pyth);
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
    self: &Fixture,
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
    self: &Fixture,
    market: &ExpiryMarket,
    pyth: &mut PythFeed,
    bs: &mut BlockScholesFeed,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    pyth.store_tick_for_testing(live_price, source_timestamp_ms, source_timestamp_ms);
    self.seed_bs_surface(market, bs, live_price, live_price, source_timestamp_ms);
}

/// Overwrite the Pyth spot directly (for staleness / pricing-source tests), keeping
/// the fixture clock as the on-chain landing timestamp.
public fun set_pyth_price_for_testing(
    self: &Fixture,
    pyth: &mut PythFeed,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    pyth.store_tick_for_testing(live_price, source_timestamp_ms, self.clock.timestamp_ms());
}

/// Write a Block Scholes surface row for `market`'s expiry through the real ingest
/// path (`spot`/`forward` give the basis; default SVI), at `source_timestamp_ms`.
public fun seed_bs_surface(
    self: &Fixture,
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
    bs.update_from_bs(bs_update, &self.clock);
}

/// Mint one order for `manager` over the tick range `(lower_tick, higher_tick]` and
/// return its packed order id.
public fun mint(
    self: &mut Fixture,
    config: &ProtocolConfig,
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
    market.mint(
        manager,
        &proof,
        config,
        pyth,
        bs,
        range_codec::pack(lower_tick, higher_tick),
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
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let proof = manager.generate_proof_as_owner(self.scenario.ctx());
    market.redeem(
        manager,
        proof,
        config,
        pyth,
        bs,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Permissionless redeem (no proof): clears an already-liquidated order. (Settled
/// redeem returns with settlement-v2; under the stub the settled branch is dead.)
public fun redeem_settled(
    self: &mut Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    market.redeem_settled(
        manager,
        config,
        pyth,
        bs,
        order_id,
        close_quantity,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Run a budgeted liquidation pass over the market's active leveraged orders.
/// Returns the number of orders liquidated.
public fun liquidate(
    self: &Fixture,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    budget: u64,
): u64 {
    market.liquidate(config, pyth, bs, budget, &self.clock)
}

/// Try to liquidate one active leveraged order by ID. Returns whether it was
/// liquidated.
public fun liquidate_order(
    self: &Fixture,
    config: &ProtocolConfig,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
): bool {
    market.liquidate_order(config, pyth, bs, order_id, &self.clock)
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
    } = self;
    lifecycle_cap.destroy();
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}
