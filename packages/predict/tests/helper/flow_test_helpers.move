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
/// returns it before the next transaction. The market reads standalone propbook
/// feeds — `PythFeed`, BS spot, BS forward, and BS SVI. The Pyth spot is seeded
/// through `pyth_feed::record_raw_for_testing` because a real `pyth_lazer::Update`
/// has no public Move constructor; the BS feeds use the stub verifier's split
/// public update constructors. Exact settlement spots are inserted through the same
/// Pyth testing seam; production settlement is passive inside the normal redeem and
/// pool-rebalance flows.
#[test_only]
module deepbook_predict::flow_test_helpers;

use account::{
    account::{Self, AccountWrapper},
    account_registry::{Self, AccountRegistry, AccountAdminCap}
};
use block_scholes_oracle::update;
use deepbook_predict::{
    accumulator_support,
    admin::AdminCap,
    block_scholes_feed::{Self as bs_feed, BlockScholesFeed},
    constants,
    expiry_market::ExpiryMarket,
    market_lifecycle_cap::MarketLifecycleCap,
    market_manager,
    plp::{Self, PoolVault, PoolValuation},
    predict_account::{Self, PredictApp},
    pricing,
    protocol_config::ProtocolConfig,
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::{Self, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    accumulator::AccumulatorRoot,
    clock::{Self, Clock},
    coin,
    test_scenario::{Self as test, Scenario, return_shared}
};

const PYTH_EXPONENT_NEG_9: u16 = 9;

/// A representative finite strike tick the flow tests mint against. Re-exported
/// from `test_constants` so existing call sites keep one source of truth.
public fun strike_tick(): u64 { test_constants::default_strike_tick() }

/// Scenario-local objects shared across one flow test. `Registry`/`ProtocolConfig`/
/// `OracleRegistry`/`AccountRegistry` are real shared objects taken per-transaction,
/// not held here. `AccumulatorRoot` follows the same pattern: setup creates one
/// shared empty root, and root-dependent tests take/return it per transaction.
public struct Fixture {
    scenario: Scenario,
    admin_cap: AdminCap,
    propbook_admin_cap: RegistryAdminCap,
    lifecycle_cap: MarketLifecycleCap,
    clock: Clock,
    vault_id: ID,
    pyth_id: ID,
    bs_spot_id: ID,
    bs_forward_id: ID,
    bs_svi_id: ID,
}

/// A trader handle: the canonical `AccountWrapper` ID plus its owner. The wrapper is
/// a shared object, so a flow test holds this lightweight handle and `take_account`s
/// the wrapper for the duration of a trade transaction (it cannot survive a
/// `next_tx`, like every other shared object). Replaces the owned `PredictManager`.
public struct Trader has copy, drop, store {
    wrapper_id: ID,
    owner: address,
}

/// Transaction-local borrow of an expiry market and the shared objects normally
/// needed to exercise it. Pair with `return_market_bundle` before advancing the
/// scenario transaction.
public struct MarketBundle {
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    vault: PoolVault,
    market: ExpiryMarket,
    config: ProtocolConfig,
}

/// Transaction-local borrow of a trader account plus the accumulator root used
/// for balance reads and trade settlement.
public struct AccountBundle {
    wrapper: AccountWrapper,
    root: AccumulatorRoot,
}

/// Stand up a registry + protocol config + an empty PLP vault + the permanent
/// Pyth, BS spot, BS forward, and BS SVI feeds for the default cadence's `tick`
/// size. base_fee is floored to 1 and min_ask to 0 so small test quantities are
/// admissible. Creation reads no spot (strikes are absolute ticks), so no spot is
/// seeded here — `prepare_live_oracle` seeds the live spot + surface for pricing.
public fun setup_market(tick: u64): Fixture {
    let mut scenario = test::begin(test_constants::admin());
    // The framework root constructor is a system-only test seam.
    scenario.next_tx(@0x0);
    accumulator_support::create_shared_root(&mut scenario);
    scenario.next_tx(test_constants::admin());
    account_registry::init_for_testing(scenario.ctx());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());

    // tx1: configure protocol params, register the underlying, create feeds.
    scenario.next_tx(test_constants::admin());
    // Whitelist PredictApp on the account registry so permissionless settled-redeem can
    // generate app auth (`predict_account::generate_auth_as_app`).
    let account_admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut account_registry = scenario.take_shared<AccountRegistry>();
    account_registry.authorize_app<PredictApp>(&account_admin_cap);
    return_shared(account_registry);
    destroy(account_admin_cap);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    config.set_template_base_fee(&admin_cap, 1);
    config.set_template_min_entry_probability(&admin_cap, 0);
    let mut registry = scenario.take_shared<Registry>();
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

    // tx2: bind all pricing feeds to the canonical underlying, mint the lifecycle cap,
    // and capture the vault id.
    scenario.next_tx(test_constants::admin());
    let propbook_admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    let bs_spot = scenario.take_shared_by_id<BlockScholesSpotFeed>(bs_spot_id);
    let bs_forward = scenario.take_shared_by_id<BlockScholesForwardFeed>(bs_forward_id);
    let bs_svi = scenario.take_shared_by_id<BlockScholesSVIFeed>(bs_svi_id);
    propbook_registry::bind_pyth_to_underlying(
        &mut oracle_registry,
        &propbook_admin_cap,
        &pyth,
        test_constants::propbook_underlying_id(),
    );
    propbook_registry::bind_block_scholes_spot_to_underlying(
        &mut oracle_registry,
        &propbook_admin_cap,
        &bs_spot,
        test_constants::propbook_underlying_id(),
    );
    propbook_registry::bind_block_scholes_surface_to_underlying(
        &mut oracle_registry,
        &propbook_admin_cap,
        &bs_forward,
        &bs_svi,
        test_constants::propbook_underlying_id(),
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    let mut registry = scenario.take_shared<Registry>();
    let config = scenario.take_shared<ProtocolConfig>();
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        scenario.ctx(),
    );
    return_shared(config);
    return_shared(registry);
    let vault = scenario.take_shared<PoolVault>();
    let vault_id = vault.id();
    return_shared(vault);

    scenario.next_tx(test_constants::admin());

    Fixture {
        scenario,
        admin_cap,
        propbook_admin_cap,
        lifecycle_cap,
        clock,
        vault_id,
        pyth_id,
        bs_spot_id,
        bs_forward_id,
        bs_svi_id,
    }
}

