// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::{
    margin_state::{Self, State, InterestParams},
    position_manager::{Self, PositionManager},
    reward_manager::{Self, RewardManager}
};
use std::type_name::{Self, TypeName};
use sui::{bag::{Self, Bag}, balance::{Self, Balance}, clock::Clock, coin::Coin, event};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const ECannotRepayMoreThanLoan: u64 = 4;
const EMaxPoolBorrowPercentageExceeded: u64 = 5;
const EInvalidLoanQuantity: u64 = 6;
const EInvalidRepaymentQuantity: u64 = 7;
const EInvalidRewardEndTime: u64 = 8;

// === Structs ===
public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    state: State,
    positions: PositionManager,
    rewards: RewardManager,
    reward_balances: Bag,
}

public struct RepaymentProof<phantom Asset> {
    manager_id: ID,
    repay_amount: u64,
    pool_reward_amount: u64,
    in_default: bool,
}

public struct LoanDefault has copy, drop {
    pool_id: ID,
    manager_id: ID, // id of the margin manager
    loan_amount: u64, // amount of the loan that was defaulted
}

public struct PoolLiquidationReward has copy, drop {
    pool_id: ID,
    manager_id: ID, // id of the margin manager
    liquidation_reward: u64, // amount of the liquidation reward
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.update_state(clock);
    self.rewards.update(self.state.total_supply_shares(), clock);

    let supply_amount = coin.value();
    let supplier = ctx.sender();
    let supply_shares = self.state.to_supply_shares(supply_amount);
    let reward_pools = self.rewards.reward_pools();
    self.state.increase_total_supply(supply_amount);
    self.positions.increase_user_supply_shares(supplier, supply_shares, reward_pools);

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

/// Repays a loan for a margin manager being liquidated.
public fun verify_and_repay_liquidation<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    mut coin: Coin<Asset>,
    repayment_proof: RepaymentProof<Asset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        coin.value() == repayment_proof.repay_amount + repayment_proof.pool_reward_amount,
        EInvalidRepaymentQuantity,
    );

    let repay_coin = coin.split(repayment_proof.repay_amount, ctx);
    margin_pool.repay<Asset>(
        repayment_proof.manager_id,
        repay_coin,
        clock,
    );
    margin_pool.add_liquidation_reward(coin, repayment_proof.manager_id, clock);

    if (repayment_proof.in_default) {
        margin_pool.default_loan(repayment_proof.manager_id, clock);
    };

    let RepaymentProof {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        in_default: _,
    } = repayment_proof;
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

    let end_time_ms = end_time * 1000;
    assert!(end_time_ms > clock.timestamp_ms(), EInvalidRewardEndTime);
    let time_duration_seconds = (end_time_ms - clock.timestamp_ms()) / 1000;
    let rewards_per_second = math::div(total_emissions, time_duration_seconds);

    self.rewards.increase_emission(reward_token_type, end_time_ms, rewards_per_second);
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
    manager_id: ID,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    assert!(amount <= self.vault.value(), ENotEnoughAssetInPool);
    assert!(amount > 0, EInvalidLoanQuantity);

    self.update_state(clock);
    let borrow_shares = self.state.to_borrow_shares(amount);
    self.positions.increase_user_loan_shares(manager_id, borrow_shares);
    self.state.increase_total_borrow(amount);

    assert!(
        self.state.utilization_rate() <= self.state.max_utilization_rate(),
        EMaxPoolBorrowPercentageExceeded,
    );

    let balance = self.vault.split(amount);

    balance.into_coin(ctx)
}

/// Allows repaying the loan.
public(package) fun repay<Asset>(
    self: &mut MarginPool<Asset>,
    manager_id: ID,
    coin: Coin<Asset>,
    clock: &Clock,
) {
    self.state.update(clock);
    let repay_amount = coin.value();
    let repay_amount_shares = self.state.to_borrow_shares(repay_amount);
    assert!(
        repay_amount_shares <= self.positions.user_loan_shares(manager_id),
        ECannotRepayMoreThanLoan,
    );
    self.positions.decrease_user_loan_shares(manager_id, repay_amount_shares);
    self.state.decrease_total_borrow(repay_amount);

    let balance = coin.into_balance();
    self.vault.join(balance);
}

/// Marks a loan as defaulted.
public(package) fun default_loan<Asset>(
    self: &mut MarginPool<Asset>,
    manager_id: ID,
    clock: &Clock,
) {
    self.state.update(clock);
    let user_loan_shares = self.positions.user_loan_shares(manager_id);
    let user_loan_amount = self.state.to_borrow_amount(user_loan_shares);

    // No loan to default
    if (user_loan_shares == 0) {
        return
    };

    self.positions.decrease_user_loan_shares(manager_id, user_loan_shares);
    self.state.decrease_total_borrow(user_loan_amount);
    self.state.decrease_total_supply_with_index(user_loan_amount);

    event::emit(LoanDefault {
        pool_id: self.id.to_inner(),
        manager_id,
        loan_amount: user_loan_amount,
    });
}

/// Adds rewards in liquidation back to the protocol
public(package) fun add_liquidation_reward<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    manager_id: ID,
    clock: &Clock,
) {
    self.update_state(clock);
    let liquidation_reward = coin.value();
    self.state.increase_total_supply_with_index(liquidation_reward);
    self.vault.join(coin.into_balance());

    event::emit(PoolLiquidationReward {
        pool_id: self.id.to_inner(),
        manager_id,
        liquidation_reward,
    });
}

/// Creates a RepaymentProof object for the margin pool.
public(package) fun create_repayment_proof<Asset>(
    manager_id: ID,
    repay_amount: u64,
    pool_reward_amount: u64,
    in_default: bool,
): RepaymentProof<Asset> {
    RepaymentProof<Asset> {
        manager_id,
        repay_amount,
        pool_reward_amount,
        in_default,
    }
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

public(package) fun user_loan_amount<Asset>(
    self: &mut MarginPool<Asset>,
    manager_id: ID,
    clock: &Clock,
): u64 {
    self.update_state(clock);
    let loan_shares = self.positions.user_loan_shares(manager_id);
    self.state.to_borrow_amount(loan_shares)
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
