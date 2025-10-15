// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::margin_pool;

use deepbook::{balance_manager::{BalanceManager, WithdrawCap, DepositCap}, math};
use deepbook_margin::{
    margin_registry::{MarginRegistry, MaintainerCap, MarginAdminCap, MarginPoolCap},
    margin_state::{Self, State},
    position_manager::{Self, PositionManager},
    protocol_config::{InterestConfig, MarginPoolConfig, ProtocolConfig},
    referral_fees::{Self, ReferralFees, SupplyReferral}
};
use std::{string::String, type_name::{Self, TypeName}};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    event,
    vec_map::{Self, VecMap},
    vec_set::{Self, VecSet}
};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const EMaxPoolBorrowPercentageExceeded: u64 = 3;
const EDeepbookPoolAlreadyAllowed: u64 = 4;
const EDeepbookPoolNotAllowed: u64 = 5;
const EInvalidMarginPoolCap: u64 = 6;
const EBorrowAmountTooLow: u64 = 7;

// === Structs ===
public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    state: State,
    config: ProtocolConfig,
    referral_fees: ReferralFees,
    positions: PositionManager,
    allowed_deepbook_pools: VecSet<ID>,
    extra_fields: VecMap<String, u64>,
}

// === Events ===
public struct MarginPoolCreated has copy, drop {
    margin_pool_id: ID,
    maintainer_cap_id: ID,
    asset_type: TypeName,
    config: ProtocolConfig,
    timestamp: u64,
}

public struct MaintainerFeesWithdrawn has copy, drop {
    margin_pool_id: ID,
    maintainer_cap_id: ID,
    maintainer_fees: u64,
    timestamp: u64,
}

public struct ProtocolFeesWithdrawn has copy, drop {
    margin_pool_id: ID,
    protocol_fees: u64,
    timestamp: u64,
}

public struct DeepbookPoolUpdated has copy, drop {
    margin_pool_id: ID,
    deepbook_pool_id: ID,
    pool_cap_id: ID,
    enabled: bool,
    timestamp: u64,
}

public struct InterestParamsUpdated has copy, drop {
    margin_pool_id: ID,
    pool_cap_id: ID,
    interest_config: InterestConfig,
    timestamp: u64,
}

public struct MarginPoolConfigUpdated has copy, drop {
    margin_pool_id: ID,
    pool_cap_id: ID,
    margin_pool_config: MarginPoolConfig,
    timestamp: u64,
}

public struct AssetSupplied has copy, drop {
    margin_pool_id: ID,
    asset_type: TypeName,
    supplier: address,
    supply_amount: u64,
    supply_shares: u64,
    timestamp: u64,
}

public struct AssetWithdrawn has copy, drop {
    margin_pool_id: ID,
    asset_type: TypeName,
    supplier: address,
    withdraw_amount: u64,
    withdraw_shares: u64,
    timestamp: u64,
}

// === Public Functions * ADMIN *===
/// Creates and registers a new margin pool. If a same asset pool already exists, abort.
/// Sends a `MarginPoolCap` to the pool creator. Returns the created margin pool id.
public fun create_margin_pool<Asset>(
    registry: &mut MarginRegistry,
    config: ProtocolConfig,
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
        config,
        referral_fees: referral_fees::default_referral_fees(ctx),
        positions: position_manager::create_position_manager(ctx),
        allowed_deepbook_pools: vec_set::empty(),
        extra_fields: vec_map::empty(),
    };
    transfer::share_object(margin_pool);

    let asset_type = type_name::with_defining_ids<Asset>();
    registry.register_margin_pool(asset_type, margin_pool_id, maintainer_cap, ctx);

    let maintainer_cap_id = maintainer_cap.maintainer_cap_id();
    event::emit(MarginPoolCreated {
        margin_pool_id,
        maintainer_cap_id,
        asset_type,
        config,
        timestamp: clock.timestamp_ms(),
    });

    margin_pool_id
}

/// Allow a margin manager tied to a deepbook pool to borrow from the margin pool.
public fun enable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
    clock: &Clock,
) {
    registry.load_inner();
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    assert!(!self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolAlreadyAllowed);
    self.allowed_deepbook_pools.insert(deepbook_pool_id);

    event::emit(DeepbookPoolUpdated {
        margin_pool_id: self.id(),
        pool_cap_id: margin_pool_cap.pool_cap_id(),
        deepbook_pool_id,
        enabled: true,
        timestamp: clock.timestamp_ms(),
    });
}

/// Disable a margin manager tied to a deepbook pool from borrowing from the margin pool.
public fun disable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    deepbook_pool_id: ID,
    margin_pool_cap: &MarginPoolCap,
    clock: &Clock,
) {
    registry.load_inner();
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    assert!(self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolNotAllowed);
    self.allowed_deepbook_pools.remove(&deepbook_pool_id);

    event::emit(DeepbookPoolUpdated {
        margin_pool_id: self.id(),
        pool_cap_id: margin_pool_cap.pool_cap_id(),
        deepbook_pool_id,
        enabled: false,
        timestamp: clock.timestamp_ms(),
    });
}

