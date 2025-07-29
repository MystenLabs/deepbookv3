// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::margin_state::{Self, State};
use std::type_name::{Self, TypeName};
use sui::{
    balance::{Self, Balance}, 
    clock::Clock, 
    coin::Coin, 
    event, 
    table::{Self, Table},
    bag::{Self, Bag},
    vec_map::{Self, VecMap}
};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const ECannotRepayMoreThanLoan: u64 = 4;
const EMaxPoolBorrowPercentageExceeded: u64 = 5;
const EInvalidLoanQuantity: u64 = 6;
const EInvalidRepaymentQuantity: u64 = 7;
const ERewardPoolNotFound: u64 = 8;
const EInvalidRewardPeriod: u64 = 10;
const ERewardAmountTooSmall: u64 = 11;
const ERewardPeriodTooShort: u64 = 12;

// === Reward Constraints ===
const MIN_REWARD_AMOUNT: u64 = 1000;
const MIN_REWARD_DURATION_MS: u64 = 3_600_000;
/// Precision scaling for cumulative_reward_per_share calculations
/// Using 9 decimals to match most tokens 
const SCALING_FACTOR: u64 = 1_000_000_000;

// === Structs ===
public struct Loan has drop, store {
    loan_amount: u64, // total loan remaining, including interest
    last_index: u64, // 9 decimals
}

public struct Supply has drop, store {
    supplied_amount: u64, // amount supplied in this transaction
    last_index: u64, // 9 decimals
}

public struct RewardPool has store {
    id: ID, // unique identifier for this reward pool instance
    reward_balance: Bag, // stores Balance<T> for arbitrary token types
    total_rewards: u64, // total reward amount for this pool
    start_time: u64, // when rewards start distributing (ms)
    end_time: u64, // when rewards stop distributing (ms)
    reward_per_ms: u64, // reward distributed per millisecond
    cumulative_reward_per_share: u64, // scaled by SCALING_FACTOR for precision
    last_update_time: u64, // last time this pool was updated
    type_name: TypeName, // type of reward token
}

public struct UserRewards has store {
    accumulated_rewards: VecMap<ID, u64>, // tracks user's accumulated rewards per reward pool ID
}

public struct PoolData has drop {
    pool_id: ID,
    cumulative_reward_per_share: u64,
}

public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    supplies: Table<address, Supply>, // maps address id to deposits
    supply_cap: u64, // maximum amount of assets that can be supplied to the pool
    max_borrow_percentage: u64, // maximum percentage of borrowable assets in the pool
    state: State,
    reward_pools: VecMap<TypeName, vector<RewardPool>>, // maps reward token type to list of reward pools
    user_rewards: Table<address, UserRewards>, // maps user address to their reward tracking
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

public struct RewardPoolAdded has copy, drop {
    pool_id: ID,
    reward_pool_id: ID,
    reward_type: TypeName,
    total_rewards: u64,
    start_time: u64,
    end_time: u64,
}

public struct RewardsClaimed has copy, drop {
    pool_id: ID,
    user: address,
    reward_type: TypeName,
    amount: u64,
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let supplier = ctx.sender();
    let supply_amount = coin.value();
    
    // Update rewards before changing user's share
    self.update_all_reward_pools(clock);
    self.update_user_rewards(supplier, clock, ctx);
    
    let old_user_supply = self.user_supply(supplier, clock);
    self.increase_user_supply(supplier, supply_amount);
    self.state.increase_total_supply(supply_amount);
    let balance = coin.into_balance();
    self.vault.join(balance);

    // Update user accumulated rewards after supply change
    let new_user_supply = old_user_supply + supply_amount;
    self.update_user_accumulated_rewards(supplier, new_user_supply, ctx);

    assert!(self.state.total_supply() <= self.supply_cap, ESupplyCapExceeded);
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw<Asset>(
    self: &mut MarginPool<Asset>,
    amount: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    let supplier = ctx.sender();
    
    // Update rewards before changing user's share
    self.update_all_reward_pools(clock);
    self.update_user_rewards(supplier, clock, ctx);
    
    let user_supply = self.user_supply(supplier, clock);
    let withdrawal_amount = amount.get_with_default(user_supply);
    assert!(withdrawal_amount <= user_supply, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= self.vault.value(), ENotEnoughAssetInPool);
    self.decrease_user_supply(ctx.sender(), withdrawal_amount);
    self.state.decrease_total_supply(withdrawal_amount);

    // Update user accumulated rewards after withdrawal
    let new_user_supply = user_supply - withdrawal_amount;
    self.update_user_accumulated_rewards(supplier, new_user_supply, ctx);

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
    supply_cap: u64,
    max_borrow_percentage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): MarginPool<Asset> {
    let margin_pool = MarginPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        loans: table::new(ctx),
        supplies: table::new(ctx),
        supply_cap,
        max_borrow_percentage,
        state: margin_state::default(clock),
        reward_pools: vec_map::empty(),
        user_rewards: table::new(ctx),
    };

