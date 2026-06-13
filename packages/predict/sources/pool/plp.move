// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap, the pooled DEEP staked by managers, and
/// the market-lifecycle cap allowlist used by market creation. The PLP token is
/// inert: synchronous supply/withdraw, full-pool NAV sync, expiry cash
/// accounting, profit, and incentives have been pruned pending the async LP
/// redesign. DEEP staking and the lifecycle-cap allowlist are unrelated trading
/// features and stay.
module deepbook_predict::plp;

use deepbook_predict::{
    admin::AdminCap,
    constants,
    market_lifecycle_cap::{Self, MarketLifecycleCap},
    predict_manager::PredictManager,
    vault_events
};
use sui::{
    balance::{Self, Balance},
    coin::{Coin, TreasuryCap},
    coin_registry,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EPackageVersionDisabled: u64 = 9;
const ELifecycleCapNotValid: u64 = 11;
const ELifecycleCapNotFound: u64 = 12;

/// One-time witness type for Predict LP token registration.
public struct PLP has drop {}

/// Pool-level vault state.
public struct PoolVault has key {
    id: UID,
    /// Pooled DEEP staked by all managers for trading benefits. Per-manager
    /// active/inactive amounts are mirrored on each `PredictManager`.
    staked_deep: Balance<DEEP>,
    /// Treasury cap for the inert PLP share token (kept for the LP rebuild).
    treasury_cap: TreasuryCap<PLP>,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
    /// IDs of `MarketLifecycleCap` objects currently authorized for market
    /// lifecycle entries (market creation). Admin mints into this set and
    /// revokes from it.
    allowed_lifecycle_caps: VecSet<ID>,
}

// === Package Initializer ===

/// Register PLP metadata and create the pool vault on package publish.
fun init(witness: PLP, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        witness,
        6,
        b"PLP".to_string(),
        b"Predict LP".to_string(),
        b"LP token representing shares in the Predict pool vault".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    create_and_share(treasury_cap, ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
}

// === Public Functions ===

/// Return the pool vault object ID.
public fun id(vault: &PoolVault): ID {
    vault.id.to_inner()
}

/// Return this vault's mirrored set of allowed package versions.
public fun allowed_versions(vault: &PoolVault): VecSet<u64> {
    vault.allowed_versions
}

/// Return DEEP staked by managers and held in custody by the pool.
public fun staked_deep(vault: &PoolVault): u64 {
    vault.staked_deep.value()
}

/// Stake DEEP for trading benefits. The DEEP is held in the pool vault; the
/// amount is recorded as inactive on the manager and activates next epoch
/// (`PredictManager.update_stake`, run by the trade/claim flows). Callable
/// anytime, any number of times.
public fun stake_deep(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    deep: Coin<DEEP>,
    ctx: &TxContext,
) {
    vault.assert_version_allowed();
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    let amount = deep.value();
    manager.add_inactive_stake(amount);
    vault.staked_deep.join(deep.into_balance());
    vault_events::emit_deep_staked(
        vault.id(),
        manager.id(),
        amount,
        manager.active_stake(),
        manager.inactive_stake(),
    );
}

/// Withdraw all staked DEEP (active and inactive) at any time, no penalty.
public fun unstake_deep(
    vault: &mut PoolVault,
    manager: &mut PredictManager,
    ctx: &mut TxContext,
): Coin<DEEP> {
    vault.assert_version_allowed();
    manager.assert_owner(ctx);
    let amount = manager.remove_all_stake();
    vault_events::emit_deep_unstaked(vault.id(), manager.id(), amount);
    vault.staked_deep.split(amount).into_coin(ctx)
}

/// Mint a new `MarketLifecycleCap`. Admin-only.
public fun mint_lifecycle_cap(
    vault: &mut PoolVault,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): MarketLifecycleCap {
    vault.assert_version_allowed();
    let cap = market_lifecycle_cap::new(ctx);
    vault.allowed_lifecycle_caps.insert(cap.id());
    cap
}

/// Revoke a previously minted `MarketLifecycleCap` by ID. Admin-only.
/// Deliberately not version-gated (like pause-cap revocation): revocation is
/// harm-reducing and must stay available even when per-object version mirrors
/// transiently disagree with the gates on this cap's lifecycle entries.
public fun revoke_lifecycle_cap(
    vault: &mut PoolVault,
    _admin_cap: &AdminCap,
    lifecycle_cap_id: ID,
) {
    // Distinct from the gate code so expected_failure tests that revoke first
    // stay pinned to the create gate under test.
    assert!(vault.allowed_lifecycle_caps.contains(&lifecycle_cap_id), ELifecycleCapNotFound);
    vault.allowed_lifecycle_caps.remove(&lifecycle_cap_id);
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        staked_deep: balance::zero(),
        treasury_cap,
        allowed_versions: vec_set::singleton(constants::current_version!()),
        allowed_lifecycle_caps: vec_set::empty(),
    }
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = vault.id();
    transfer::share_object(vault);
    id
}

/// Abort unless the supplied lifecycle cap was minted by admin and not
/// revoked. Called by `registry::create_expiry_market`.
public(package) fun assert_valid_lifecycle_cap(vault: &PoolVault, cap: &MarketLifecycleCap) {
    assert!(vault.allowed_lifecycle_caps.contains(&cap.id()), ELifecycleCapNotValid);
}

/// Overwrite this vault's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pool_vault_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(vault: &mut PoolVault, allowed_versions: VecSet<u64>) {
    vault.allowed_versions = allowed_versions;
}

// === Private Functions ===

/// Abort if the running package version is not allowed for this vault.
fun assert_version_allowed(vault: &PoolVault) {
    assert!(
        vault.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
