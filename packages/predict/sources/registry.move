// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry and admin entrypoints for the Predict protocol.
///
/// This module creates shared setup objects, stores uniqueness indexes for
/// Pyth sources and expiries, and exposes admin/governance entrypoints. Runtime
/// pool accounting, expiry risk, oracle state, and user positions stay in their
/// owning modules.
module deepbook_predict::registry;

use deepbook_predict::{
    builder_code,
    constants,
    expiry_market::{Self, ExpiryMarket},
    market_oracle::{Self, MarketOracle, MarketOracleCap},
    plp::PoolVault,
    predict_manager::{Self, PredictManager},
    protocol_config::{Self, ProtocolConfig},
    pyth_source::{Self, PythSource}
};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    table::{Self, Table},
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EFeedIdMismatch: u64 = 2;
const EPythSourceAlreadyCreated: u64 = 3;
const EInvalidExpiry: u64 = 4;
const EExpiryMarketAlreadyCreated: u64 = 5;
const EPauseCapNotValid: u64 = 6;
const EPackageVersionDisabled: u64 = 7;
const EVersionAlreadyEnabled: u64 = 8;
const EVersionNotEnabled: u64 = 9;
const ECannotDisableLastVersion: u64 = 10;
/// The DEEP lock is still binding: it has not expired (on unstake) or a stake
/// action tried to set an earlier lock end than the current one.
const EStakeLocked: u64 = 11;
const EInvalidLockDays: u64 = 12;

/// Capability for admin operations.
/// Created during package init, transferred to deployer (multisig).
public struct AdminCap has key, store {
    id: UID,
}

/// Capability for emergency pause operations. Admin can mint these for
/// trusted operators; holders can disable versions, pause global trading,
/// and pause per-market minting. Cannot unpause anything.
public struct PauseCap has key, store {
    id: UID,
}

/// Shared registry for source and expiry uniqueness.
public struct Registry has key {
    id: UID,
    /// Pyth Lazer feed ID -> shared PythSource ID.
    pyth_source_ids: Table<u32, ID>,
    /// Created expiry markets keyed by expiry timestamp.
    expiry_market_ids: Table<u64, ID>,
    /// IDs of `PauseCap` objects currently authorized to use pause-only entries.
    /// Admin mints into this set and revokes from it.
    allowed_pause_caps: VecSet<ID>,
    /// Package versions currently permitted to mutate per-pool state. Authoritative
    /// source; pool objects mirror this set and refresh via permissionless sync.
    allowed_versions: VecSet<u64>,
    /// Pooled DEEP locked by all managers for staking. Per-manager amounts are
    /// mirrored on each `PredictManager`.
    staked_deep: Balance<DEEP>,
}

// === Public Functions ===

/// Return the registry object ID.
public fun id(registry: &Registry): ID {
    registry.id.to_inner()
}

/// Return the set of package versions currently permitted to mutate per-pool
/// state. Pool sync helpers snapshot this; newly-created pools inherit it.
public fun allowed_versions(registry: &Registry): VecSet<u64> {
    registry.allowed_versions
}

/// Return the shared PythSource ID for a feed, if it has been created.
public fun pyth_source_id(registry: &Registry, pyth_lazer_feed_id: u32): Option<ID> {
    if (registry.pyth_source_ids.contains(pyth_lazer_feed_id)) {
        option::some(registry.pyth_source_ids[pyth_lazer_feed_id])
    } else {
        option::none()
    }
}

/// Set the base fee multiplier.
public fun set_base_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.set_base_fee(fee);
}

/// Set the minimum fee floor.
public fun set_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.set_min_fee(fee);
}

/// Set the maximum floor-index increase snapshotted by future expiry markets.
public fun set_template_max_expiry_floor_premium(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_template_max_expiry_floor_premium(value);
}