    margin_pool
}

/// Updates the supply cap for the margin pool.
public(package) fun update_supply_cap<Asset>(self: &mut MarginPool<Asset>, supply_cap: u64) {
    self.supply_cap = supply_cap;
}

/// Updates the maximum borrow percentage for the margin pool.
public(package) fun update_max_borrow_percentage<Asset>(
    self: &mut MarginPool<Asset>,
    max_borrow_percentage: u64,
) {
    self.max_borrow_percentage = max_borrow_percentage;
}

/// Adds a reward token to be distributed linearly over a specified time period.
public(package) fun add_reward_pool<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    reward_coin: Coin<RewardToken>,
    start_time: u64,
    end_time: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(start_time < end_time, EInvalidRewardPeriod);
    assert!(end_time > clock.timestamp_ms(), EInvalidRewardPeriod);
    
    let reward_amount = reward_coin.value();
    let duration = end_time - start_time;
    
    assert!(reward_amount >= MIN_REWARD_AMOUNT, ERewardAmountTooSmall);
    assert!(duration >= MIN_REWARD_DURATION_MS, ERewardPeriodTooShort);
    
    let reward_per_ms = (reward_amount * SCALING_FACTOR) / duration;
    let reward_type = type_name::get<RewardToken>();
    self.update_all_reward_pools(clock);

    let uid = object::new(ctx);
    let reward_pool_id = uid.to_inner();
    uid.delete();
    
    let mut reward_pool = RewardPool {
        id: reward_pool_id,
        reward_balance: bag::new(ctx),
        total_rewards: reward_amount,
        start_time,
        end_time,
        reward_per_ms,
        cumulative_reward_per_share: 0,
        last_update_time: start_time.max(clock.timestamp_ms()),
        type_name: reward_type,
    };
    
    let reward_balance = reward_coin.into_balance();
    reward_pool.reward_balance.add(reward_type, reward_balance);
    
    if (self.reward_pools.contains(&reward_type)) {
        let pools = self.reward_pools.get_mut(&reward_type);
        pools.push_back(reward_pool);
    } else {
        let mut pools = vector[];
        pools.push_back(reward_pool);
        self.reward_pools.insert(reward_type, pools);
    };
    
    event::emit(RewardPoolAdded {
        pool_id: self.id.to_inner(),
        reward_pool_id,
        reward_type,
        total_rewards: reward_amount,
        start_time,
        end_time,
    });
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
    self.user_loan(manager_id, clock);
    self.increase_user_loan(manager_id, amount);

    self.state.increase_total_borrow(amount);

    let borrow_percentage = math::div(
        self.state.total_borrow(),
        self.state.total_supply(),
    );

    assert!(borrow_percentage <= self.max_borrow_percentage, EMaxPoolBorrowPercentageExceeded);

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
    let repay_amount = coin.value();
    let user_loan = self.user_loan(manager_id, clock);
    assert!(repay_amount <= user_loan, ECannotRepayMoreThanLoan);
    self.decrease_user_loan(manager_id, repay_amount);
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
    let user_loan = self.user_loan(manager_id, clock);

    // No loan to default
    if (user_loan == 0) {
        return
    };

    self.decrease_user_loan(manager_id, user_loan);
    self.state.decrease_total_borrow(user_loan);

    let total_supply = self.state.total_supply();
    let new_supply = total_supply - user_loan;
    let new_supply_index = math::mul(
        self.state.supply_index(),
        math::div(new_supply, total_supply),
    );

    self.state.decrease_total_supply(user_loan);
    self.state.set_supply_index(new_supply_index);

    event::emit(LoanDefault {
        pool_id: self.id.to_inner(),
        manager_id,
        loan_amount: user_loan,
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
    let current_supply = self.state.total_supply();
    let new_supply = current_supply + liquidation_reward;
    let new_supply_index = math::mul(
        self.state.supply_index(),
        math::div(new_supply, current_supply),
    );

    self.state.increase_total_supply(liquidation_reward);
    self.state.set_supply_index(new_supply_index);
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

public(package) fun user_loan<Asset>(
    self: &mut MarginPool<Asset>,
    manager_id: ID,
    clock: &Clock,
): u64 {
    self.update_state(clock);
    self.update_user_loan(manager_id);

    self.loans.borrow(manager_id).loan_amount
}

/// Returns the loans table.
public(package) fun loans<Asset>(self: &MarginPool<Asset>): &Table<ID, Loan> {
    &self.loans
}

/// Returns the supplies table.
public(package) fun supplies<Asset>(self: &MarginPool<Asset>): &Table<address, Supply> {
    &self.supplies
}

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.supply_cap
}

/// Returns the state.
public(package) fun state<Asset>(self: &MarginPool<Asset>): &State {
    &self.state
}

/// Allows users to claim their accumulated rewards for a specific reward token.
/// Claims from all pools of that token type.
public fun claim_rewards<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RewardToken> {
    let user = ctx.sender();
    let reward_type = type_name::get<RewardToken>();
    
    // Update reward pools first
    self.update_all_reward_pools(clock);
    
    assert!(self.reward_pools.contains(&reward_type), ERewardPoolNotFound);
    
    // Get user's current supply amount
    let user_supply_amount = self.user_supply(user, clock);
    
    // Calculate total pending rewards across all pools of this type BEFORE updating user debt
    let pending_rewards = self.calculate_pending_rewards_for_type(
        user,
        reward_type,
        user_supply_amount,
    );
    
    
    if (pending_rewards == 0) {
        return balance::zero<RewardToken>().into_coin(ctx)
    };
    
    // Update user's accumulated rewards for all pools of this type
    // First collect the pool data to avoid borrowing conflicts
    let pools = self.reward_pools.get(&reward_type);
    let pool_data = vector::tabulate!(pools.length(), |pool_idx| {
        let reward_pool = pools.borrow(pool_idx);
        PoolData {
            pool_id: reward_pool.id,
            cumulative_reward_per_share: reward_pool.cumulative_reward_per_share
        }
    });
    
    // Transfer rewards from pools to user BEFORE updating user's accumulated rewards
    let mut total_claimed_balance = balance::zero<RewardToken>();
    let pools_mut = self.reward_pools.get_mut(&reward_type);
    let user_rewards = self.user_rewards.borrow(user);
    
    // Calculate pending rewards for each pool
    pools_mut.length().do!(|pool_idx| {
        let reward_pool = pools_mut.borrow_mut(pool_idx);
        let pool_id = reward_pool.id;
        let reward_balance: &mut Balance<RewardToken> = reward_pool.reward_balance.borrow_mut(reward_type);
        
        let pool_rewards = ((user_supply_amount as u128) * (reward_pool.cumulative_reward_per_share as u128) / (SCALING_FACTOR as u128)) as u64;
        
        let user_accumulated = if (user_rewards.accumulated_rewards.contains(&pool_id)) {
            *user_rewards.accumulated_rewards.get(&pool_id)
        } else {
            0
        };
        
        let pool_pending = if (pool_rewards > user_accumulated) {
            pool_rewards - user_accumulated
        } else {
            0
        };
        
        if (pool_pending > 0 && reward_balance.value() >= pool_pending) {
            let claimed_from_pool = reward_balance.split(pool_pending);
            total_claimed_balance.join(claimed_from_pool);
        };
    });
    
    // Update user's accumulated rewards for each pool
    pool_data.do_ref!(|data| {
        self.update_user_accumulated_rewards_for_pool(user, data.pool_id, data.cumulative_reward_per_share, user_supply_amount);
    });
    
    event::emit(RewardsClaimed {
        pool_id: self.id.to_inner(),
        user,
        reward_type,
        amount: total_claimed_balance.value(),
    });
    
    total_claimed_balance.into_coin(ctx)
}

// === Internal Functions ===
/// Updates the state
fun update_state<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    self.state.update(clock);
}

