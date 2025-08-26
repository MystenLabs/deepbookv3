// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::{
    margin_registry::{MarginRegistry, MaintainerCap, MarginAdminCap, MarginPoolCap},
    margin_state::{Self, State},
    position_manager::{Self, PositionManager},
    protocol_config::{InterestConfig, MarginPoolConfig, ProtocolConfig},
    referral_manager::{Self, ReferralManager, ReferralCap}
};
use std::type_name;
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, vec_set::{Self, VecSet}};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const EMaxPoolBorrowPercentageExceeded: u64 = 4;
const EInvalidLoanQuantity: u64 = 5;
const EDeepbookPoolAlreadyAllowed: u64 = 6;
const EDeepbookPoolNotAllowed: u64 = 7;
const EInvalidMarginPoolCap: u64 = 8;

// === Structs ===
public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    state: State,
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
    protocol_config: ProtocolConfig,
    maintainer_cap: &MaintainerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let margin_pool_id = id.to_inner();
    let margin_pool = MarginPool<Asset> {
        id,
        vault: balance::zero<Asset>(),
        state: margin_state::default(clock),
        config: protocol_config,
        protocol_profit: 0,
        positions: position_manager::create_position_manager(ctx),
        referral_manager: referral_manager::empty(),
        allowed_deepbook_pools: vec_set::empty(),
    };
    transfer::share_object(margin_pool);

    let key = type_name::get<Asset>();
    registry.register_margin_pool(key, margin_pool_id, maintainer_cap, ctx);

    margin_pool_id
}

/// Allow a margin manager tied to a deepbook pool to borrow from the margin pool.
public fun enable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    assert!(!self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolAlreadyAllowed);
    self.allowed_deepbook_pools.insert(deepbook_pool_id);
}

/// Disable a margin manager tied to a deepbook pool from borrowing from the margin pool.
public fun disable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    assert!(self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolNotAllowed);
    self.allowed_deepbook_pools.remove(&deepbook_pool_id);
}

public fun mint_referral_cap<Asset>(
    self: &mut MarginPool<Asset>,
    _cap: &MarginAdminCap,
    ctx: &mut TxContext,
): ReferralCap {
    let current_index = self.state.supply_index();
    self.referral_manager.mint_referral_cap(current_index, ctx)
}

public fun update_interest_params<Asset>(
    self: &mut MarginPool<Asset>,
    interest_config: InterestConfig,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    self.config.set_interest_config(interest_config);
}

public fun update_protocol_config<Asset>(
    self: &mut MarginPool<Asset>,
    margin_pool_config: MarginPoolConfig,
    margin_pool_cap: &MarginPoolCap,
) {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    self.config.set_margin_pool_config(margin_pool_config);
}

/// Resets the protocol profit and returns the coin.
public fun withdraw_protocol_profit<Asset>(
    self: &mut MarginPool<Asset>,
    margin_pool_cap: &MarginPoolCap,
    ctx: &mut TxContext,
): Coin<Asset> {
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);

    let profit = self.protocol_profit;
    self.protocol_profit = 0;
    let balance = self.vault.split(profit);

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
    self.update_state(clock);

    let supplier = ctx.sender();
    let (referred_supply_shares, previous_referral) = self
        .positions
        .reset_referral_supply_shares(supplier);
    self
        .referral_manager
        .decrease_referral_supply_shares(previous_referral, referred_supply_shares);

    let supply_amount = coin.value();
    let supply_shares = self.state.to_supply_shares(supply_amount);
    self.state.increase_total_supply(supply_amount);
    let new_supply_shares = self.positions.increase_user_supply_shares(supplier, supply_shares);
    self.referral_manager.increase_referral_supply_shares(referral, new_supply_shares);

    let balance = coin.into_balance();
    self.vault.join(balance);

    assert!(self.state.total_supply() <= self.config.supply_cap(), ESupplyCapExceeded);
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    self.update_state(clock);

    let supplier = ctx.sender();
    let (referred_supply_shares, previous_referral) = self
        .positions
        .reset_referral_supply_shares(supplier);
    self
        .referral_manager
        .decrease_referral_supply_shares(previous_referral, referred_supply_shares);

    let user_supply_shares = self.positions.user_supply_shares(supplier);
    let user_supply_amount = self.state.to_supply_amount(user_supply_shares);
    let withdrawal_amount = amount.get_with_default(user_supply_amount);
    let withdrawal_amount_shares = self.state.to_supply_shares(withdrawal_amount);
    assert!(withdrawal_amount_shares <= user_supply_shares, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= self.vault.value(), ENotEnoughAssetInPool);

    self.state.decrease_total_supply(withdrawal_amount);
    self.positions.decrease_user_supply_shares(supplier, withdrawal_amount_shares);

    self.vault.split(withdrawal_amount).into_coin(ctx)
}

public(package) fun claim_referral_rewards<Asset>(
    self: &mut MarginPool<Asset>,
    referral_cap: &ReferralCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    self.update_state(clock);
    let share_value_appreciated = self
        .referral_manager
        .claim_referral_rewards(referral_cap.id(), self.state.supply_index());
    let reward_amount = math::mul(share_value_appreciated, self.config.protocol_spread());
    self.protocol_profit = self.protocol_profit - reward_amount;

    self.vault.split(reward_amount).into_coin(ctx)
}

// === Public-View Functions ===
public fun deepbook_pool_allowed<Asset>(self: &MarginPool<Asset>, deepbook_pool_id: ID): bool {
    self.allowed_deepbook_pools.contains(&deepbook_pool_id)
}

// === Public-Package Functions ===
public(package) fun update_state<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    let interest_accrued = self.state.update(&self.config, clock);
    let protocol_profit_accrued = math::mul(interest_accrued, self.config.protocol_spread());
    if (protocol_profit_accrued > 0) {
        self.protocol_profit = self.protocol_profit + protocol_profit_accrued;
        self.state.decrease_total_supply_with_index(protocol_profit_accrued);
    }
}

/// Allows borrowing from the margin pool. Returns the borrowed coin.
public(package) fun borrow<Asset>(
    self: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    assert!(amount <= self.vault.value(), ENotEnoughAssetInPool);
    assert!(amount > 0, EInvalidLoanQuantity);

    self.update_state(clock);
    self.state.increase_total_borrow(amount);

    assert!(
        self.state.utilization_rate() <= self.config.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let balance = self.vault.split(amount);

    balance.into_coin(ctx)
}

/// Allows repaying the loan.
public(package) fun repay<Asset>(self: &mut MarginPool<Asset>, coin: Coin<Asset>, clock: &Clock) {
    self.update_state(clock);
    self.state.decrease_total_borrow(coin.value());
    self.vault.join(coin.into_balance());
}

public(package) fun repay_with_reward<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    repay_amount: u64,
    reward_amount: u64,
    default_amount: u64,
    clock: &Clock,
) {
    self.update_state(clock);
    self.state.decrease_total_borrow(repay_amount);
    self.state.increase_total_supply_with_index(reward_amount);
    self.state.decrease_total_supply_with_index(default_amount);
    self.vault.join(coin.into_balance());
}

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.supply_cap()
}

public(package) fun to_borrow_shares<Asset>(self: &MarginPool<Asset>, amount: u64): u64 {
    self.state.to_borrow_shares(amount)
}

public(package) fun to_borrow_amount<Asset>(self: &MarginPool<Asset>, shares: u64): u64 {
    self.state.to_borrow_amount(shares)
}

public fun id<Asset>(self: &MarginPool<Asset>): ID {
    self.id.to_inner()
}