/// Set the per-asset time-to-expiry fee ramp for a Pyth source's markets.
/// `window_ms` (0 disables) is the ms-before-expiry over which the fee ramps up;
/// `max_multiplier` (FLOAT_SCALING, 1x disables) is the multiplier reached at
/// expiry. Larger values suit more volatile assets.
public fun set_pyth_source_expiry_fee_params(
    pyth: &mut PythSource,
    _admin_cap: &AdminCap,
    window_ms: u64,
    max_multiplier: u64,
) {
    pyth.set_expiry_fee_params(window_ms, max_multiplier);
}

/// Set the global minimum allowed mint price.
public fun set_min_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.set_min_ask_price(value);
}

/// Set the global maximum allowed mint price.
public fun set_max_ask_price(config: &mut ProtocolConfig, _admin_cap: &AdminCap, value: u64) {
    config.set_max_ask_price(value);
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_pyth_spot_freshness_ms(value);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_prices_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_block_scholes_prices_freshness_ms(value);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_block_scholes_svi_freshness_ms(value);
}

/// Set the current fee surplus distribution shares used during settled expiry surplus sweeps.
public fun set_fee_shares(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    config.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
}

/// Set the trading loss rebate rate template used by future expiry markets.
public fun set_template_trading_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_template_trading_loss_rebate_rate(value);
}

/// Set the maximum total exposure percentage.
public fun set_max_total_exposure_pct(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    pct: u64,
) {
    config.set_max_total_exposure_pct(pct);
}

/// Set the current DUSDC allocation for new expiry markets.
public fun set_expiry_allocation(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    allocation: u64,
) {
    config.set_expiry_allocation(allocation);
}

/// Set the utilization threshold that enables expiry allocation growth.
public fun set_grow_utilization_threshold(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    threshold: u64,
) {
    config.set_grow_utilization_threshold(threshold);
}

/// Set the utilization threshold that enables expiry allocation shrink.
public fun set_shrink_utilization_threshold(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    threshold: u64,
) {
    config.set_shrink_utilization_threshold(threshold);
}

/// Set the allocation growth target multiplier.
public fun set_grow_factor(config: &mut ProtocolConfig, _admin_cap: &AdminCap, factor: u64) {
    config.set_grow_factor(factor);
}

/// Set the allocation shrink target multiplier.
public fun set_shrink_factor(config: &mut ProtocolConfig, _admin_cap: &AdminCap, factor: u64) {
    config.set_shrink_factor(factor);
}

/// Set the settlement freshness threshold template used by future market oracles.
public fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.set_market_oracle_template_settlement_freshness_ms(value);
}

/// Set basis guard bounds template used by future market oracles.
public fun set_market_oracle_template_basis_bounds(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.set_market_oracle_template_basis_bounds(
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    );
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.set_trading_paused(paused);
}

// === Version Management (admin) ===

/// Add `version` to the registry's allowed set.
///
/// Not version-gated so admin can re-enable a previously disabled version.
public fun enable_version(registry: &mut Registry, _admin_cap: &AdminCap, version: u64) {
    assert!(!registry.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    registry.allowed_versions.insert(version);
}

/// Remove `version` from the registry's allowed set.
///
/// Not version-gated so admin can revoke a version even after the active
/// version has been paused. The set may not be left empty.
public fun disable_version(registry: &mut Registry, _admin_cap: &AdminCap, version: u64) {
    registry.disable_version_internal(version);
}

// === Version Sync (permissionless) ===
//
// Each shared object that gates flows on a mirrored `allowed_versions` set
// exposes one `sync_*` entry below. The registry is the source of truth: the
// caller supplies `&Registry`, and the entry copies its current set into the
// target. The package-internal `set_allowed_versions` setters on the target
// modules are not callable from outside the package, so user-supplied
// `VecSet<u64>` cannot reach a mirror through any other path.

/// Sync an expiry market's `allowed_versions` mirror from the registry.
public fun sync_expiry_market_allowed_versions(registry: &Registry, market: &mut ExpiryMarket) {
    market.set_allowed_versions(registry.allowed_versions);
}

/// Sync a pool vault's `allowed_versions` mirror from the registry.
public fun sync_pool_vault_allowed_versions(registry: &Registry, vault: &mut PoolVault) {
    vault.set_allowed_versions(registry.allowed_versions);
}

/// Sync a market oracle's `allowed_versions` mirror from the registry.
public fun sync_market_oracle_allowed_versions(registry: &Registry, market: &mut MarketOracle) {
    market.set_allowed_versions(registry.allowed_versions);
}

/// Sync a Pyth source's `allowed_versions` mirror from the registry.
public fun sync_pyth_source_allowed_versions(registry: &Registry, source: &mut PythSource) {
    source.set_allowed_versions(registry.allowed_versions);
}

// === PauseCap Lifecycle (admin) ===

/// Mint a new `PauseCap`. Admin-only and bypasses the version gate so the
/// kill switch remains available even when admin has misconfigured versions.
public fun mint_pause_cap(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): PauseCap {
    let id = object::new(ctx);
    registry.allowed_pause_caps.insert(id.to_inner());
    PauseCap { id }
}

/// Revoke a previously minted `PauseCap` by ID. Admin-only.
public fun revoke_pause_cap(registry: &mut Registry, _admin_cap: &AdminCap, pause_cap_id: ID) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap_id), EPauseCapNotValid);
    registry.allowed_pause_caps.remove(&pause_cap_id);
}