/// Updates user's supply to include interest earned, supply index, and total supply. Returns Supply.
fun update_user_supply<Asset>(self: &mut MarginPool<Asset>, supplier: address) {
    self.add_user_supply_entry(supplier);

    let supply = self.supplies.borrow_mut(supplier);
    let current_index = self.state.supply_index();
    let interest_multiplier = math::div(
        current_index,
        supply.last_index,
    );
    let new_supply_amount = math::mul(
        supply.supplied_amount,
        interest_multiplier,
    );
    supply.supplied_amount = new_supply_amount;
    supply.last_index = current_index;
}

fun increase_user_supply<Asset>(self: &mut MarginPool<Asset>, supplier: address, amount: u64) {
    let supply = self.supplies.borrow_mut(supplier);
    supply.supplied_amount = supply.supplied_amount + amount;
}

fun decrease_user_supply<Asset>(self: &mut MarginPool<Asset>, supplier: address, amount: u64) {
    let supply = self.supplies.borrow_mut(supplier);
    supply.supplied_amount = supply.supplied_amount - amount;
}

fun add_user_supply_entry<Asset>(self: &mut MarginPool<Asset>, supplier: address) {
    if (self.supplies.contains(supplier)) {
        return
    };
    let current_index = self.state.supply_index();
    let supply = Supply {
        supplied_amount: 0,
        last_index: current_index,
    };
    self.supplies.add(supplier, supply);
}

