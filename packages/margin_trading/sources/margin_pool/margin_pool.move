// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::{
    margin_state::{Self, State, InterestParams},
    position_manager::{Self, PositionManager},
    referral_manager::{Self, ReferralManager, ReferralCap},
    reward_manager::{Self, RewardManager}
};
use std::type_name::{Self, TypeName};
use sui::{
    bag::{Self, Bag},
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    vec_set::{Self, VecSet}
};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const EMaxPoolBorrowPercentageExceeded: u64 = 4;
const EInvalidLoanQuantity: u64 = 5;
const EInvalidRewardEndTime: u64 = 8;
const EDeepbookPoolAlreadyAllowed: u64 = 9;
const EDeepbookPoolNotAllowed: u64 = 10;

// === Structs ===
public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    state: State,
    positions: PositionManager,
    rewards: RewardManager,
    referral_manager: ReferralManager,
    reward_balances: Bag,
    allowed_deepbook_pools: VecSet<ID>,
}

public struct RepayReceipt has drop {
    repaid_amount: u64,
    reward_amount: u64,
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
    self.rewards.update(self.state.total_supply_shares(), clock);

    let supplier = ctx.sender();
    let (referred_supply_shares, previous_referral) = self
        .positions
        .reset_referral_supply_shares(supplier);
    self
        .referral_manager
        .decrease_referral_supply_shares(previous_referral, referred_supply_shares);

    let supply_amount = coin.value();
    let supply_shares = self.state.to_supply_shares(supply_amount);
    let reward_pools = self.rewards.reward_pools();
    self.state.increase_total_supply(supply_amount);
    let new_supply_shares = self
        .positions
        .increase_user_supply_shares(supplier, supply_shares, reward_pools);
    self.referral_manager.increase_referral_supply_shares(referral, new_supply_shares);

    let balance = coin.into_balance();
    self.vault.join(balance);

    assert!(self.state.total_supply() <= self.state.supply_cap(), ESupplyCapExceeded);
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    self.update_state(clock);
    self.rewards.update(self.state.total_supply_shares(), clock);

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
    let reward_pools = self.rewards.reward_pools();
    assert!(withdrawal_amount_shares <= user_supply_shares, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= self.vault.value(), ENotEnoughAssetInPool);

    self.state.decrease_total_supply(withdrawal_amount);
    self.positions.decrease_user_supply_shares(supplier, withdrawal_amount_shares, reward_pools);

    self.vault.split(withdrawal_amount).into_coin(ctx)
}

public(package) fun mint_referral_cap<Asset>(
    self: &mut MarginPool<Asset>,
    ctx: &mut TxContext,
): ReferralCap {
    let current_index = self.state.supply_index();
    self.referral_manager.mint_referral_cap(current_index, ctx)
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
    let reward_amount = math::mul(share_value_appreciated, self.state.protocol_spread());
    self.state.reduce_protocol_profit(reward_amount);

    self.vault.split(reward_amount).into_coin(ctx)
}

// === Public-View Functions ===
public fun deepbook_pool_allowed<Asset>(self: &MarginPool<Asset>, deepbook_pool_id: ID): bool {
    self.allowed_deepbook_pools.contains(&deepbook_pool_id)
}

// === Public-Package Functions ===
/// Creates a margin pool as the admin.
public(package) fun create_margin_pool<Asset>(
    interest_params: InterestParams,
    supply_cap: u64,
    max_borrow_percentage: u64,
    protocol_spread: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let margin_pool = MarginPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        state: margin_state::default(
            interest_params,
            supply_cap,
            max_borrow_percentage,
            protocol_spread,
            clock,
        ),
        positions: position_manager::create_position_manager(ctx),
        rewards: reward_manager::create_reward_manager(clock),
        reward_balances: bag::new(ctx),
        referral_manager: referral_manager::empty(),
        allowed_deepbook_pools: vec_set::empty(),
    };
    let margin_pool_id = margin_pool.id.to_inner();
    transfer::share_object(margin_pool);

    margin_pool_id
}

public(package) fun update_state<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    self.state.update(clock);
}

/// Updates the supply cap for the margin pool.
public(package) fun update_supply_cap<Asset>(self: &mut MarginPool<Asset>, supply_cap: u64) {
    self.state.set_supply_cap(supply_cap);
}

/// Updates the maximum borrow percentage for the margin pool.
public(package) fun update_max_utilization_rate<Asset>(
    self: &mut MarginPool<Asset>,
    max_utilization_rate: u64,
) {
    self.state.set_max_utilization_rate(max_utilization_rate);
}

/// Updates the interest parameters for the margin pool.
public(package) fun update_interest_params<Asset>(
    self: &mut MarginPool<Asset>,
    interest_params: InterestParams,
    clock: &Clock,
) {
    self.state.update_interest_params(interest_params, clock);
}

public(package) fun enable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
) {
    assert!(!self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolAlreadyAllowed);
    self.allowed_deepbook_pools.insert(deepbook_pool_id);
}