/// Updates interest params for the margin pool
public fun update_interest_params<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    interest_config: InterestConfig,
    margin_pool_cap: &MarginPoolCap,
    clock: &Clock,
) {
    registry.load_inner();
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    self.config.set_interest_config(interest_config);

    event::emit(InterestParamsUpdated {
        margin_pool_id: self.id(),
        pool_cap_id: margin_pool_cap.pool_cap_id(),
        interest_config,
        timestamp: clock.timestamp_ms(),
    });
}

/// Updates margin pool config
public fun update_margin_pool_config<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    margin_pool_config: MarginPoolConfig,
    margin_pool_cap: &MarginPoolCap,
    clock: &Clock,
) {
    registry.load_inner();
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);
    self.config.set_margin_pool_config(margin_pool_config);

    event::emit(MarginPoolConfigUpdated {
        margin_pool_id: self.id(),
        pool_cap_id: margin_pool_cap.pool_cap_id(),
        margin_pool_config,
        timestamp: clock.timestamp_ms(),
    });
}

// === Public Functions * LENDING * ===
/// Supply to the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    coin: Coin<Asset>,
    referral: Option<address>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    registry.load_inner();
    let user = ctx.sender();

    self.supply_inner(coin, referral, clock, user)
}

public fun supply_with_balance_manager<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    balance_manager: &mut BalanceManager,
    withdraw_cap: &WithdrawCap,
    amount: u64,
    referral: Option<address>,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    let user = balance_manager.id().to_address();
    let coin = balance_manager.withdraw_with_cap<Asset>(withdraw_cap, amount, ctx);

    self.supply_inner(coin, referral, clock, user)
}

/// Withdraw from the margin pool. Returns the withdrawn coin.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    let user = ctx.sender();

    self.withdraw_inner(amount, clock, user, ctx)
}

public fun withdraw_with_balance_manager<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    balance_manager: &mut BalanceManager,
    deposit_cap: &DepositCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    registry.load_inner();
    let user = balance_manager.id().to_address();
    let coin = self.withdraw_inner(option::some(amount), clock, user, ctx);
    let amount = coin.value();
    balance_manager.deposit_with_cap<Asset>(deposit_cap, coin, ctx);

    amount
}

/// Mint a supply referral.
public fun mint_supply_referral<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    ctx: &mut TxContext,
): ID {
    registry.load_inner();
    self.referral_fees.mint_supply_referral(ctx)
}

/// Withdraw the referral fees.
public fun withdraw_referral_fees<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    referral: &mut SupplyReferral,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    let referral_fees = self.referral_fees.calculate_and_claim(referral, ctx);
    let coin = self.vault.split(referral_fees).into_coin(ctx);

    coin
}

/// Withdraw the maintainer fees.
public fun withdraw_maintainer_fees<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    maintainer_cap: &MaintainerCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    registry.assert_maintainer_cap_valid(maintainer_cap);
    let maintainer_fees = self.referral_fees.claim_maintainer_fees();
    let coin = self.vault.split(maintainer_fees).into_coin(ctx);

    event::emit(MaintainerFeesWithdrawn {
        margin_pool_id: self.id(),
        maintainer_cap_id: maintainer_cap.maintainer_cap_id(),
        maintainer_fees,
        timestamp: clock.timestamp_ms(),
    });

    coin
}

/// Withdraw the protocol fees.
public fun withdraw_protocol_fees<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    _admin_cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    let protocol_fees = self.referral_fees.claim_protocol_fees();
    let coin = self.vault.split(protocol_fees).into_coin(ctx);

    event::emit(ProtocolFeesWithdrawn {
        margin_pool_id: self.id(),
        protocol_fees,
        timestamp: clock.timestamp_ms(),
    });

    coin
}

// === Public-View Functions ===
public fun deepbook_pool_allowed<Asset>(self: &MarginPool<Asset>, deepbook_pool_id: ID): bool {
    self.allowed_deepbook_pools.contains(&deepbook_pool_id)
}

public fun total_supply<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.total_supply()
}

public fun supply_shares<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.supply_shares()
}

public fun total_borrow<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.total_borrow()
}

public fun borrow_shares<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.borrow_shares()
}

public fun last_update_timestamp<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.last_update_timestamp()
}

public fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.supply_cap()
}

public fun max_utilization_rate<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.max_utilization_rate()
}

public fun referral_spread<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.referral_spread()
}

public fun min_borrow<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.min_borrow()
}

public fun interest_rate<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.interest_rate(self.state.utilization_rate())
}