/// `setup_market` with the default tick size.
public fun setup_market_default(): Fixture {
    setup_market(test_constants::default_tick_size())
}

/// One-shot composite bring-up over `(expiry_ms, live_price)`: a default market
/// already past `create_expiry` + `prepare_live_oracle` + test-only cash seeding,
/// plus a funded alice trader, so a flow test starts at the first interesting
/// line. The market objects are returned to the shared pool; the caller
/// takes them with `take_market_bundle`. Returns `(fixture, expiry_id, trader)`.
public fun setup_live_market(expiry_ms: u64, live_price: u64): (Fixture, ID, Trader) {
    setup_funded_live_market(expiry_ms, live_price, test_constants::mint_deposit())
}

/// `setup_live_market` at the far default expiry / live price with the large
/// default trader deposit (used by the smoke + gate tests).
public fun setup_everything(): (Fixture, ID, Trader) {
    setup_funded_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
        test_constants::default_manager_deposit(),
    )
}

fun setup_funded_live_market(expiry_ms: u64, live_price: u64, deposit: u64): (Fixture, ID, Trader) {
    let mut fx = setup_market_default();
    let expiry_id = fx.create_expiry(expiry_ms);
    let trader = fx.create_funded_manager(deposit);
    let mut market = fx.take_market_bundle(expiry_id);
    fx.prepare_live_oracle_bundle(&mut market, live_price);
    fx.seed_market_cash(&mut market.market, test_constants::default_seeded_expiry_cash());
    return_market_bundle(market);
    fx.scenario.next_tx(test_constants::admin());
    (fx, expiry_id, trader)
}

/// Create the market for `expiry` through the production path, returning its id.
public fun create_expiry(self: &mut Fixture, expiry: u64): ID {
    self.scenario.next_tx(test_constants::admin());
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut registry = self.scenario.take_shared<Registry>();
    let oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let config = self.scenario.take_shared<ProtocolConfig>();
    let mut creation_clock = clock::create_for_testing(self.scenario.ctx());
    creation_clock.set_for_testing(expiry - test_constants::default_cadence_period_ms());
    let expiry_id = registry.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &self.lifecycle_cap,
        test_constants::propbook_underlying_id(),
        test_constants::default_cadence_id(),
        &creation_clock,
        self.scenario.ctx(),
    );
    creation_clock.destroy_for_testing();
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(registry);
    return_shared(vault);
    self.scenario.next_tx(test_constants::admin());
    expiry_id
}

