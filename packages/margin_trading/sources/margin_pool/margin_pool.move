// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::{
    margin_constants,
    margin_state::{Self, State, InterestParams},
    reward_pool::{
        RewardPool,
        UserRewards,
        claim_from_pool,
        create_reward_pool,
        emit_rewards_claimed,
        emit_reward_pool_added,
        create_user_rewards,
        initialize_user_reward_for_type,
        reward_token_type,
        update_user_accumulated_rewards_by_type,
        update_reward_pool
    }
};
use std::type_name::{Self, TypeName};
use sui::{
    bag::{Self, Bag},
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    event,
    table::{Self, Table}
};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const ECannotRepayMoreThanLoan: u64 = 4;
const EMaxPoolBorrowPercentageExceeded: u64 = 5;
const EInvalidLoanQuantity: u64 = 6;
const EInvalidRepaymentQuantity: u64 = 7;
const EMaxRewardTypesExceeded: u64 = 8;

// === Structs ===
public struct Loan has drop, store {
    loan_amount: u64, // total loan remaining, including interest
    last_index: u64, // 9 decimals
}

public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    supplies: Table<address, u64>, // maps address quantity of shares supplied
    state: State,
    reward_pools: vector<RewardPool>, // stores all reward pools
    reward_balances: Bag,
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

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    self.update_state(clock);

    let supplier = ctx.sender();
    let supply_amount = coin.value();
    let supply_index = self.state.supply_index();
    let supply_shares = math::div(supply_amount, supply_index);

    self.update_user(supplier, clock);
    self.increase_user_supply_shares(supplier, supply_shares);
    self.state.increase_total_supply(supply_amount);
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
    let supplier = ctx.sender();
    let user_supply_shares = self.update_user(supplier, clock);
    let withdrawal_amount = amount.get_with_default(user_supply_shares);
    let withdrawal_amount_shares = math::div(withdrawal_amount, self.state.supply_index());
    assert!(withdrawal_amount_shares <= user_supply_shares, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= self.vault.value(), ENotEnoughAssetInPool);
    self.decrease_user_supply_shares(ctx.sender(), withdrawal_amount_shares);
    self.state.decrease_total_supply(withdrawal_amount);

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
        loans: table::new(ctx),
        supplies: table::new(ctx),
        state: margin_state::default(
            interest_params,
            supply_cap,
            max_borrow_percentage,
            protocol_spread,
            clock,
        ),
        reward_pools: vector[],
        reward_balances: bag::new(ctx),
        user_rewards: table::new(ctx),
    };
    let margin_pool_id = margin_pool.id.to_inner();
    transfer::share_object(margin_pool);

    margin_pool_id
}

/// Updates the supply cap for the margin pool.
public(package) fun update_supply_cap<Asset>(self: &mut MarginPool<Asset>, supply_cap: u64) {
    self.state.set_supply_cap(supply_cap);
}