fun user_supply<Asset>(self: &mut MarginPool<Asset>, supplier: address, clock: &Clock): u64 {
    self.update_state(clock);
    self.update_user_supply(supplier);

    self.supplies.borrow(supplier).supplied_amount
}

fun update_user_loan<Asset>(self: &mut MarginPool<Asset>, manager_id: ID) {
    self.add_user_loan_entry(manager_id);

    let loan = self.loans.borrow_mut(manager_id);
    let current_index = self.state.borrow_index();
    let interest_multiplier = math::div(
        current_index,
        loan.last_index,
    );
    let new_loan_amount = math::mul(
        loan.loan_amount,
        interest_multiplier,
    );
    loan.loan_amount = new_loan_amount;
    loan.last_index = current_index;
}

fun increase_user_loan<Asset>(self: &mut MarginPool<Asset>, manager_id: ID, amount: u64) {
    let loan = self.loans.borrow_mut(manager_id);
    loan.loan_amount = loan.loan_amount + amount;
}

fun decrease_user_loan<Asset>(self: &mut MarginPool<Asset>, manager_id: ID, amount: u64) {
    let loan = self.loans.borrow_mut(manager_id);
    loan.loan_amount = loan.loan_amount - amount;
}

fun add_user_loan_entry<Asset>(self: &mut MarginPool<Asset>, manager_id: ID) {
    if (self.loans.contains(manager_id)) {
        return
    };
    let current_index = self.state.borrow_index();
    let loan = Loan {
        loan_amount: 0,
        last_index: current_index,
    };
    self.loans.add(manager_id, loan);
}

// === Reward Functions ===

/// Updates all active reward pools to the current time.
fun update_all_reward_pools<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let total_supply = self.state.total_supply();
    
    if (total_supply == 0) {
        return // No shares to distribute rewards to
    };
    
    let reward_types = vector::tabulate!(self.reward_pools.size(), |i| {
        let (key, _) = self.reward_pools.get_entry_by_idx(i);
        *key
    });
    
    reward_types.do_ref!(|reward_type| {
        let pools = self.reward_pools.get_mut(reward_type);
        
        // Update each pool for this reward type
        pools.length().do!(|pool_idx| {
            let reward_pool = pools.borrow_mut(pool_idx);
            
            if (current_time > reward_pool.last_update_time && current_time >= reward_pool.start_time) {
                let end_time = reward_pool.end_time.min(current_time);
                let time_elapsed = end_time - reward_pool.last_update_time;
                
                if (time_elapsed > 0) {
                    // reward_per_ms is already scaled by SCALING_FACTOR, so we need to account for that
                    let scaled_rewards_to_distribute = reward_pool.reward_per_ms * time_elapsed;
                    // Divide by SCALING_FACTOR to get actual rewards, then scale again for per-share calculation
                    let rewards_to_distribute = scaled_rewards_to_distribute / SCALING_FACTOR;
                    let reward_per_share = ((rewards_to_distribute as u128) * (SCALING_FACTOR as u128) / (total_supply as u128)) as u64;
                    
                    reward_pool.cumulative_reward_per_share = reward_pool.cumulative_reward_per_share + reward_per_share;
                    reward_pool.last_update_time = end_time;
                };
            };
        });
    });
}