/// Destroy a `PauseCap` the holder no longer needs.
public fun destroy_pause_cap(cap: PauseCap) {
    let PauseCap { id } = cap;
    id.delete();
}

// === Emergency Pause (PauseCap) ===

/// Disable a package version via a valid `PauseCap`. One-way: admin must
/// `enable_version` to restore.
public fun disable_version_pause_cap(registry: &mut Registry, pause_cap: &PauseCap, version: u64) {
    registry.assert_valid_pause_cap(pause_cap);
    registry.disable_version_internal(version);
}

/// Force `trading_paused = true` via a valid `PauseCap`. One-way.
public fun pause_trading_pause_cap(
    config: &mut ProtocolConfig,
    registry: &Registry,
    pause_cap: &PauseCap,
) {
    registry.assert_valid_pause_cap(pause_cap);
    config.pause_trading();
}

/// Force `mint_paused = true` on a single expiry market via a valid `PauseCap`.
/// One-way; admin's `set_expiry_market_mint_paused` is needed to unpause.
public fun pause_expiry_market_mint_pause_cap(
    market: &mut ExpiryMarket,
    registry: &Registry,
    pause_cap: &PauseCap,
) {
    registry.assert_valid_pause_cap(pause_cap);
    market.pause_mint();
}

// === Per-Market Mint Pause (admin) ===

/// Set `mint_paused` on a single expiry market. Admin can pause or unpause.
public fun set_expiry_market_mint_paused(
    market: &mut ExpiryMarket,
    _admin_cap: &AdminCap,
    paused: bool,
) {
    market.set_mint_paused(paused);
}

/// Create a shared Pyth source for one admin-approved Lazer feed, configuring
/// the per-asset expiry-fee ramp up front (window 0 or multiplier 1x disables it).
///
/// The registry enforces one source object per feed ID.
public fun create_pyth_source(
    registry: &mut Registry,
    _admin_cap: &AdminCap,
    pyth_lazer_feed_id: u32,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    ctx: &mut TxContext,
): ID {
    registry.assert_version_allowed();
    assert!(!registry.pyth_source_ids.contains(pyth_lazer_feed_id), EPythSourceAlreadyCreated);
    let pyth_source_id = pyth_source::create_and_share(
        pyth_lazer_feed_id,
        registry.allowed_versions,
        expiry_fee_window_ms,
        expiry_fee_max_multiplier,
        ctx,
    );
    registry.pyth_source_ids.add(pyth_lazer_feed_id, pyth_source_id);
    pyth_source_id
}

/// Admin-only creation of a new MarketOracleCap.
public fun create_market_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): MarketOracleCap {
    market_oracle::create_cap(ctx)
}