/// Updates the maximum borrow percentage for the margin pool.
public(package) fun update_max_borrow_percentage<Asset>(
    self: &mut MarginPool<Asset>,
    max_borrow_percentage: u64,
) {
    self.state.set_max_borrow_percentage(max_borrow_percentage);
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
/// End time is specified in seconds.
public(package) fun add_reward_pool<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    reward_coin: Coin<RewardToken>,
    end_time: u64,
    clock: &Clock,
) {
    let reward_token_type = type_name::get<RewardToken>();
    let existing_pool_index = self.reward_pools.find_index!(|pool| {
        pool.reward_token_type() == reward_token_type
    });

    if (existing_pool_index.is_some()) {
        let index = existing_pool_index.destroy_some();
        let existing_balance = if (self.reward_balances.contains(reward_token_type)) {
            self.reward_balances.borrow<TypeName, Balance<RewardToken>>(reward_token_type).value()
        } else {
            0
        };

        self
            .reward_pools[index]
            .add_rewards_and_reset_timing(
                existing_balance,
                reward_coin.value(),
                end_time,
                clock,
            );
        add_reward_balance_to_bag(&mut self.reward_balances, reward_coin);
    } else {
        assert!(
            self.reward_pools.length() < margin_constants::max_reward_types(),
            EMaxRewardTypesExceeded,
        );
        let reward_pool = create_reward_pool<RewardToken>(reward_coin.value(), end_time, clock);
        add_reward_balance_to_bag(&mut self.reward_balances, reward_coin);
        emit_reward_pool_added(self.id.to_inner(), &reward_pool);
        self.reward_pools.push_back(reward_pool);
    };
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

    assert!(
        borrow_percentage <= self.state.max_borrow_percentage(),
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

/// Returns the loans table.
public(package) fun loans<Asset>(self: &MarginPool<Asset>): &Table<ID, Loan> {
    &self.loans
}

/// Returns the supplies table.
public(package) fun supplies<Asset>(self: &MarginPool<Asset>): &Table<address, u64> {
    &self.supplies
}

/// Returns the supply cap.
public(package) fun supply_cap<Asset>(self: &MarginPool<Asset>): u64 {
    self.state.supply_cap()
}

/// Returns the state.
public(package) fun state<Asset>(self: &MarginPool<Asset>): &State {
    &self.state
}

/// Allows users to claim their accumulated rewards for a specific reward token type.
/// Claims from all active reward pools of that token type.
public fun claim_rewards<Asset, RewardToken>(
    self: &mut MarginPool<Asset>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RewardToken> {
    let user = ctx.sender();
    self.update_user(user, clock);

    let reward_token_type = type_name::get<RewardToken>();
    let user_rewards_mut = self.user_rewards.borrow_mut(user);
    let mut claimed_balance = balance::zero<RewardToken>();

    let reward_pool_index = self.reward_pools.find_index!(|pool| {
        pool.reward_token_type() == reward_token_type
    });

    if (reward_pool_index.is_some()) {
        let claimed_amount = claim_from_pool<RewardToken>(user_rewards_mut);
        claimed_balance.join(
            withdraw_reward_balance_from_bag<RewardToken>(
                &mut self.reward_balances,
                claimed_amount,
            ),
        );
    };

    if (claimed_balance.value() > 0) {
        emit_rewards_claimed(self.id.to_inner(), reward_token_type, user, claimed_balance.value());
    };

    claimed_balance.into_coin(ctx)
}

/// Returns all reward pools
public fun get_reward_pools<Asset>(self: &MarginPool<Asset>): &vector<RewardPool> {
    &self.reward_pools
}

// === Internal Functions ===
fun update_all_reward_pools<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    self.reward_pools.do_mut!(|pool| update_reward_pool(pool, self.state.total_supply(), clock));
}

/// Updates the state
fun update_state<Asset>(self: &mut MarginPool<Asset>, clock: &Clock) {
    self.state.update(clock);
}

fun increase_user_supply_shares<Asset>(
    self: &mut MarginPool<Asset>,
    supplier: address,
    amount: u64,
) {
    let supply = self.supplies.borrow_mut(supplier);
    *supply = *supply + amount;
}

fun decrease_user_supply_shares<Asset>(
    self: &mut MarginPool<Asset>,
    supplier: address,
    amount: u64,
) {
    let supply = self.supplies.borrow_mut(supplier);
    *supply = *supply - amount;
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

fun update_user_rewards_entry<Asset>(self: &mut MarginPool<Asset>, user: address) {
    if (self.user_rewards.contains(user)) {
        return
    };

    let mut user_rewards = create_user_rewards();
    self.reward_pools.do_ref!(|reward_pool| {
        let reward_type = reward_pool.reward_token_type();
        let cumulative_reward_per_share = reward_pool.cumulative_reward_per_share();
        initialize_user_reward_for_type(
            &mut user_rewards,
            reward_type,
            cumulative_reward_per_share,
        );
    });
    self.user_rewards.add(user, user_rewards);
}

/// Updates user supply with interest and rewards, returns the user's supply amount before update
fun update_user<Asset>(self: &mut MarginPool<Asset>, user: address, clock: &Clock): u64 {
    self.add_user_supply_entry(user);
    self.update_user_rewards_entry(user);
    self.update_all_reward_pools(clock);

    let user_supply_shares = self.supplies.borrow(user);
    let user_rewards_mut = self.user_rewards.borrow_mut(user);
    self.reward_pools.do_ref!(|reward_pool| {
        let reward_type = reward_pool.reward_token_type();
        let cumulative_reward_per_share = reward_pool.cumulative_reward_per_share();

        update_user_accumulated_rewards_by_type(
            user_rewards_mut,
            reward_type,
            cumulative_reward_per_share,
            *user_supply_shares,
        );
    });

    *user_supply_shares
}

fun add_user_supply_entry<Asset>(self: &mut MarginPool<Asset>, user: address) {
    if (self.supplies.contains(user)) {
        return
    };
    self.supplies.add(user, 0);
}

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
