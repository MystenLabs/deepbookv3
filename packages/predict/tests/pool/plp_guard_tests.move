// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for `plp`'s error constants (one `expected_failure` test
/// per guard), driven through the production sync/supply/withdraw flows.
///
/// Two guards are intentionally NOT covered because they are unreachable from a
/// minimal production-valid fixture:
/// - `EInvalidInitialSupply` (bootstrap with nonzero pool value): every idle
///   inflow is either `supply` (blocked at bootstrap by this very guard) or cash
///   returned from an expiry. Reaching "value in, zero supply" needs a custom
///   multi-order flow (unmaterialized swept premium + total LP exit + a
///   protocol-share change before re-bootstrap), so the guard stays as defense.
/// - `EZeroPoolValue` (supply priced against a zero pool): with `total_supply >
///   0` and no incentives this needs `lp_pool_value` to clamp to exactly 0 (the
///   documented active-mark-collapse scenario where traders win everything LPs
///   withdrew against). The zero-clamp math itself is unit-tested in
///   `plp_tests::lp_pool_value_floors_at_zero_*`; fabricating the full collapse
///   here would not be a minimal production-valid fixture.
#[test_only]
module deepbook_predict::plp_guard_tests;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    flow_test_helpers as helpers,
    plp::{Self, PLP, PoolVault},
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    registry::{Self, Registry},
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    coin,
    coin_registry,
    sui::SUI,
    test_scenario::{Self as test, Scenario, return_shared},
    test_utils
};

/// Any valid post-expiry settlement spot (no orders exist in these tests, so
/// only "a settlement happened" matters).
const SETTLEMENT_PRICE: u64 = 110_000_000_000;
/// SUI coin decimals, as the registry would read them from `Currency<SUI>`.
const SUI_DECIMALS: u8 = 9;
/// 1_000 SUI (9 decimals): large enough that its vested DUSDC value dominates
/// the pool and a 1-unit supply payment rounds to zero shares.
const LARGE_SUI_INCENTIVE: u64 = 1_000_000_000_000;
/// One day in ms; well inside `constants::max_incentive_stream_ms!()` (1 year).
const STREAM_DURATION_MS: u64 = 86_400_000;
/// Smallest possible DUSDC supply payment (1 raw unit).
const DUST_PAYMENT: u64 = 1;

// === EExpiryMarketNotActive ===

#[test, expected_failure(abort_code = plp::EExpiryMarketNotActive)]
fun sync_expiry_on_unregistered_settled_market_aborts() {
    let (mut fx, expiry_id, oracle_id, _manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_PRICE);
    // This sync deactivates the settled expiry and drops it from the active set.
    fx.sync_expiry(&mut config, &mut vault, &mut market, &oracle, &pyth);

    // A fresh sync snapshots an empty active set, so the market is not expected.
    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    abort 999
}

// === EWrongPoolVault ===

#[test, expected_failure(abort_code = plp::EWrongPoolVault)]
fun finish_pool_sync_with_other_vault_sync_aborts() {
    let (mut scenario, _admin_cap, _clock) = begin_pool();
    // Production publishes a single vault (one PLP one-time witness); a second
    // vault from a test treasury cap is the only way to exercise the
    // cross-vault binding guard directly.
    let vault_a = scenario.take_shared<PoolVault>();
    let vault_a_id = vault_a.id();
    let treasury_cap = coin::create_treasury_cap_for_testing<PLP>(scenario.ctx());
    let vault_b_id = plp::create_and_share(treasury_cap, scenario.ctx());
    return_shared(vault_a);
    scenario.next_tx(test_constants::admin());

    let mut config = scenario.take_shared<ProtocolConfig>();
    let vault_a = scenario.take_shared_by_id<PoolVault>(vault_a_id);
    let vault_b = scenario.take_shared_by_id<PoolVault>(vault_b_id);
    let sync = plp::start_pool_sync(&mut config, &vault_b);
    let _pool_value = vault_a.finish_pool_sync(&mut config, sync);
    abort 999
}

// === EExpiryMarketAlreadySynced ===