// === Public-Package Functions ===
/// Allows borrowing from the margin pool. Returns the borrowed coin.
public(package) fun borrow<Asset>(
    self: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Asset>, u64, u64) {
    assert!(amount <= self.vault.value(), ENotEnoughAssetInPool);
    assert!(amount >= self.config.min_borrow(), EBorrowAmountTooLow);
    let (total_borrow, total_borrow_shares, referral_fees) = self
        .state
        .increase_borrow(&self.config, amount, clock);
    self.referral_fees.increase_fees_accrued(referral_fees);
    assert!(
        self.state.utilization_rate() <= self.config.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );

    (self.vault.split(amount).into_coin(ctx), total_borrow, total_borrow_shares)
}

public(package) fun repay<Asset>(
    self: &mut MarginPool<Asset>,
    shares: u64,
    coin: Coin<Asset>,
    clock: &Clock,
) {
    let (_, referral_fees) = self.state.decrease_borrow_shares(&self.config, shares, clock);
    self.referral_fees.increase_fees_accrued(referral_fees);

    self.vault.join(coin.into_balance());
}

// Repay a liquidation given some quantity of shares and a coin. If too much coin is given, then extra is used as reward.
// If not enough coin given, then the difference is recorded as default.
// Returns (applied amount repaid, reward given, and default recorded).
public(package) fun repay_liquidation<Asset>(
    self: &mut MarginPool<Asset>,
    shares: u64,
    coin: Coin<Asset>,
    clock: &Clock,
): (u64, u64, u64) {
    let (amount, referral_fees) = self.state.decrease_borrow_shares(&self.config, shares, clock); // decreased 48.545 shares, 97.087 USDC
    self.referral_fees.increase_fees_accrued(referral_fees);
    let coin_value = coin.value(); // 100 USDC
    let (reward, default) = if (coin_value > amount) {
        self.state.increase_supply_absolute(coin_value - amount);
        (coin_value - amount, 0)
    } else {
        self.state.decrease_supply_absolute(amount - coin_value);
        (0, amount - coin_value)
    };
    self.vault.join(coin.into_balance());

    (amount, reward, default)
}

public(package) fun borrow_shares_to_amount<Asset>(
    self: &MarginPool<Asset>,
    shares: u64,
    clock: &Clock,
): u64 {
    self.state.borrow_shares_to_amount(shares, &self.config, clock)
}

public(package) fun id<Asset>(self: &MarginPool<Asset>): ID {
    self.id.to_inner()
}

fun supply_inner<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    referral: Option<address>,
    clock: &Clock,
    user: address,
): u64 {
    let supply_amount = coin.value();
    let (supply_shares, referral_fees) = self
        .state
        .increase_supply(&self.config, supply_amount, clock);
    self.referral_fees.increase_fees_accrued(referral_fees);
    let (total_user_supply, previous_referral) = self
        .positions
        .increase_user_supply(referral, supply_shares, user);
    self.referral_fees.decrease_shares(previous_referral, total_user_supply - supply_shares);
    self.referral_fees.increase_shares(referral, total_user_supply);

    let balance = coin.into_balance();
    self.vault.join(balance);

    assert!(self.state.total_supply() <= self.config.supply_cap(), ESupplyCapExceeded);

    event::emit(AssetSupplied {
        margin_pool_id: self.id(),
        asset_type: type_name::with_defining_ids<Asset>(),
        supplier: user,
        supply_amount,
        supply_shares,
        timestamp: clock.timestamp_ms(),
    });

    total_user_supply
}

fun withdraw_inner<Asset>(
    self: &mut MarginPool<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    user: address,
    ctx: &mut TxContext,
): Coin<Asset> {
    let supplied_shares = self.positions.user_supply_shares(user);
    let supplied_amount = self.state.supply_shares_to_amount(supplied_shares, &self.config, clock);
    let withdraw_amount = amount.destroy_with_default(supplied_amount);
    let withdraw_shares = math::mul(supplied_shares, math::div(withdraw_amount, supplied_amount));

    let (_, referral_fees) = self
        .state
        .decrease_supply_shares(&self.config, withdraw_shares, clock);
    self.referral_fees.increase_fees_accrued(referral_fees);

    let (_, previous_referral) = self.positions.decrease_user_supply(withdraw_shares, user);
    self.referral_fees.decrease_shares(previous_referral, withdraw_shares);
    assert!(withdraw_amount <= self.vault.value(), ENotEnoughAssetInPool);
    let coin = self.vault.split(withdraw_amount).into_coin(ctx);

    event::emit(AssetWithdrawn {
        margin_pool_id: self.id(),
        asset_type: type_name::with_defining_ids<Asset>(),
        supplier: user,
        withdraw_amount,
        withdraw_shares,
        timestamp: clock.timestamp_ms(),
    });

    coin
}