/// Register an additional MarketOracleCap as authorized to update a market oracle.
public fun register_market_oracle_cap(
    market: &mut MarketOracle,
    _admin_cap: &AdminCap,
    cap: &MarketOracleCap,
) {
    market.register_cap(cap);
}

/// Revoke a MarketOracleCap's authorization on a market oracle.
public fun unregister_market_oracle_cap(
    market: &mut MarketOracle,
    _admin_cap: &AdminCap,
    cap_id: ID,
) {
    market.unregister_cap(cap_id);
}

/// Cap holder voluntarily removes its own cap from a market oracle.
public fun self_unregister_market_oracle_cap(market: &mut MarketOracle, cap: &MarketOracleCap) {
    market.self_unregister_cap(cap);
}

/// Destroy a MarketOracleCap the holder no longer needs.
public fun destroy_market_oracle_cap(cap: MarketOracleCap) {
    cap.destroy_cap();
}

/// Create the MarketOracle and ExpiryMarket objects for one future expiry.
///
/// The registry enforces one market per expiry, validates the registered Pyth
/// source, allocates initial pool capital, and registers the expiry as active.
public fun create_expiry_market(
    registry: &mut Registry,
    pool_vault: &mut PoolVault,
    config: &ProtocolConfig,
    pyth: &PythSource,
    cap: &MarketOracleCap,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    registry.assert_version_allowed();
    config.assert_trading_allowed();
    assert!(expiry > clock.timestamp_ms(), EInvalidExpiry);
    let pyth_lazer_feed_id = pyth.feed_id();
    assert!(registry.pyth_source_ids.contains(pyth_lazer_feed_id), EFeedIdMismatch);
    assert!(registry.pyth_source_ids[pyth_lazer_feed_id] == pyth.id(), EFeedIdMismatch);
    assert!(!registry.expiry_market_ids.contains(expiry), EExpiryMarketAlreadyCreated);
    let allowed_versions = registry.allowed_versions;
    let allocation = pool_vault.allocate_to_new_expiry(config.risk_config());
    let market_oracle_id = market_oracle::create_and_share(
        pyth,
        config.market_oracle_config(),
        cap,
        expiry,
        allowed_versions,
        ctx,
    );
    let expiry_market_id = expiry_market::create_and_share(
        config,
        allocation,
        allowed_versions,
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        min_strike,
        tick_size,
        ctx,
    );
    pool_vault.register_expiry_market(expiry_market_id);
    registry.expiry_market_ids.add(expiry, expiry_market_id);

    (expiry_market_id, market_oracle_id)
}

/// Create a derived shared BuilderCode for the caller and index.
public fun create_builder_code(registry: &mut Registry, index: u64, ctx: &mut TxContext): ID {
    builder_code::create_and_share(&mut registry.id, index, ctx)
}

/// Create a derived PredictManager for the caller.
public fun create_manager(registry: &mut Registry, ctx: &mut TxContext): PredictManager {
    predict_manager::new(&mut registry.id, ctx)
}

/// Stake DEEP, or top up / extend an existing lock, for trading benefits.
///
/// Adds `deep` to the manager's locked balance and commits the lock to
/// `lock_days` from now (1..=2 years; longer is rejected). The new lock end may
/// not be earlier than the current one. Longer locks and larger stakes both
/// raise live power. Pass a zero-value coin to extend the lock without adding
/// DEEP.
public fun stake_deep(
    registry: &mut Registry,
    manager: &mut PredictManager,
    deep: Coin<DEEP>,
    lock_days: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.assert_version_allowed();
    manager.assert_owner(ctx);
    assert!(lock_days >= 1 && lock_days <= constants::max_lock_days!(), EInvalidLockDays);

    let new_end_ms = clock.timestamp_ms() + lock_days * constants::day_ms!();
    assert!(new_end_ms >= manager.stake_end_ms(), EStakeLocked);

    let new_amount = manager.staked_deep() + deep.value();
    registry.staked_deep.join(deep.into_balance());
    manager.set_stake(new_amount, new_end_ms);
}

