// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::{constants, math};
use margin_trading::{
    interest_params::{Self, InterestParams},
    margin_constants,
    margin_registry::{MarginRegistry, MaintainerCap, MarginAdminCap, MarginPoolCap},
    margin_state::{Self, State},
    position_manager::{Self, PositionManager},
    protocol_config::{Self, ProtocolConfig},
    referral_manager::{Self, ReferralManager, ReferralCap}
};
use std::type_name;
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    vec_set::{Self, VecSet},
    versioned::{Self, Versioned}
};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const EMaxPoolBorrowPercentageExceeded: u64 = 4;
const EInvalidLoanQuantity: u64 = 5;
const EDeepbookPoolAlreadyAllowed: u64 = 6;
const EDeepbookPoolNotAllowed: u64 = 7;
const EInvalidMarginPoolCap: u64 = 8;
const EInvalidRiskParam: u64 = 9;
const EInvalidProtocolSpread: u64 = 10;
const EPackageVersionDisabled: u64 = 11;

// === Structs ===
public struct MarginPool<phantom Asset> has key {
    id: UID,
    inner: Versioned,
}

public struct MarginPoolInner<phantom Asset> has store {
    allowed_versions: VecSet<u64>,
    vault: Balance<Asset>,
    state: State,
    interest: InterestParams,
    config: ProtocolConfig,
    protocol_profit: u64,
    positions: PositionManager,
    referral_manager: ReferralManager,
    allowed_deepbook_pools: VecSet<ID>,
}

// === Public Functions * ADMIN *===
/// Creates and registers a new margin pool. If a same asset pool already exists, abort.
/// Returns a `MarginPoolCap` that can be used to update the margin pool.
public fun create_margin_pool<Asset>(
    registry: &mut MarginRegistry,
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
    supply_cap: u64,
    max_borrow_percentage: u64,
    protocol_spread: u64,
    maintainer_cap: &MaintainerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let margin_pool_inner = MarginPoolInner<Asset> {
        allowed_versions: registry.allowed_versions(),
        vault: balance::zero<Asset>(),
        state: margin_state::default(clock),
        interest: interest_params::new_interest_params(
            base_rate,
            base_slope,
            optimal_utilization,
            excess_slope,
        ),
        config: protocol_config::default(supply_cap, max_borrow_percentage, protocol_spread),
        protocol_profit: 0,
        positions: position_manager::create_position_manager(ctx),
        referral_manager: referral_manager::empty(),
        allowed_deepbook_pools: vec_set::empty(),
    };

    let margin_pool = MarginPool<Asset> {
        id: object::new(ctx),
        inner: versioned::create(margin_constants::margin_version(), margin_pool_inner, ctx),
    };
    let margin_pool_id = margin_pool.id.to_inner();
    transfer::share_object(margin_pool);

    let key = type_name::get<Asset>();
    registry.register_margin_pool(maintainer_cap, key, margin_pool_id, ctx);

    margin_pool_id
}

/// Allow a margin manager tied to a deepbook pool to borrow from the margin pool.
public fun enable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    let inner = self.load_inner_mut();
    assert!(!inner.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolAlreadyAllowed);
    inner.allowed_deepbook_pools.insert(deepbook_pool_id);
}

/// Disable a margin manager tied to a deepbook pool from borrowing from the margin pool.
public fun disable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    let inner = self.load_inner_mut();
    assert!(inner.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolNotAllowed);
    inner.allowed_deepbook_pools.remove(&deepbook_pool_id);
}

public fun mint_referral_cap<Asset>(
    self: &mut MarginPool<Asset>,
    _cap: &MarginAdminCap,
    ctx: &mut TxContext,
): ReferralCap {
    let inner = self.load_inner_mut();
    let current_index = inner.state.supply_index();
    inner.referral_manager.mint_referral_cap(current_index, ctx)
}

public fun update_interest_params<Asset>(
    self: &mut MarginPool<Asset>,
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    let inner = self.load_inner_mut();
    let interest_params = interest_params::new_interest_params(
        base_rate,
        base_slope,
        optimal_utilization,
        excess_slope,
    );
    assert!(
        inner.config.max_utilization_rate() >= interest_params.optimal_utilization(),
        EInvalidRiskParam,
    );
    inner.interest = interest_params;
}

public fun update_protocol_config<Asset>(
    self: &mut MarginPool<Asset>,
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    let inner = self.load_inner_mut();
    assert!(protocol_spread <= constants::float_scaling(), EInvalidProtocolSpread);
    assert!(max_utilization_rate <= constants::float_scaling(), EInvalidRiskParam);
    assert!(max_utilization_rate >= inner.interest.optimal_utilization(), EInvalidRiskParam);
    inner.config = protocol_config::default(supply_cap, max_utilization_rate, protocol_spread);
}