public(package) fun disable_deepbook_pool_for_loan<Asset>(
    self: &mut MarginPool<Asset>,
    deepbook_pool_id: ID,
) {
    assert!(self.allowed_deepbook_pools.contains(&deepbook_pool_id), EDeepbookPoolNotAllowed);
    self.allowed_deepbook_pools.remove(&deepbook_pool_id);
}

/// Adds a reward token to be distributed linearly over a specified time period.
/// If a reward pool for the same token type already exists, adds the new rewards
/// to the existing pool and resets the timing to end at the specified time.
public(package) fun add_reward_pool<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    reward_coin: Coin<RewardToken>,
    end_time: u64,
    clock: &Clock,
) {
    let reward_token_type = type_name::get<RewardToken>();
    self.rewards.add_reward_pool_entry(reward_token_type);
    let remaining_emissions = self.rewards.remaining_emission_for_type(reward_token_type, clock);
    let total_emissions = remaining_emissions + reward_coin.value();

    assert!(end_time > clock.timestamp_ms(), EInvalidRewardEndTime);
    let time_duration_seconds = (end_time - clock.timestamp_ms()) / 1000;
    let rewards_per_second = math::div(total_emissions, time_duration_seconds);

    self.rewards.increase_emission(reward_token_type, end_time, rewards_per_second);
    add_reward_balance_to_bag(&mut self.reward_balances, reward_coin);
}

/// Allows users to claim their accumulated rewards for a specific reward token type.
/// Claims from all active reward pools of that token type.
public(package) fun claim_rewards<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RewardToken> {
    let user = ctx.sender();
    self.rewards.update(self.state.total_supply_shares(), clock);

    let user_shares = self.positions.user_supply_shares(user);
    let reward_token_type = type_name::get<RewardToken>();
    let reward_pools = self.rewards.reward_pools();
    let user_rewards = self
        .positions
        .reset_user_rewards_for_type(user, reward_token_type, reward_pools, user_shares);
    let claimed_balance = withdraw_reward_balance_from_bag(&mut self.reward_balances, user_rewards);

    claimed_balance.into_coin(ctx)
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
        self.state.utilization_rate() <= self.state.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let balance = self.vault.split(amount);

    balance.into_coin(ctx)
}

/// Allows repaying the loan.
public(package) fun repay<Asset>(self: &mut MarginPool<Asset>, coin: Coin<Asset>, clock: &Clock) {
    self.state.update(clock);
    self.state.decrease_total_borrow(coin.value());
    self.vault.join(coin.into_balance());
}

public(package) fun repay_with_reward<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    reward: Coin<Asset>,
    default_amount: u64,
    clock: &Clock,
): RepayReceipt {
    self.update_state(clock);
    let coin_value = coin.value();
    let reward_value = reward.value();
    self.state.decrease_total_borrow(coin_value);
    self.state.increase_total_supply_with_index(reward_value);
    self.state.decrease_total_supply(default_amount);
    self.vault.join(coin.into_balance());
    self.vault.join(reward.into_balance());

    RepayReceipt {
        repaid_amount: coin_value,
        reward_amount: reward_value,
    }
}

public(package) fun paid_amount(repay_receipt: &RepayReceipt): u64 {
    repay_receipt.repaid_amount
}

public(package) fun reward_amount(repay_receipt: &RepayReceipt): u64 {
    repay_receipt.reward_amount
}

/// Updates the protocol spread
public(package) fun update_margin_pool_spread<Asset>(
    self: &mut MarginPool<Asset>,
    protocol_spread: u64,
    clock: &Clock,
) {
    self.state.update_margin_pool_spread(protocol_spread, clock);
}

/// Resets the protocol profit and returns the coin.
public(package) fun withdraw_protocol_profit<Asset>(
    self: &mut MarginPool<Asset>,
    ctx: &mut TxContext,
): Coin<Asset> {
    let profit = self.state.reset_protocol_profit();
    let balance = self.vault.split(profit);

    balance.into_coin(ctx)
}

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.supply_cap()
}

/// Returns the state.
public(package) fun state<Asset>(self: &MarginPool<Asset>): &State {
    &self.state
}

public fun id<Asset>(self: &MarginPool<Asset>): ID {
    self.id.to_inner()
}

// === Internal Functions ===
fun add_reward_balance_to_bag<RewardToken>(
    reward_balances: &mut Bag,
    reward_coin: Coin<RewardToken>,
) {
    let reward_type = type_name::get<RewardToken>();
    if (reward_balances.contains(reward_type)) {
        let existing_balance: &mut Balance<RewardToken> = reward_balances.borrow_mut<
            TypeName,
            Balance<RewardToken>,
        >(reward_type);
        existing_balance.join(reward_coin.into_balance());
    } else {
        reward_balances.add(reward_type, reward_coin.into_balance());
    };
}

fun withdraw_reward_balance_from_bag<RewardToken>(
    reward_balances: &mut Bag,
    amount: u64,
): Balance<RewardToken> {
    let reward_type = type_name::get<RewardToken>();
    let balance: &mut Balance<RewardToken> = reward_balances.borrow_mut(reward_type);
    balance::split(balance, amount)
}