/// Withdraw all locked DEEP once the lock has expired.
public fun unstake_deep(
    registry: &mut Registry,
    manager: &mut PredictManager,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<DEEP> {
    registry.assert_version_allowed();
    manager.assert_owner(ctx);
    assert!(clock.timestamp_ms() >= manager.stake_end_ms(), EStakeLocked);

    let amount = manager.clear_stake();
    registry.staked_deep.split(amount).into_coin(ctx)
}

/// Create and share a derived PredictManager for the caller.
entry fun create_and_share_manager(registry: &mut Registry, ctx: &mut TxContext) {
    create_manager(registry, ctx).share();
}

// === Public-Package Functions ===

/// Abort if the running package version is not in the allowed set.
///
/// Bypasses are package-internal version-management entries
/// (`enable_version`, `disable_version`, PauseCap-based disables) so admin
/// can recover from any disabled state.
public(package) fun assert_version_allowed(registry: &Registry) {
    assert!(
        registry.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

// === Private Functions ===

/// Package initializer - creates Registry and AdminCap.
fun init(ctx: &mut TxContext) {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());
}

/// Construct registry and admin cap during package init or tests.
fun new_registry_and_admin_cap(ctx: &mut TxContext): (Registry, AdminCap) {
    (
        Registry {
            id: object::new(ctx),
            pyth_source_ids: table::new(ctx),
            expiry_market_ids: table::new(ctx),
            allowed_pause_caps: vec_set::empty(),
            allowed_versions: vec_set::singleton(constants::current_version!()),
            staked_deep: balance::zero(),
        },
        AdminCap {
            id: object::new(ctx),
        },
    )
}

/// Abort unless the supplied `PauseCap` was minted by admin and not revoked.
fun assert_valid_pause_cap(registry: &Registry, pause_cap: &PauseCap) {
    assert!(registry.allowed_pause_caps.contains(&pause_cap.id.to_inner()), EPauseCapNotValid);
}

/// Remove a version from the allowed set, enforcing the non-empty invariant.
/// Shared by the admin `disable_version` and PauseCap `disable_version_pause_cap`.
fun disable_version_internal(registry: &mut Registry, version: u64) {
    assert!(registry.allowed_versions.contains(&version), EVersionNotEnabled);
    assert!(registry.allowed_versions.length() > 1, ECannotDisableLastVersion);
    registry.allowed_versions.remove(&version);
}

// === Test-Only Functions ===

#[test_only]
/// Initialize registry and admin cap for tests, returning the registry ID.
public fun init_for_testing(ctx: &mut TxContext): ID {
    let (registry, admin_cap) = new_registry_and_admin_cap(ctx);
    let registry_id = registry.id();
    protocol_config::create_and_share(ctx);
    transfer::share_object(registry);
    transfer::transfer(admin_cap, ctx.sender());

    registry_id
}

#[test_only]
/// Create an admin cap for tests.
public fun create_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

#[test_only]
/// Return a Registry + AdminCap without sharing or storing the registry.
/// Use this when a test wants direct access without `test_scenario`.
public fun new_for_testing(ctx: &mut TxContext): (Registry, AdminCap) {
    new_registry_and_admin_cap(ctx)
}

#[test_only]
public fun destroy_registry_for_testing(registry: Registry) {
    let Registry {
        id,
        pyth_source_ids,
        expiry_market_ids,
        allowed_pause_caps: _,
        allowed_versions: _,
        staked_deep,
    } = registry;
    id.delete();
    pyth_source_ids.destroy_empty();
    expiry_market_ids.destroy_empty();
    staked_deep.destroy_for_testing();
}

/// Variant for tests that exercise registration paths: drops the uniqueness
/// tables without requiring them to be empty.
#[test_only]
public fun destroy_registry_drop_for_testing(registry: Registry) {
    let Registry {
        id,
        pyth_source_ids,
        expiry_market_ids,
        allowed_pause_caps: _,
        allowed_versions: _,
        staked_deep,
    } = registry;
    id.delete();
    pyth_source_ids.drop();
    expiry_market_ids.drop();
    staked_deep.destroy_for_testing();
}
