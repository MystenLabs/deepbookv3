// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use deepbook::math;
use margin_trading::{margin_registry::MarginAdminCap, margin_state::{Self, State}};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, event, table::{Self, Table}};

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ECannotWithdrawMoreThanSupply: u64 = 3;
const ECannotRepayMoreThanLoan: u64 = 4;
const EMaxPoolBorrowPercentageExceeded: u64 = 5;
const EInvalidLoanQuantity: u64 = 6;
const EInvalidRepaymentQuantity: u64 = 7;

// === Structs ===
public struct Loan has drop, store {
    loan_amount: u64, // total loan remaining, including interest
    last_index: u64, // 9 decimals
}

public struct Supply has drop, store {
    supplied_amount: u64, // amount supplied in this transaction
    last_index: u64, // 9 decimals
}

public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    supplies: Table<address, Supply>, // maps address id to deposits
    supply_cap: u64, // maximum amount of assets that can be supplied to the pool
    max_borrow_percentage: u64, // maximum percentage of borrowable assets in the pool
    state: State,
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

// === Public Functions * ADMIN * ===
/// Creates a margin pool as the admin. Registers the margin pool in the margin registry.
public fun create_margin_pool<Asset>(
    supply_cap: u64,
    max_borrow_percentage: u64,
    _cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let margin_pool = MarginPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        loans: table::new(ctx),
        supplies: table::new(ctx),
        supply_cap,
        max_borrow_percentage,
        state: margin_state::default(clock),
    };

    transfer::share_object(margin_pool);
}

/// Updates the supply cap for the margin pool as the admin.
public fun update_supply_cap<Asset>(
    pool: &mut MarginPool<Asset>,
    supply_cap: u64,
    _cap: &MarginAdminCap,
) {
    pool.supply_cap = supply_cap;
}

/// Updates the maximum borrow percentage for the margin pool as the admin.
public fun update_max_borrow_percentage<Asset>(
    pool: &mut MarginPool<Asset>,
    max_borrow_percentage: u64,
    _cap: &MarginAdminCap,
) {
    pool.max_borrow_percentage = max_borrow_percentage;
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply<Asset>(
    self: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let supplier = ctx.sender();
    let supply_amount = coin.value();
    self.user_supply(supplier, clock);
    self.increase_user_supply(supplier, supply_amount);
    self.state.increase_total_supply(supply_amount);
    let balance = coin.into_balance();
    self.vault.join(balance);

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
    let user_supply = self.user_supply(supplier, clock);
    let withdrawal_amount = amount.get_with_default(user_supply);
    assert!(withdrawal_amount <= user_supply, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= self.vault.value(), ENotEnoughAssetInPool);
    self.decrease_user_supply(ctx.sender(), withdrawal_amount);
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

public(package) fun share<Asset>(self: MarginPool<Asset>) {
    transfer::share_object(self);
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
