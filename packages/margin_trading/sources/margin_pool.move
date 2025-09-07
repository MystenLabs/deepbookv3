// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::constants;
use margin_trading::{
    margin_registry::{MarginRegistry, MaintainerCap, MarginPoolCap},
    margin_state::{Self, State},
    position_manager::{Self, PositionManager},
    protocol_config::{InterestConfig, MarginPoolConfig, ProtocolConfig}
};
use std::type_name::{Self, TypeName};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, event, vec_set::{Self, VecSet}};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const EMaxPoolBorrowPercentageExceeded: u64 = 4;
const EInvalidLoanQuantity: u64 = 5;
const EDeepbookPoolAlreadyAllowed: u64 = 6;
const EDeepbookPoolNotAllowed: u64 = 7;
const EInvalidMarginPoolCap: u64 = 8;
const EBorrowAmountTooLow: u64 = 9;
const EInvalidRepayQuantity: u64 = 10;

// === Structs ===
public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    state: State,
    config: ProtocolConfig,
    protocol_profit: u64,
    positions: PositionManager,
    allowed_deepbook_pools: VecSet<ID>,
}

// === Events ===
public struct MarginPoolCreated has copy, drop {
    margin_pool_id: ID,
    maintainer_cap_id: ID,
    asset_type: TypeName,
    config: ProtocolConfig,
    timestamp: u64,
}

public struct DeepbookPoolEnabled has copy, drop {
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

public struct ProtocolProfitWithdrawn has copy, drop {
    margin_pool_id: ID,
    pool_cap_id: ID,
    asset_type: TypeName,
    profit: u64,
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
    withdrawal_amount: u64,
    withdrawal_shares: u64,
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
        protocol_profit: 0,
        positions: position_manager::create_position_manager(ctx),
        allowed_deepbook_pools: vec_set::empty(),
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

    event::emit(DeepbookPoolEnabled {
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

    event::emit(DeepbookPoolEnabled {
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

/// Resets the protocol profit and returns the coin.
public fun withdraw_protocol_profit<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    margin_pool_cap: &MarginPoolCap,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    assert!(margin_pool_cap.margin_pool_id() == self.id(), EInvalidMarginPoolCap);

    let profit = self.protocol_profit;
    self.protocol_profit = 0;
    let balance = self.vault.split(profit);

    let coin = balance.into_coin(ctx);

    event::emit(ProtocolProfitWithdrawn {
        margin_pool_id: self.id(),
        pool_cap_id: margin_pool_cap.pool_cap_id(),
        asset_type: type_name::with_defining_ids<Asset>(),
        profit,
        timestamp: clock.timestamp_ms(),
    });

    coin
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    registry.load_inner();
    let supplier = ctx.sender();
    let supply_amount = coin.value();

    let supply_shares = self.state.increase_supply(&self.config, supply_amount, clock);
    self.positions.increase_user_supply(supplier, supply_shares);

    let balance = coin.into_balance();
    self.vault.join(balance);

    assert!(self.state.supply() <= self.config.supply_cap(), ESupplyCapExceeded);

    event::emit(AssetSupplied {
        margin_pool_id: self.id(),
        asset_type: type_name::with_defining_ids<Asset>(),
        supplier,
        supply_amount,
        supply_shares,
        timestamp: clock.timestamp_ms(),
    });
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    registry: &MarginRegistry,
    percentage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    registry.load_inner();
    let supplier = ctx.sender();
    let percentage = percentage.min(constants::float_scaling());
    let withdrawal_shares = self.positions.decrease_user_supply(supplier, percentage);
    let withdrawal_amount = self
        .state
        .decrease_supply_shares(&self.config, withdrawal_shares, clock);

    let coin = self.vault.split(withdrawal_amount).into_coin(ctx);

    event::emit(AssetWithdrawn {
        margin_pool_id: self.id(),
        asset_type: type_name::with_defining_ids<Asset>(),
        supplier,
        withdrawal_amount,
        withdrawal_shares,
        timestamp: clock.timestamp_ms(),
    });

    coin
}

// === Public-View Functions ===
public fun deepbook_pool_allowed<Asset>(self: &MarginPool<Asset>, deepbook_pool_id: ID): bool {
    self.allowed_deepbook_pools.contains(&deepbook_pool_id)
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
    assert!(
        self.state.utilization_rate() <= self.config.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );
    assert!(amount >= self.config.min_borrow(), EBorrowAmountTooLow);

    let (total_borrow, total_borrow_shares) = self
        .state
        .increase_borrow(&self.config, amount, clock);

    (self.vault.split(amount).into_coin(ctx), total_borrow, total_borrow_shares)
}

public(package) fun repay<Asset>(
    self: &mut MarginPool<Asset>,
    shares: u64,
    coin: Coin<Asset>,
    clock: &Clock,
) {
    let amount = self.state.decrease_borrow_shares(&self.config, shares, clock);
    assert!(coin.value() == amount, EInvalidRepayQuantity);
    self.vault.join(coin.into_balance());
}

public(package) fun repay_liquidation<Asset>(
    self: &mut MarginPool<Asset>,
    shares: u64,
    coin: Coin<Asset>,
    clock: &Clock,
): (u64, u64, u64) {
    let amount = self.state.decrease_borrow_shares(&self.config, shares, clock);
    let coin_value = coin.value();
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

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.config.supply_cap()
}

public(package) fun id<Asset>(self: &MarginPool<Asset>): ID {
    self.id.to_inner()
}
