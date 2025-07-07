// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::margin_pool;

use margin_trading::constants;
use margin_trading::interest_rate::{Self, InterestRate};
use margin_trading::margin_registry::{MarginAdminCap, MarginRegistry};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::table::{Self, Table};

// === Constants ===
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ENoSupplyFound: u64 = 3;
const ECannotWithdrawMoreThanSupply: u64 = 4;

// === Structs ===
public struct Loan has drop, store {
    loan_amount: u64, // total loan remaining, including interest
    last_borrow_index: u64, // 9 decimals
}

public struct Supply has drop, store {
    supplied_amount: u64, // amount supplied in this transaction
    last_supply_index: u64, // 9 decimals
}

/// Represents the state of the margin pool.
public struct State has drop, store {
    borrow_index: u64, // 9 decimals
    supply_index: u64, // 9 decimals
    last_index_update_timestamp: u64,
    utilization_rate: u64, // 9 decimals
}

public struct MarginPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    supplies: Table<address, Supply>, // maps address id to deposits
    total_loan: u64, // total amount of loans in the pool, excluding interest
    total_supply: u64, // total amount of assets in the pool
    supply_cap: u64, // maximum amount of assets that can be supplied to the pool
    interest_rate: InterestRate,
    state: State,
}

// === Public Functions * ADMIN * ===
/// Creates a margin pool as the admin. Registers the margin pool in the margin registry.
#[allow(unused_field)]
public fun create_margin_pool<Asset>(
    registry: &mut MarginRegistry,
    supply_cap: u64,
    _cap: &MarginAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {}

/// Updates interest params for the margin pool as the admin.
public fun update_interest_params<Asset>(
    pool: &mut MarginPool<Asset>,
    base_rate: u64,
    multiplier: u64,
    _cap: &MarginAdminCap,
) {
    pool.interest_rate.update_interest_rate(base_rate, multiplier)
}

/// Updates the supply cap for the margin pool as the admin.
public fun update_supply_cap<Asset>(
    pool: &mut MarginPool<Asset>,
    supply_cap: u64,
    _cap: &MarginAdminCap,
) {
    pool.supply_cap = supply_cap;
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the margin pool. Returns the new user supply amount.
public fun supply_margin_pool<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let supplier = ctx.sender();
    // if no entry, add an empty entry
    if (!margin_pool.supplies.contains(supplier)) {
        let supply = Supply {
            supplied_amount: 0,
            last_supply_index: margin_pool.state.supply_index,
        };
        margin_pool.supplies.add(supplier, supply);
    };

    let mut supply = update_user_supply<Asset>(margin_pool, clock, ctx);

    let supply_amount = coin.value();
    let balance = coin.into_balance();
    margin_pool.vault.join(balance);

    // remove entry and modify it
    let new_user_supply = supply.supplied_amount + supply_amount;
    supply.supplied_amount = new_user_supply;

    margin_pool.supplies.add(supplier, supply);
    margin_pool.total_supply = margin_pool.total_supply + supply_amount;

    assert!(
        margin_pool.total_supply <= margin_pool.supply_cap,
        ESupplyCapExceeded,
    );

    new_user_supply
}

/// Allows withdrawal from the margin pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw_from_margin_pool<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    amount: Option<u64> // if None, withdraw all,,,,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Asset>, u64) {
    let mut supply = update_user_supply<Asset>(margin_pool, clock, ctx);
    let new_supply_amount = supply.supplied_amount;
    let withdrawal_amount = amount.get_with_default(new_supply_amount);

    assert!(
        withdrawal_amount <= new_supply_amount,
        ECannotWithdrawMoreThanSupply,
    );
    assert!(
        withdrawal_amount <= margin_pool.vault.value(),
        ENotEnoughAssetInPool,
    );
    margin_pool.total_supply = margin_pool.total_supply - withdrawal_amount;

    let new_user_supply = supply.supplied_amount - withdrawal_amount;
    supply.supplied_amount = new_user_supply; // new supply

    if (supply.supplied_amount > 0) {
        margin_pool.supplies.add(ctx.sender(), supply); // update supply
    };

    (margin_pool.vault.split(withdrawal_amount).into_coin(ctx), new_user_supply)
}