#[test, expected_failure(abort_code = plp::EExpiryMarketAlreadySynced)]
fun sync_expiry_twice_in_one_sync_aborts() {
    let mut fx = helpers::setup_market_default();
    let (expiry_id, oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    fx.prepare_live_oracle(&config, &mut oracle, &mut pyth, test_constants::default_live_price());

    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    sync.sync_expiry(&mut vault, &mut market, &config, &oracle, &pyth, fx.clock());
    abort 999
}

// === EMissingExpirySync ===

#[test, expected_failure(abort_code = plp::EMissingExpirySync)]
fun finish_pool_sync_without_syncing_active_expiry_aborts() {
    let mut fx = helpers::setup_market_default();
    let (_expiry_id, _oracle_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let vault_id = fx.vault_id();
    let vault = fx.scenario_mut().take_shared_by_id<PoolVault>(vault_id);
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();

    let sync = plp::start_pool_sync(&mut config, &vault);
    let _pool_value = vault.finish_pool_sync(&mut config, sync);
    abort 999
}

// === EZeroSupply ===

#[test, expected_failure(abort_code = plp::EZeroSupply)]
fun supply_with_zero_payment_aborts() {
    let (mut scenario, admin_cap, clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    let pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();

    let sync = plp::start_pool_sync(&mut config, &vault);
    let _plp = vault.supply(
        &mut config,
        sync,
        coin::zero<DUSDC>(scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === EZeroWithdraw ===

// `EZeroWithdraw` guards only the entry (`lp_amount > 0`); a zero rounded
// payout is allowed so an incentive-only exit can complete (see
// `supply_withdraw_rounding_tests::sub_share_withdraw_pays_zero_dusdc_and_still_exits`).
#[test, expected_failure(abort_code = plp::EZeroWithdraw)]
fun withdraw_with_zero_plp_aborts() {
    let (mut scenario, _admin_cap, clock) = begin_pool();
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();

    let sync = plp::start_pool_sync(&mut config, &vault);
    let (_dusdc, _sui, _deep) = vault.withdraw(
        &mut config,
        sync,
        coin::zero<PLP>(scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === EZeroShares ===

#[test, expected_failure(abort_code = plp::EZeroShares)]
fun supply_dust_payment_rounding_to_zero_shares_aborts() {
    let (mut scenario, admin_cap, mut clock) = begin_pool();
    let pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    bootstrap_supply(&mut scenario, &clock, pyth_id);
    configure_sui_incentive(&mut scenario, &admin_cap);
    fund_sui_incentive(&mut scenario, &admin_cap, &clock);

    // Vest the incentive fully, then supply 1 raw DUSDC unit. Share pricing:
    //   total_supply = 300_000e6 (bootstrap 1:1)
    //   dusdc_value  = 300_000e6 idle
    //   incentive    = ceil(1e12 SUI-units * 50_100e9 spot / 10^(9+9-6)) = 50_100e9
    //   pool_value   = 300_000e6 + 50_100e9 = 50_400e9
    //   share_fraction = floor(300_000e6 * 1e9 / 50_400e9) = 5_952_380
    //   shares = floor(1 * 5_952_380 / 1e9) = 0 -> EZeroShares
    let vest_end_ms = test_constants::now_ms() + STREAM_DURATION_MS;
    clock.set_for_testing(vest_end_ms);
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    pyth.set_state_for_testing(test_constants::default_creation_spot(), vest_end_ms, vest_end_ms);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();

    let sync = plp::start_pool_sync(&mut config, &vault);
    let _plp = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(DUST_PAYMENT, scenario.ctx()),
        &pyth,
        &pyth,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === EPackageVersionDisabled ===

#[test, expected_failure(abort_code = plp::EPackageVersionDisabled)]
fun start_pool_sync_with_current_version_disabled_aborts() {
    let (scenario, admin_cap, _clock) = begin_pool();
    let mut registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    registry::enable_version(&mut registry, &admin_cap, constants::current_version!() + 1);
    registry::disable_version(&mut registry, &admin_cap, constants::current_version!());
    registry::sync_pool_vault_allowed_versions(&registry, &mut vault);

    let _sync = plp::start_pool_sync(&mut config, &vault);
    abort 999
}

// === ENoPlpHolders ===

#[test, expected_failure(abort_code = plp::ENoPlpHolders)]
fun incentive_deposit_with_no_plp_holders_aborts() {
    // No bootstrap supply: the vault has zero PLP outstanding, so the deposit
    // must be rejected (the first future supplier would otherwise capture it).
    // The SUI incentive asset IS configured, so the registry's
    // EIncentiveAssetNotConfigured guard passes and the plp guard is the one hit.
    let (mut scenario, admin_cap, clock) = begin_pool();
    let _pyth_id = create_default_pyth(&mut scenario, &admin_cap);
    configure_sui_incentive(&mut scenario, &admin_cap);
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();

    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        &admin_cap,
        coin::mint_for_testing<SUI>(LARGE_SUI_INCENTIVE, scenario.ctx()),
        STREAM_DURATION_MS,
        &clock,
    );
    abort 999
}

// === Private bring-up helpers (no-supply paths the flow fixture cannot serve:
// they need the AdminCap, which `Fixture` holds privately) ===

/// Stand up the production-mirroring shared objects (PLP vault, registry,
/// protocol config) with no PLP supplied, plus the admin cap and a clock at
/// `now_ms`.
fun begin_pool(): (Scenario, AdminCap, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    plp::init_for_testing(scenario.ctx());
    registry::init_for_testing(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    (scenario, admin_cap, clock)
}

/// Register the default Pyth feed and create its shared source.
fun create_default_pyth(scenario: &mut Scenario, admin_cap: &AdminCap): ID {
    let mut registry = scenario.take_shared<Registry>();
    let pyth_id = registry::create_pyth_source(
        &mut registry,
        admin_cap,
        test_constants::pyth_feed_id(),
        test_constants::default_tick_size(),
        scenario.ctx(),
    );
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
    pyth_id
}

/// Bootstrap the pool with the default initial PLP supply through the real
/// `supply` path (1:1 mint), seeding the Pyth source with a fresh spot first.
fun bootstrap_supply(scenario: &mut Scenario, clock: &Clock, pyth_id: ID) {
    let mut pyth = scenario.take_shared_by_id<PythSource>(pyth_id);
    let live_ts = test_constants::live_source_timestamp_ms();
    pyth.set_state_for_testing(test_constants::default_creation_spot(), live_ts, live_ts);
    let mut vault = scenario.take_shared<PoolVault>();
    let mut config = scenario.take_shared<ProtocolConfig>();
    let sync = plp::start_pool_sync(&mut config, &vault);
    let plp_coin = vault.supply(
        &mut config,
        sync,
        coin::mint_for_testing<DUSDC>(test_constants::default_initial_supply(), scenario.ctx()),
        &pyth,
        &pyth,
        clock,
        scenario.ctx(),
    );
    destroy(plp_coin);
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    scenario.next_tx(test_constants::admin());
}

/// Bind SUI as an incentive asset to the default feed through the real admin
/// path. `Currency<SUI>` has no production test seam, so it is built from the
/// framework's test-only one-time-witness + currency initializer helpers.
fun configure_sui_incentive(scenario: &mut Scenario, admin_cap: &AdminCap) {
    let mut registry = scenario.take_shared<Registry>();
    let otw = test_utils::create_one_time_witness<SUI>();
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        SUI_DECIMALS,
        b"SUI".to_string(),
        b"Sui".to_string(),
        b"".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let currency = coin_registry::unwrap_for_testing(initializer);
    registry::set_incentive_asset<SUI>(
        &mut registry,
        admin_cap,
        &currency,
        test_constants::pyth_feed_id(),
    );
    destroy(currency);
    destroy(treasury_cap);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}

/// Deposit `LARGE_SUI_INCENTIVE` as an admin SUI incentive vesting over
/// `STREAM_DURATION_MS`.
fun fund_sui_incentive(scenario: &mut Scenario, admin_cap: &AdminCap, clock: &Clock) {
    let registry = scenario.take_shared<Registry>();
    let mut vault = scenario.take_shared<PoolVault>();
    registry::deposit_sui_incentive(
        &registry,
        &mut vault,
        admin_cap,
        coin::mint_for_testing<SUI>(LARGE_SUI_INCENTIVE, scenario.ctx()),
        STREAM_DURATION_MS,
        clock,
    );
    return_shared(vault);
    return_shared(registry);
    scenario.next_tx(test_constants::admin());
}