/// Updates a user's reward tracking for all reward pools.
fun update_user_rewards<Asset>(self: &mut MarginPool<Asset>, user: address, clock: &Clock, ctx: &mut TxContext) {
    self.add_user_rewards_entry(user, ctx);
    
    let user_supply_amount = self.user_supply(user, clock);
    self.update_user_accumulated_rewards(user, user_supply_amount, ctx);
}

/// Updates a user's accumulated rewards for all active reward pools.
fun update_user_accumulated_rewards<Asset>(self: &mut MarginPool<Asset>, user: address, user_supply: u64, ctx: &mut TxContext) {
    self.add_user_rewards_entry(user, ctx);
    
    let reward_types = vector::tabulate!(self.reward_pools.size(), |i| {
        let (key, _) = self.reward_pools.get_entry_by_idx(i);
        *key
    });
    
    // Update accumulated rewards for each pool ID across all reward types
    // First collect all pool data to avoid borrowing conflicts
    let all_pool_data = reward_types.fold!(vector[], |mut acc, reward_type| {
        let pools = self.reward_pools.get(&reward_type);
        let pool_data = vector::tabulate!(pools.length(), |pool_idx| {
            let reward_pool = pools.borrow(pool_idx);
            PoolData {
                pool_id: reward_pool.id,
                cumulative_reward_per_share: reward_pool.cumulative_reward_per_share
            }
        });
        acc.append(pool_data);
        acc
    });
    
    // Now update accumulated rewards without borrowing conflicts
    all_pool_data.do_ref!(|data| {
        self.update_user_accumulated_rewards_for_pool(user, data.pool_id, data.cumulative_reward_per_share, user_supply);
    });
}

/// Updates a user's accumulated rewards for a specific reward pool.
fun update_user_accumulated_rewards_for_pool<Asset>(
    self: &mut MarginPool<Asset>, 
    user: address, 
    pool_id: ID, 
    cumulative_reward_per_share: u64,
    user_supply: u64
) {
    let user_rewards = self.user_rewards.borrow_mut(user);
    
    // Calculate: (user_supply * cumulative_reward_per_share) / SCALING_FACTOR
    let new_accumulated = ((user_supply as u128) * (cumulative_reward_per_share as u128) / (SCALING_FACTOR as u128)) as u64;
    
    if (user_rewards.accumulated_rewards.contains(&pool_id)) {
        *user_rewards.accumulated_rewards.get_mut(&pool_id) = new_accumulated;
    } else {
        user_rewards.accumulated_rewards.insert(pool_id, new_accumulated);
    };
}

/// Calculates pending rewards for a user for a specific reward type across all pools.
fun calculate_pending_rewards_for_type<Asset>(
    self: &MarginPool<Asset>,
    user: address,
    reward_type: TypeName,
    user_supply: u64,
): u64 {
    if (!self.user_rewards.contains(user) || !self.reward_pools.contains(&reward_type)) {
        return 0
    };
    
    let user_rewards = self.user_rewards.borrow(user);
    let pools = self.reward_pools.get(&reward_type);
    
    // Calculate pending rewards from each pool of this token type
    let mut total_pending = 0;
    
    pools.length().do!(|pool_idx| {
        let reward_pool = pools.borrow(pool_idx);
        let pool_id = reward_pool.id;
        
        if (user_rewards.accumulated_rewards.contains(&pool_id)) {
            let user_accumulated = *user_rewards.accumulated_rewards.get(&pool_id);
            let total_rewards = ((user_supply as u128) * (reward_pool.cumulative_reward_per_share as u128) / (SCALING_FACTOR as u128)) as u64;
            
            if (total_rewards > user_accumulated) {
                total_pending = total_pending + (total_rewards - user_accumulated);
            };
        } else {
            // User has no accumulated rewards for this pool, so all rewards are pending
            let total_rewards = ((user_supply as u128) * (reward_pool.cumulative_reward_per_share as u128) / (SCALING_FACTOR as u128)) as u64;
            total_pending = total_pending + total_rewards;
        };
    });
    total_pending
}

/// Adds a user rewards entry if it doesn't exist.
fun add_user_rewards_entry<Asset>(self: &mut MarginPool<Asset>, user: address, _ctx: &mut TxContext) {
    if (self.user_rewards.contains(user)) {
        return
    };
    
    let user_rewards = UserRewards {
        accumulated_rewards: vec_map::empty(),
    };
    
    self.user_rewards.add(user, user_rewards);
}

