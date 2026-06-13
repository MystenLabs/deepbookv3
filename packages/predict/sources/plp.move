// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PLP token and pool vault.
///
/// PoolVault owns the PLP treasury cap and the pooled DEEP staked by managers.
/// The PLP token is inert: synchronous supply/withdraw, full-pool NAV sync,
/// expiry cash accounting, and profit have been pruned pending the async LP
/// redesign; incentives were pruned and move to a separate staking contract.
/// DEEP staking is an unrelated trading feature and stays.
module deepbook_predict::plp;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    pool_accounting::{Self, Ledger},
    predict_manager::PredictManager,
    vault_events
};
use predict_math::math;
use sui::{
    balance::{Self, Balance},
    coin::{Coin, TreasuryCap},
    coin_registry,
    vec_set::{Self, VecSet}
};
use token::deep::DEEP;

const EPackageVersionDisabled: u64 = 9;

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
    /// Idle DUSDC custody, registered expiries, and per-expiry cash-flow rows.
    expiry_accounting: Ledger,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
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

/// Move cash between pool idle liquidity and one expiry market toward its target.
///
/// Permissionless and standalone: anyone may call it at any cadence. It performs
/// both initial funding of a freshly registered (unfunded) market and ongoing
/// rebalancing. Below target, it tops the market up from idle (bounded by idle
/// liquidity and the net-funding cap); above the sweep band, it returns the
/// surplus over target to idle. Mint asserts backing but never pulls pool cash,
/// so this is what makes a market mintable. The market must already be
/// registered to this vault (`registry::create_expiry_market`).
public fun rebalance_expiry_cash(vault: &mut PoolVault, market: &mut ExpiryMarket) {
    vault.assert_version_allowed();
    market.assert_version_allowed();
    let expiry_market_id = market.id();
    vault.expiry_accounting.assert_registered_expiry(expiry_market_id);
    let (cash_balance, target_cash, sweep_threshold_cash) = expiry_rebalance_cash_terms(market);

    if (cash_balance < target_cash) {
        let requested_top_up = target_cash - cash_balance;
        let funding_room = vault
            .expiry_accounting
            .available_expiry_funding(expiry_market_id, constants::expiry_max_funding!());
        let top_up = requested_top_up.min(vault.expiry_accounting.idle_balance()).min(funding_room);
        if (top_up > 0) {
            let cash = vault
                .expiry_accounting
                .send_expiry_cash(expiry_market_id, constants::expiry_max_funding!(), top_up);
            market.receive_pool_cash(cash);
        };
    } else if (cash_balance > sweep_threshold_cash) {
        let returned_cash = market.release_pool_cash(cash_balance - target_cash);
        vault.expiry_accounting.receive_expiry_cash(expiry_market_id, returned_cash);
    };
}

// === Public-Package Functions ===

/// Create an empty pool vault from the PLP treasury cap.
public(package) fun new(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): PoolVault {
    PoolVault {
        id: object::new(ctx),
        staked_deep: balance::zero(),
        treasury_cap,
        expiry_accounting: pool_accounting::new(ctx),
        allowed_versions: vec_set::singleton(constants::current_version!()),
    }
}

/// Create and share an empty pool vault from the PLP treasury cap.
public(package) fun create_and_share(treasury_cap: TreasuryCap<PLP>, ctx: &mut TxContext): ID {
    let vault = new(treasury_cap, ctx);
    let id = vault.id();
    transfer::share_object(vault);
    id
}

/// Overwrite this vault's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pool_vault_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(vault: &mut PoolVault, allowed_versions: VecSet<u64>) {
    vault.allowed_versions = allowed_versions;
}

/// Register a freshly created expiry market with the pool as an accounting row.
/// No cash moves: the market is not mintable until `rebalance_expiry_cash` funds
/// it. Called by `registry::create_expiry_market`.
public(package) fun register_expiry(vault: &mut PoolVault, expiry_market_id: ID) {
    vault.assert_version_allowed();
    vault.expiry_accounting.register_expiry(expiry_market_id);
}

// === Private Functions ===

/// Abort if the running package version is not allowed for this vault.
fun assert_version_allowed(vault: &PoolVault) {
    assert!(
        vault.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Current cash, the target cash to hold, and the upper sweep band for one expiry.
///
/// `required_cash` is payout liability plus rebate reserve; `target_cash` adds one
/// buffer above it and `sweep_threshold_cash` adds two, both floored at
/// `expiry_cash_floor`. Below target the pool tops up to target; above the sweep
/// band it returns the excess over target.
fun expiry_rebalance_cash_terms(market: &ExpiryMarket): (u64, u64, u64) {
    let required_cash = market.payout_liability() + market.rebate_reserve();
    let target_buffer = math::mul(required_cash, constants::expiry_rebalance_pct!());
    let target_cash = (required_cash + target_buffer).max(constants::expiry_cash_floor!());
    let sweep_threshold_cash = (required_cash + target_buffer + target_buffer).max(
        constants::expiry_cash_floor!(),
    );
    (market.cash_balance(), target_cash, sweep_threshold_cash)
}

// === Test-Only Functions ===

#[test_only]
/// Register PLP in tests.
public fun init_for_testing(ctx: &mut TxContext) {
    init(PLP {}, ctx);
}