/// Resets the protocol profit and returns the coin.
public fun withdraw_protocol_profit<Asset>(
    self: &mut MarginPool<Asset>,
    margin_pool_cap: &MarginPoolCap,
    ctx: &mut TxContext,
): Coin<Asset> {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    let inner = self.load_inner_mut();

    let profit = inner.protocol_profit;
    inner.protocol_profit = 0;
    let balance = inner.vault.split(profit);

    balance.into_coin(ctx)
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    referral: Option<ID>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };

    let supplier = ctx.sender();
    let (referred_supply_shares, previous_referral) = inner
        .positions
        .reset_referral_supply_shares(supplier);
    inner
        .referral_manager
        .decrease_referral_supply_shares(previous_referral, referred_supply_shares);

    let supply_amount = coin.value();
    let supply_shares = inner.state.to_supply_shares(supply_amount);
    inner.state.increase_total_supply(supply_amount);
    let new_supply_shares = inner.positions.increase_user_supply_shares(supplier, supply_shares);
    inner.referral_manager.increase_referral_supply_shares(referral, new_supply_shares);

    let balance = coin.into_balance();
    inner.vault.join(balance);

    assert!(inner.state.total_supply() <= inner.config.supply_cap(), ESupplyCapExceeded);
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };

    let supplier = ctx.sender();
    let (referred_supply_shares, previous_referral) = inner
        .positions
        .reset_referral_supply_shares(supplier);
    inner
        .referral_manager
        .decrease_referral_supply_shares(previous_referral, referred_supply_shares);

    let user_supply_shares = inner.positions.user_supply_shares(supplier);
    let user_supply_amount = inner.state.to_supply_amount(user_supply_shares);
    let withdrawal_amount = amount.get_with_default(user_supply_amount);
    let withdrawal_amount_shares = inner.state.to_supply_shares(withdrawal_amount);
    assert!(withdrawal_amount_shares <= user_supply_shares, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= inner.vault.value(), ENotEnoughAssetInPool);

    inner.state.decrease_total_supply(withdrawal_amount);
    inner.positions.decrease_user_supply_shares(supplier, withdrawal_amount_shares);

    inner.vault.split(withdrawal_amount).into_coin(ctx)
}

public(package) fun claim_referral_rewards<Asset>(
    self: &mut MarginPool<Asset>,
    referral_cap: &ReferralCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };
    let share_value_appreciated = inner
        .referral_manager
        .claim_referral_rewards(referral_cap.id(), inner.state.supply_index());
    let reward_amount = math::mul(share_value_appreciated, inner.config.protocol_spread());
    inner.protocol_profit = inner.protocol_profit - reward_amount;

    inner.vault.split(reward_amount).into_coin(ctx)
}

// === Public-View Functions ===
public fun deepbook_pool_allowed<Asset>(self: &MarginPool<Asset>, deepbook_pool_id: ID): bool {
    let inner = self.load_inner();
    inner.allowed_deepbook_pools.contains(&deepbook_pool_id)
}

// === Public-Package Functions ===
public(package) fun update_state<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    }
}

/// Allows borrowing from the margin pool. Returns the borrowed coin.
public(package) fun borrow<Asset>(
    self: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    let inner = self.load_inner_mut();
    assert!(amount <= inner.vault.value(), ENotEnoughAssetInPool);
    assert!(amount > 0, EInvalidLoanQuantity);

    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };
    inner.state.increase_total_borrow(amount);

    assert!(
        inner.state.utilization_rate() <= inner.config.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let balance = inner.vault.split(amount);

    balance.into_coin(ctx)
}

/// Allows repaying the loan.
public(package) fun repay<Asset>(self: &mut MarginPool<Asset>, coin: Coin<Asset>, clock: &Clock) {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };
    inner.state.decrease_total_borrow(coin.value());
    inner.vault.join(coin.into_balance());
}

public(package) fun repay_with_reward<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    repay_amount: u64,
    reward_amount: u64,
    default_amount: u64,
    clock: &Clock,
) {
    let inner = self.load_inner_mut();
    let interest_accrued = inner.state.update(&inner.interest, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, inner.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        inner.protocol_profit = inner.protocol_profit + protocol_profit_accrued;
        inner.state.decrease_total_supply_with_index(protocol_profit_accrued);
    };
    inner.state.decrease_total_borrow(repay_amount);
    inner.state.increase_total_supply_with_index(reward_amount);
    inner.state.decrease_total_supply_with_index(default_amount);
    inner.vault.join(coin.into_balance());
}

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    let inner = self.load_inner();
    inner.config.supply_cap()
}

public(package) fun to_borrow_shares<Asset>(self: &MarginPool<Asset>, amount: u64): u64 {
    let inner = self.load_inner();
    inner.state.to_borrow_shares(amount)
}

public(package) fun to_borrow_amount<Asset>(self: &MarginPool<Asset>, shares: u64): u64 {
    let inner = self.load_inner();
    inner.state.to_borrow_amount(shares)
}

public(package) fun max_utilization_rate<Asset>(self: &MarginPool<Asset>): u64 {
    let inner = self.load_inner();
    inner.config.max_utilization_rate()
}

public(package) fun id<Asset>(self: &MarginPool<Asset>): ID {
    self.id.to_inner()
}

fun load_inner<Asset>(self: &MarginPool<Asset>): &MarginPoolInner<Asset> {
    let inner: &MarginPoolInner<Asset> = self.inner.load_value();
    let package_version = margin_constants::margin_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

fun load_inner_mut<Asset>(self: &mut MarginPool<Asset>): &mut MarginPoolInner<Asset> {
    let inner: &mut MarginPoolInner<Asset> = self.inner.load_value_mut();
    let package_version = margin_constants::margin_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}