public fun create_next_expiry_for_cadence(self: &mut Fixture, cadence_id: u8): ID {
    self.scenario.next_tx(test_constants::admin());
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let mut registry = self.scenario.take_shared<Registry>();
    let oracle_registry = self.scenario.take_shared<OracleRegistry>();
    let config = self.scenario.take_shared<ProtocolConfig>();
    let expiry_id = registry.create_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &self.lifecycle_cap,
        test_constants::propbook_underlying_id(),
        cadence_id,
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

/// Pause / unpause global trading through a market bundle.
public fun set_trading_paused_bundle(self: &Fixture, market: &mut MarketBundle, paused: bool) {
    self.set_trading_paused(&mut market.config, paused);
}

/// Pause / unpause minting for one expiry market through the real admin path.
public fun set_expiry_mint_paused(
    self: &Fixture,
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    paused: bool,
) {
    market.set_mint_paused(config, &self.admin_cap, paused);
}

/// Pause / unpause minting for one expiry market through a market bundle.
public fun set_expiry_mint_paused_bundle(self: &Fixture, market: &mut MarketBundle, paused: bool) {
    self.set_expiry_mint_paused(&mut market.market, &market.config, paused);
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

public fun set_template_max_admission_leverage(self: &mut Fixture, value: u64) {
    self.scenario.next_tx(test_constants::admin());
    let mut config = self.scenario.take_shared<ProtocolConfig>();
    config.set_template_max_admission_leverage(&self.admin_cap, value);
    return_shared(config);
    self.scenario.next_tx(test_constants::admin());
}

/// Sponsor fee incentives for a market bundle with freshly-minted DUSDC.
public fun sponsor_fee_incentives_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    amount: u64,
) {
    let payment = coin::mint_for_testing<DUSDC>(amount, self.scenario.ctx());
    market.vault.sponsor_fee_incentives(&market.config, payment, self.scenario.ctx());
}

/// Take the market transaction objects as a named bundle to avoid wide positional
/// tuple plumbing in flow tests.
public fun take_market_bundle(self: &mut Fixture, expiry_id: ID): MarketBundle {
    MarketBundle {
        pyth: self.scenario.take_shared_by_id<PythFeed>(self.pyth_id),
        bs: self.take_bs(),
        oracle_registry: self.scenario.take_shared<OracleRegistry>(),
        vault: self.scenario.take_shared_by_id<PoolVault>(self.vault_id),
        market: self.scenario.take_shared_by_id<ExpiryMarket>(expiry_id),
        config: self.scenario.take_shared<ProtocolConfig>(),
    }
}

/// Return the shared objects taken by `take_market_bundle`.
public fun return_market_bundle(bundle: MarketBundle) {
    let MarketBundle { pyth, bs, oracle_registry, vault, market, config } = bundle;
    return_shared(market);
    return_shared(vault);
    return_bs(bs);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
}

/// Take the split Block Scholes feeds as one transaction-local bundle.
public fun take_bs(self: &Fixture): BlockScholesFeed {
    bs_feed::new(
        self.scenario.take_shared_by_id<BlockScholesSpotFeed>(self.bs_spot_id),
        self.scenario.take_shared_by_id<BlockScholesForwardFeed>(self.bs_forward_id),
        self.scenario.take_shared_by_id<BlockScholesSVIFeed>(self.bs_svi_id),
    )
}

/// Return a `take_bs` / `take_market` Block Scholes bundle.
public fun return_bs(bs: BlockScholesFeed) {
    bs.return_feed();
}

/// Bundle explicitly-created split Block Scholes feeds for wrong-feed tests.
public fun block_scholes_feed_for_testing(
    spot: BlockScholesSpotFeed,
    forward: BlockScholesForwardFeed,
    svi: BlockScholesSVIFeed,
): BlockScholesFeed {
    bs_feed::new(spot, forward, svi)
}

/// Create a fresh account (owned by alice) and fund its DUSDC stored balance. The
/// scenario sender is left as alice so the caller's next mint/redeem generates a
/// valid owner auth.
public fun create_funded_manager(self: &mut Fixture, deposit: u64): Trader {
    self.create_funded_manager_as(test_constants::alice(), deposit)
}

/// `create_funded_manager` for an arbitrary owner, for multi-trader flows. Creates the
/// owner's canonical account through the account registry, shares the wrapper, and
/// deposits `deposit` DUSDC into the account's stored balance.
public fun create_funded_manager_as(self: &mut Fixture, owner: address, deposit: u64): Trader {
    self.scenario.next_tx(owner);
    let mut account_registry = self.scenario.take_shared<AccountRegistry>();
    let wrapper_id = account_registry.derived_wrapper_address(owner).to_id();
    let mut wrapper = account_registry.new(self.scenario.ctx());
    return_shared(account_registry);
    let auth = account::generate_auth(self.scenario.ctx());
    let acct = wrapper.load_account_mut(auth);
    // Pure stored-balance deposit (no accumulator settle), so test funding needs no
    // `AccumulatorRoot` — the barrier-delivered settle path is exercised by the localnet sim.
    acct.deposit<DUSDC>(coin::mint_for_testing<DUSDC>(deposit, self.scenario.ctx()));
    wrapper.share();
    // Commit the shared returns (test_scenario defers them to a tx boundary) before the
    // caller's bundle takes. Sender stays `owner`, so a subsequent
    // owner auth is still valid.
    self.scenario.next_tx(owner);
    Trader { wrapper_id, owner }
}

/// Take a trader's wrapper and the accumulator root as one transaction-local
/// account bundle.
public fun take_account_bundle(self: &Fixture, trader: &Trader): AccountBundle {
    AccountBundle {
        wrapper: self.scenario.take_shared_by_id<AccountWrapper>(trader.wrapper_id),
        root: accumulator_support::take_root(&self.scenario),
    }
}

/// Return the shared objects taken by `take_account_bundle`.
public fun return_account_bundle(bundle: AccountBundle) {
    let AccountBundle { wrapper, root } = bundle;
    return_shared(wrapper);
    return_shared(root);
}

/// The trader's account owner address.
public fun owner(trader: &Trader): address { trader.owner }

/// Whether the trader's account holds an open position for `order_id` in `expiry_id`.
public fun has_position(wrapper: &AccountWrapper, expiry_id: ID, order_id: u256): bool {
    predict_account::has_position(wrapper.load_account(), expiry_id, order_id)
}

/// The account's free balance of `T` (stored + unsettled accumulator funds; the latter
/// is zero with the empty test root, so this equals stored balance).
public fun account_balance<T>(
    self: &Fixture,
    wrapper: &AccountWrapper,
    root: &AccumulatorRoot,
): u64 {
    wrapper.load_account().balance<T>(root, &self.clock)
}

/// Open position count for the trader's account in `expiry_id`.
public fun position_count(wrapper: &AccountWrapper, expiry_id: ID): u64 {
    predict_account::expiry_position_count(wrapper.load_account(), expiry_id)
}

/// Open position count for a bundled account in `expiry_id`.
public fun position_count_bundle(account: &AccountBundle, expiry_id: ID): u64 {
    position_count(&account.wrapper, expiry_id)
}

/// Cumulative trading fees the trader's account paid into `expiry_id`.
public fun fees_paid(wrapper: &AccountWrapper, expiry_id: ID): u64 {
    predict_account::trading_fees_paid(wrapper.load_account(), expiry_id)
}

/// Cumulative trading fees paid by a bundled account into `expiry_id`.
public fun fees_paid_bundle(account: &AccountBundle, expiry_id: ID): u64 {
    fees_paid(&account.wrapper, expiry_id)
}

/// Active (this-epoch-effective) DEEP stake on the trader's account.
public fun active_stake(wrapper: &AccountWrapper): u64 {
    predict_account::active_stake(wrapper.load_account())
}

/// Inactive (next-epoch) DEEP stake on the trader's account.
public fun inactive_stake(wrapper: &AccountWrapper): u64 {
    predict_account::inactive_stake(wrapper.load_account())
}

public fun seed_market_cash(self: &mut Fixture, market: &mut ExpiryMarket, amount: u64) {
    market.receive_pool_cash(coin::mint_for_testing<DUSDC>(
        amount,
        self.scenario.ctx(),
    ).into_balance());
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

/// Seed a fresh live oracle for a market bundle.
public fun prepare_live_oracle_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    live_price: u64,
) {
    self.prepare_live_oracle(
        &market.market,
        &mut market.pyth,
        &mut market.bs,
        live_price,
    );
}

/// Seed a fresh live oracle for a market bundle at an explicit source timestamp.
public fun prepare_live_oracle_bundle_at(
    self: &mut Fixture,
    market: &mut MarketBundle,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    self.prepare_live_oracle_at(
        &market.market,
        &mut market.pyth,
        &mut market.bs,
        live_price,
        source_timestamp_ms,
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

/// Overwrite a market bundle's Pyth spot directly.
public fun set_pyth_price_for_testing_bundle(
    self: &Fixture,
    market: &mut MarketBundle,
    live_price: u64,
    source_timestamp_ms: u64,
) {
    self.set_pyth_price_for_testing(&mut market.pyth, live_price, source_timestamp_ms);
}

/// Write split Block Scholes spot, forward, and SVI rows for `market`'s expiry
/// through the real ingest path (`spot`/`forward` give the basis; default SVI),
/// at `source_timestamp_ms`.
public fun seed_bs_surface(
    self: &mut Fixture,
    market: &ExpiryMarket,
    bs: &mut BlockScholesFeed,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
) {
    bs
        .spot_mut()
        .update(
            update::new_spot_update(test_constants::pyth_feed_id(), source_timestamp_ms, spot),
            &self.clock,
        );
    bs
        .forward_mut()
        .update(
            update::new_forward_update(
                test_constants::pyth_feed_id(),
                market.expiry(),
                source_timestamp_ms,
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
                market.expiry(),
                source_timestamp_ms,
                test_constants::default_svi_a(),
                test_constants::default_svi_b(),
                test_constants::default_svi_sigma(),
                test_constants::default_svi_rho_magnitude(),
                false,
                test_constants::default_svi_m(),
                false,
            ),
            &self.clock,
            self.scenario.ctx(),
        );
}

/// Mint one order for `wrapper`'s account over the tick range `(lower_tick,
/// higher_tick]` and return its packed order id. Owner auth comes from the current
/// scenario sender, so the caller must `next_tx(trader.owner)` first.
public fun mint(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    wrapper: &mut AccountWrapper,
    root: &AccumulatorRoot,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
): u256 {
    self.mint_exact_quantity(
        config,
        oracle_registry,
        wrapper,
        root,
        market,
        pyth,
        bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        std::u64::max_value!(),
        std::u64::max_value!(),
    )
}

/// Mint one order through a market/account bundle while still using the production
/// mint path.
public fun mint_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
): u256 {
    self.mint(
        &market.config,
        &market.oracle_registry,
        &mut account.wrapper,
        &account.root,
        &mut market.market,
        &market.pyth,
        &market.bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
    )
}

/// Mint one order through a market/account bundle while substituting an explicit
/// Block Scholes feed for binding-guard tests.
public fun mint_bundle_with_bs(
    self: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
): u256 {
    self.mint(
        &market.config,
        &market.oracle_registry,
        &mut account.wrapper,
        &account.root,
        &mut market.market,
        &market.pyth,
        bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
    )
}

/// Mint one exact-quantity order with explicit total-cost and probability caps.
public fun mint_exact_quantity(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    wrapper: &mut AccountWrapper,
    root: &AccumulatorRoot,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    max_cost: u64,
    max_probability: u64,
): u256 {
    let auth = account::generate_auth(self.scenario.ctx());
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.mint_exact_quantity(
        wrapper,
        auth,
        config,
        &pricer,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        max_cost,
        max_probability,
        root,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Mint the largest lot-rounded order that fits inside a fixed net premium amount.
public fun mint_exact_amount(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    wrapper: &mut AccountWrapper,
    root: &AccumulatorRoot,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    amount: u64,
    min_quantity: u64,
    leverage: u64,
): u256 {
    let auth = account::generate_auth(self.scenario.ctx());
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.mint_exact_amount(
        wrapper,
        auth,
        config,
        &pricer,
        lower_tick,
        higher_tick,
        amount,
        min_quantity,
        leverage,
        root,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Close (or partially close) a live order with owner auth. Returns
/// `(closed_id, replacement_id)`.
public fun redeem(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    wrapper: &mut AccountWrapper,
    root: &AccumulatorRoot,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let auth = account::generate_auth(self.scenario.ctx());
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.redeem_live(
        wrapper,
        auth,
        config,
        &pricer,
        order_id,
        close_quantity,
        root,
        &self.clock,
        self.scenario.ctx(),
    )
}

/// Close a live order through a market/account bundle while substituting an
/// explicit Pyth feed for binding-guard tests.
public fun redeem_bundle_with_pyth(
    self: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    pyth: &PythFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    self.redeem(
        &market.config,
        &market.oracle_registry,
        &mut account.wrapper,
        &account.root,
        &mut market.market,
        pyth,
        &market.bs,
        order_id,
        close_quantity,
    )
}

/// Close a live order through a market/account bundle.
public fun redeem_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    self.redeem(
        &market.config,
        &market.oracle_registry,
        &mut account.wrapper,
        &account.root,
        &mut market.market,
        &market.pyth,
        &market.bs,
        order_id,
        close_quantity,
    )
}

/// Permissionless settled redeem (no owner auth): clears a settled order using app
/// auth generated through the whitelisted `PredictApp`. Does not price, so takes no
/// Block Scholes feed.
public fun redeem_settled(
    self: &mut Fixture,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    wrapper: &mut AccountWrapper,
    root: &AccumulatorRoot,
    market: &mut ExpiryMarket,
    pyth: &PythFeed,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    let account_registry = self.scenario.take_shared<AccountRegistry>();
    let (closed_id, replacement_id) = market.redeem_settled(
        &account_registry,
        wrapper,
        config,
        oracle_registry,
        pyth,
        order_id,
        close_quantity,
        root,
        &self.clock,
        self.scenario.ctx(),
    );
    return_shared(account_registry);
    (closed_id, replacement_id)
}

/// Permissionless settled redeem through a market/account bundle.
public fun redeem_settled_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    account: &mut AccountBundle,
    order_id: u256,
    close_quantity: u64,
): (u256, Option<u256>) {
    self.redeem_settled(
        &market.config,
        &market.oracle_registry,
        &mut account.wrapper,
        &account.root,
        &mut market.market,
        &market.pyth,
        order_id,
        close_quantity,
    )
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

/// Run the passive settlement gate through a market bundle.
public fun ensure_settled_bundle(self: &Fixture, market: &mut MarketBundle): bool {
    self.ensure_settled(&mut market.market, &market.oracle_registry, &market.pyth)
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
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.liquidate(config, &pricer, budget)
}

/// Run a budgeted liquidation pass through a market bundle.
public fun liquidate_bundle(self: &Fixture, market: &mut MarketBundle, budget: u64): u64 {
    self.liquidate(
        &market.config,
        &market.oracle_registry,
        &mut market.market,
        &market.pyth,
        &market.bs,
        budget,
    )
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
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.liquidate_order(
        config,
        &pricer,
        order_id,
    )
}

/// Try to liquidate one bundled active leveraged order by ID.
public fun liquidate_order_bundle(self: &Fixture, market: &mut MarketBundle, order_id: u256): bool {
    self.liquidate_order(
        &market.config,
        &market.oracle_registry,
        &mut market.market,
        &market.pyth,
        &market.bs,
        order_id,
    )
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
    valuation.value_expiry(
        vault,
        market,
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
}

/// Value one expiry through a market bundle.
public fun value_expiry_bundle(
    self: &Fixture,
    valuation: &mut PoolValuation,
    market: &mut MarketBundle,
) {
    self.value_expiry(
        valuation,
        &mut market.vault,
        &mut market.market,
        &market.config,
        &market.oracle_registry,
        &market.pyth,
        &market.bs,
    );
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

/// Rebalance expiry cash through a market bundle.
public fun rebalance_expiry_cash_bundle(self: &Fixture, market: &mut MarketBundle) {
    self.rebalance_expiry_cash(
        &mut market.vault,
        &mut market.market,
        &market.config,
        &market.oracle_registry,
        &market.pyth,
    );
}

/// Rebalance expiry cash through a market bundle while substituting an explicit
/// Pyth feed for binding-guard tests.
public fun rebalance_expiry_cash_bundle_with_pyth(
    self: &Fixture,
    market: &mut MarketBundle,
    pyth: &PythFeed,
) {
    self.rebalance_expiry_cash(
        &mut market.vault,
        &mut market.market,
        &market.config,
        &market.oracle_registry,
        pyth,
    );
}

public fun current_nav(
    self: &Fixture,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): u64 {
    let pricer = market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    );
    market.current_nav(&pricer)
}

/// Read live NAV through a market bundle.
public fun current_nav_bundle(self: &Fixture, market: &MarketBundle): u64 {
    self.current_nav(
        &market.market,
        &market.config,
        &market.oracle_registry,
        &market.pyth,
        &market.bs,
    )
}

public fun load_pricer(
    self: &Fixture,
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    oracle_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
): pricing::Pricer {
    market.load_live_pricer(
        config,
        oracle_registry,
        pyth,
        bs.spot(),
        bs.forward(),
        bs.svi(),
        &self.clock,
    )
}

/// Load the live pricer through a market bundle.
public fun load_pricer_bundle(self: &Fixture, market: &MarketBundle): pricing::Pricer {
    self.load_pricer(
        &market.market,
        &market.config,
        &market.oracle_registry,
        &market.pyth,
        &market.bs,
    )
}

/// Genesis-bootstrap the pool via `plp::lock_capital`: permanently lock `amount`
/// DUSDC of minimum liquidity. Mints `amount` PLP into the book's locked balance
/// (delivered to no one) and joins the DUSDC into idle, so `total_supply == idle ==
/// amount` at a 1.0 mark — identical pool state to the old async bootstrap supply of
/// `amount`. Must run before any supply/withdraw/flush (those abort `ENotBootstrapped`
/// until the pool is locked).
public fun bootstrap_lock(self: &mut Fixture, amount: u64) {
    self.scenario.next_tx(test_constants::admin());
    let mut vault = self.scenario.take_shared_by_id<PoolVault>(self.vault_id);
    let config = self.scenario.take_shared<ProtocolConfig>();
    let coin = coin::mint_for_testing<DUSDC>(amount, self.scenario.ctx());
    vault.lock_capital(&config, &self.admin_cap, coin);
    return_shared(vault);
    return_shared(config);
}

/// Start a privileged pool-NAV flush as a market deployer (`MarketLifecycleCap`), the
/// sole flush-start authority. Acquires the shared `Registry` to mint the lifecycle
/// proof internally, so callers need not thread it. The returned hot potato is
/// threaded through `plp::value_expiry` × N then `plp::finish_flush`.
public fun start_flush(
    self: &mut Fixture,
    config: &mut ProtocolConfig,
    vault: &PoolVault,
): PoolValuation {
    let registry = self.scenario.take_shared<Registry>();
    let proof = registry.generate_lifecycle_proof(&self.lifecycle_cap);
    return_shared(registry);
    plp::start_pool_valuation(config, vault, proof)
}

/// Start a pool-NAV flush through a market bundle.
public fun start_flush_bundle(self: &mut Fixture, market: &mut MarketBundle): PoolValuation {
    self.start_flush(&mut market.config, &market.vault)
}

/// Finish a pool-NAV flush through a market bundle.
public fun finish_flush_bundle(
    self: &mut Fixture,
    valuation: PoolValuation,
    market: &mut MarketBundle,
    supply_budget: Option<u64>,
    withdraw_budget: Option<u64>,
): u64 {
    valuation.finish_flush(
        &mut market.vault,
        &mut market.config,
        supply_budget,
        withdraw_budget,
        self.scenario.ctx(),
    )
}

// === Invariant assertions (rule 17 one-call checks) ===

/// S1 — expiry cash backing: the market's DUSDC custody covers its payout
/// liability plus the unresolved rebate reserve. Assert after every cash-mutating
/// flow (mint / redeem / liquidate / sync / rebate).
public fun assert_market_backed(market: &ExpiryMarket) {
    assert!(market.cash_balance() >= market.payout_liability() + market.rebate_reserve());
}

/// S1 backing assertion for a market bundle.
public fun assert_market_backed_bundle(market: &MarketBundle) {
    assert_market_backed(&market.market);
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

/// Assert a bundled expiry market's full cash sheet.
public fun check_market_cash_bundle(market: &MarketBundle, expected: ExpectedMarketCash) {
    check_market_cash(&market.market, expected);
}

// === Account state-sheet assertions ===

/// A full expected snapshot of one account's scalar state plus its per-expiry
/// trading state, asserted in one call by `check_manager`.
public struct ExpectedManagerState has copy, drop {
    /// Free DUSDC balance (`account.balance<DUSDC>`).
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

/// Assert an account's full state sheet against `expected` for `expiry_id`. The DUSDC
/// balance read includes unsettled accumulator funds (zero with the empty test root,
/// so it equals stored free balance).
public fun check_manager(
    self: &Fixture,
    wrapper: &AccountWrapper,
    root: &AccumulatorRoot,
    expiry_id: ID,
    expected: ExpectedManagerState,
) {
    let account = wrapper.load_account();
    assert_eq!(account.balance<DUSDC>(root, &self.clock), expected.balance);
    assert_eq!(predict_account::trading_fees_paid(account, expiry_id), expected.fees_paid);
    assert_eq!(predict_account::expiry_position_count(account, expiry_id), expected.position_count);
    assert_eq!(predict_account::active_stake(account), expected.active_stake);
    assert_eq!(predict_account::inactive_stake(account), expected.inactive_stake);
}

/// Assert a bundled account's full state sheet.
public fun check_manager_bundle(
    self: &Fixture,
    account: &AccountBundle,
    expiry_id: ID,
    expected: ExpectedManagerState,
) {
    self.check_manager(&account.wrapper, &account.root, expiry_id, expected);
}

// === Accessors ===

public fun scenario_mut(self: &mut Fixture): &mut Scenario { &mut self.scenario }

public fun clock(self: &Fixture): &Clock { &self.clock }

public fun set_clock_for_testing(self: &mut Fixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

/// Borrow the expiry market inside a bundle for independent assertions.
public fun market(bundle: &MarketBundle): &ExpiryMarket { &bundle.market }

/// Mutably borrow the expiry market inside a bundle for setup-only cash seeding.
public fun market_mut(bundle: &mut MarketBundle): &mut ExpiryMarket { &mut bundle.market }

/// Borrow the pool vault inside a bundle for independent assertions.
public fun vault(bundle: &MarketBundle): &PoolVault { &bundle.vault }

/// Borrow the protocol config inside a bundle for independent snapshot assertions.
public fun config(bundle: &MarketBundle): &ProtocolConfig { &bundle.config }

/// Engage the valuation lock on a bundled protocol config.
public fun begin_valuation(bundle: &mut MarketBundle) {
    bundle.config.begin_valuation();
}

/// Account balance through an account bundle.
public fun account_balance_bundle<T>(self: &Fixture, account: &AccountBundle): u64 {
    self.account_balance<T>(&account.wrapper, &account.root)
}

/// Whether the bundled account holds an open position.
public fun has_position_bundle(account: &AccountBundle, expiry_id: ID, order_id: u256): bool {
    has_position(&account.wrapper, expiry_id, order_id)
}

/// Advance the fixture clock by one millisecond and reseed the default live oracle.
/// Use before live redeems in tests that mint and close inside one scenario tx.
public fun advance_live_oracle(
    self: &mut Fixture,
    market: &ExpiryMarket,
    pyth: &mut PythFeed,
    bs: &mut BlockScholesFeed,
    live_price: u64,
) {
    let timestamp_ms = self.clock.timestamp_ms() + 1;
    self.clock.set_for_testing(timestamp_ms);
    self.prepare_live_oracle_at(market, pyth, bs, live_price, timestamp_ms);
}

/// Advance the fixture clock by one millisecond and reseed a market bundle's live
/// oracle.
public fun advance_live_oracle_bundle(
    self: &mut Fixture,
    market: &mut MarketBundle,
    live_price: u64,
) {
    let timestamp_ms = self.clock.timestamp_ms() + 1;
    self.clock.set_for_testing(timestamp_ms);
    self.prepare_live_oracle_at(
        &market.market,
        &mut market.pyth,
        &mut market.bs,
        live_price,
        timestamp_ms,
    );
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

/// Insert an exact settlement spot for the bundled market expiry.
public fun insert_exact_settlement_spot_bundle(
    self: &Fixture,
    market: &mut MarketBundle,
    spot: u64,
) {
    self.insert_exact_settlement_spot(&mut market.pyth, market.market.expiry(), spot);
}

public fun vault_id(self: &Fixture): ID { self.vault_id }

public fun pyth_id(self: &Fixture): ID { self.pyth_id }

public fun bs_spot_id(self: &Fixture): ID { self.bs_spot_id }

/// Tear down the fixture and all owned objects. The shared Registry/ProtocolConfig/
/// OracleRegistry are returned by the flow test and reclaimed by `end`.
public fun finish(self: Fixture) {
    let Fixture {
        scenario,
        admin_cap,
        propbook_admin_cap,
        lifecycle_cap,
        clock,
        vault_id: _,
        pyth_id: _,
        bs_spot_id: _,
        bs_forward_id: _,
        bs_svi_id: _,
    } = self;
    lifecycle_cap.destroy();
    destroy(propbook_admin_cap);
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