// === Public-Package Functions ===
/// Updates the borrow and supply indices for the margin pool.
/// This will be called before any borrow or supply operation.
public(package) fun update_indices<Asset>(
    self: &mut MarginPool<Asset>,
    clock: &Clock,
) {
    let current_time = clock.timestamp_ms();
    let ms_elapsed = current_time - self.last_index_update_timestamp;
    let (borrow_interest_rate, supply_interest_rate) = self.interest_rates();
    let new_borrow_index =
        self.borrow_index * (
            constants::float_scaling() +
            margin_math::div(
                margin_math::mul(ms_elapsed, borrow_interest_rate),
                YEAR_MS,
            ),
        );
    let new_supply_index =
        self.supply_index * (
            constants::float_scaling() +
            margin_math::div(
                margin_math::mul(ms_elapsed, supply_interest_rate),
                YEAR_MS,
            ),
        );
    self.total_loan =
        margin_math::mul(
            self.total_loan,
            margin_math::div(new_borrow_index, self.borrow_index),
        );
    self.total_supply =
        margin_math::mul(
            self.total_supply,
            margin_math::div(new_supply_index, self.supply_index),
        );
    self.borrow_index = new_borrow_index;
    self.supply_index = new_supply_index;
    self.last_index_update_timestamp = current_time;
}

public(package) fun loans<Asset>(
    self: &mut MarginPool<Asset>,
): &mut Table<ID, Loan> {
    &mut self.loans
}

public(package) fun borrow_index<Asset>(self: &MarginPool<Asset>): u64 {
    self.borrow_index
}

public(package) fun total_loan<Asset>(self: &MarginPool<Asset>): u64 {
    self.total_loan
}

public(package) fun total_supply<Asset>(self: &MarginPool<Asset>): u64 {
    self.total_supply
}

public(package) fun vault<Asset>(
    self: &mut MarginPool<Asset>,
): &mut Balance<Asset> {
    &mut self.vault
}

public(package) fun set_total_loan<Asset>(
    self: &mut MarginPool<Asset>,
    amount: u64,
) {
    self.total_loan = amount;
}

public(package) fun max_borrow_percentage<Asset>(
    self: &MarginPool<Asset>,
): u64 {
    self.max_borrow_percentage
}

public(package) fun new_loan(loan_amount: u64, borrow_index: u64): Loan {
    Loan {
        loan_amount,
        last_borrow_index: borrow_index,
    }
}

public(package) fun loan_amount(self: &Loan): u64 { self.loan_amount }

public(package) fun last_borrow_index(self: &Loan): u64 {
    self.last_borrow_index
}

public(package) fun set_loan_amount(self: &mut Loan, amount: u64) {
    self.loan_amount = amount;
}

public(package) fun set_last_borrow_index(self: &mut Loan, index: u64) {
    self.last_borrow_index = index;
}

// === Internal Functions ===
/// TODO: more complex interest rate model, can update params on chain as needed
fun interest_rates<Asset>(self: &mut MarginPool<Asset>): (u64, u64) {
    self.update_utilization_rate<Asset>();
    let borrow_interest_rate = self.interest_params.base_rate;
    let supply_interest_rate = margin_math::mul(
        borrow_interest_rate,
        self.utilization_rate,
    );

    (borrow_interest_rate, supply_interest_rate)
}

/// Updates the utilization rate of the margin pool.
fun update_utilization_rate<Asset>(self: &mut MarginPool<Asset>) {
    self.utilization_rate = if (self.total_supply == 0) {
            0
        } else {
            margin_math::div(self.total_loan, self.total_supply) // 9 decimals
        }
}

/// Updates user's supply to include interest earned, supply index, and total supply. Returns Supply.
fun update_user_supply<Asset>(
    margin_pool: &mut MarginPool<Asset>,
    clock: &Clock,
    ctx: &TxContext,
): Supply {
    update_indices<Asset>(margin_pool, clock);

    let supplier = ctx.sender();
    assert!(margin_pool.supplies.contains(supplier), ENoSupplyFound);

    let mut supply = margin_pool.supplies.remove(supplier);
    let interest_multiplier = margin_math::div(
        margin_pool.supply_index,
        supply.last_supply_index,
    );
    let new_supply_amount = margin_math::mul(
        supply.supplied_amount,
        interest_multiplier,
    );
    supply.supplied_amount = new_supply_amount;
    supply.last_supply_index = margin_pool.supply_index;

    supply
}
