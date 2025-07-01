// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::lending_pool;

use margin_trading::{constants, margin_math, margin_registry::{LendingAdminCap, MarginRegistry}};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, table::{Self, Table}};

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

/// TODO: update interest params as needed, like max interest rate, etc.
/// Represents all the interest parameters for the lending pool. Can be updated on chain.
public struct InterestParams has drop, store {
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
}

public struct LendingPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    supplies: Table<address, Supply>, // maps address id to deposits
    supply_cap: u64, // maximum amount of assets that can be supplied to the pool
    max_borrow_percentage: u64, // maximum percentage of the total supply that can be borrowed. 9 decimals.
    total_loan: u64, // total amount of loans in the pool, excluding interest
    total_supply: u64, // total amount of assets in the pool
    borrow_index: u64, // 9 decimals
    supply_index: u64, // 9 decimals
    last_index_update_timestamp: u64,
    interest_params: InterestParams,
    utilization_rate: u64, // 9 decimals
}

// === Public Functions * ADMIN * ===
/// Creates a lending pool as the admin.
public fun create_lending_pool<Asset>(
    registry: &mut MarginRegistry,
    supply_cap: u64,
    max_borrow_percentage: u64,
    interest_params: InterestParams,
    _cap: &LendingAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let lending_pool = LendingPool<Asset> {
        id: object::new(ctx),
        vault: balance::zero<Asset>(),
        loans: table::new(ctx),
        supplies: table::new(ctx),
        supply_cap,
        max_borrow_percentage,
        total_loan: 0,
        total_supply: 0,
        borrow_index: 1_000_000_000, // start at 1.0
        supply_index: 1_000_000_000, // start at 1.0
        last_index_update_timestamp: clock.timestamp_ms(),
        interest_params,
        utilization_rate: 0,
    };

    let lending_pool_id = object::id(&lending_pool);
    registry.register_lending_pool<Asset>(lending_pool_id);

    transfer::share_object(lending_pool);
}

public fun new_interest_params(base_rate: u64, multiplier: u64): InterestParams {
    InterestParams {
        base_rate,
        multiplier,
    }
}

/// Updates interest params for the lending pool as the admin.
public fun update_interest_params<Asset>(
    pool: &mut LendingPool<Asset>,
    interest_params: InterestParams,
    _cap: &LendingAdminCap,
) {
    pool.interest_params = interest_params;
}

/// Updates the supply cap for the lending pool as the admin.
public fun update_supply_cap<Asset>(
    pool: &mut LendingPool<Asset>,
    supply_cap: u64,
    _cap: &LendingAdminCap,
) {
    pool.supply_cap = supply_cap;
}

/// Updates the maximum borrow percentage for the lending pool as the admin.
public fun update_max_borrow_percentage<Asset>(
    pool: &mut LendingPool<Asset>,
    max_borrow_percentage: u64,
    _cap: &LendingAdminCap,
) {
    pool.max_borrow_percentage = max_borrow_percentage;
}

// === Public Functions * LENDING * ===
/// Allows anyone to supply the lending pool. Returns the new user supply amount.
public fun supply_lending_pool<Asset>(
    lending_pool: &mut LendingPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    let supplier = ctx.sender();
    // if no entry, add an empty entry
    if (!lending_pool.supplies.contains(supplier)) {
        let supply = Supply {
            supplied_amount: 0,
            last_supply_index: lending_pool.supply_index,
        };
        lending_pool.supplies.add(supplier, supply);
    };

    let mut supply = update_user_supply<Asset>(lending_pool, clock, ctx);

    let supply_amount = coin.value();
    let balance = coin.into_balance();
    lending_pool.vault.join(balance);

    // remove entry and modify it
    let new_user_supply = supply.supplied_amount + supply_amount;
    supply.supplied_amount = new_user_supply;

    lending_pool.supplies.add(supplier, supply);
    lending_pool.total_supply = lending_pool.total_supply + supply_amount;

    assert!(lending_pool.total_supply <= lending_pool.supply_cap, ESupplyCapExceeded);

    new_user_supply
}

/// Allows withdrawal from the lending pool. Returns the withdrawn coin and the new user supply amount.
public fun withdraw_from_lending_pool<Asset>(
    lending_pool: &mut LendingPool<Asset>,
    amount: Option<u64>, // if None, withdraw all
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Asset>, u64) {
    let mut supply = update_user_supply<Asset>(lending_pool, clock, ctx);
    let new_supply_amount = supply.supplied_amount;
    let withdrawal_amount = amount.get_with_default(new_supply_amount);

    assert!(withdrawal_amount <= new_supply_amount, ECannotWithdrawMoreThanSupply);
    assert!(withdrawal_amount <= lending_pool.vault.value(), ENotEnoughAssetInPool);
    lending_pool.total_supply = lending_pool.total_supply - withdrawal_amount;

    let new_user_supply = supply.supplied_amount - withdrawal_amount;
    supply.supplied_amount = new_user_supply; // new supply

    if (supply.supplied_amount > 0) {
        lending_pool.supplies.add(ctx.sender(), supply); // update supply
    };

    (lending_pool.vault.split(withdrawal_amount).into_coin(ctx), new_user_supply)
}

// === Public-Helper Functions ===
/// Get the ID of the pool given the asset types.
public fun get_lending_pool_id_by_asset<Asset>(registry: &MarginRegistry): ID {
    registry.get_lending_pool_id<Asset>()
}

// === Public-Package Functions ===
/// Updates the borrow and supply indices for the lending pool.
/// This will be called before any borrow or supply operation.
public(package) fun update_indices<Asset>(self: &mut LendingPool<Asset>, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let ms_elapsed = current_time - self.last_index_update_timestamp;
    let (borrow_interest_rate, supply_interest_rate) = self.interest_rates();
    let new_borrow_index =
        self.borrow_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, borrow_interest_rate), YEAR_MS));
    let new_supply_index =
        self.supply_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, supply_interest_rate), YEAR_MS));
    self.borrow_index = new_borrow_index;
    self.supply_index = new_supply_index;
    self.last_index_update_timestamp = current_time;
}

public(package) fun loans<Asset>(self: &mut LendingPool<Asset>): &mut Table<ID, Loan> {
    &mut self.loans
}

public(package) fun borrow_index<Asset>(self: &LendingPool<Asset>): u64 {
    self.borrow_index
}

public(package) fun total_loan<Asset>(self: &LendingPool<Asset>): u64 {
    self.total_loan
}

public(package) fun total_supply<Asset>(self: &LendingPool<Asset>): u64 {
    self.total_supply
}

public(package) fun vault<Asset>(self: &mut LendingPool<Asset>): &mut Balance<Asset> {
    &mut self.vault
}

public(package) fun set_total_loan<Asset>(self: &mut LendingPool<Asset>, amount: u64) {
    self.total_loan = amount;
}

public(package) fun max_borrow_percentage<Asset>(self: &LendingPool<Asset>): u64 {
    self.max_borrow_percentage
}

public(package) fun new_loan(loan_amount: u64, borrow_index: u64): Loan {
    Loan {
        loan_amount,
        last_borrow_index: borrow_index,
    }
}

public(package) fun loan_amount(self: &Loan): u64 { self.loan_amount }

public(package) fun last_borrow_index(self: &Loan): u64 { self.last_borrow_index }

public(package) fun set_loan_amount(self: &mut Loan, amount: u64) {
    self.loan_amount = amount;
}

public(package) fun set_last_borrow_index(self: &mut Loan, index: u64) {
    self.last_borrow_index = index;
}

// === Internal Functions ===
/// TODO: more complex interest rate model, can update params on chain as needed
fun interest_rates<Asset>(self: &mut LendingPool<Asset>): (u64, u64) {
    self.update_utilization_rate<Asset>();
    let borrow_interest_rate = self.interest_params.base_rate;
    let supply_interest_rate = margin_math::mul(
        borrow_interest_rate,
        self.utilization_rate,
    );

    (borrow_interest_rate, supply_interest_rate)
}

/// Updates the utilization rate of the lending pool.
fun update_utilization_rate<Asset>(self: &mut LendingPool<Asset>) {
    self.utilization_rate = if (self.total_supply == 0) {
        0
    } else {
        margin_math::div(self.total_loan, self.total_supply) // 9 decimals
    }
}

/// Updates user's supply to include interest earned, supply index, and total supply. Returns Supply.
fun update_user_supply<Asset>(
    lending_pool: &mut LendingPool<Asset>,
    clock: &Clock,
    ctx: &TxContext,
): Supply {
    update_indices<Asset>(lending_pool, clock);

    let supplier = ctx.sender();
    assert!(lending_pool.supplies.contains(supplier), ENoSupplyFound);

    let mut supply = lending_pool.supplies.remove(supplier);
    let interest_multiplier = margin_math::div(
        lending_pool.supply_index,
        supply.last_supply_index,
    );
    let new_supply_amount = margin_math::mul(supply.supplied_amount, interest_multiplier);
    let interest_earned = new_supply_amount - supply.supplied_amount;

    supply.supplied_amount = new_supply_amount;
    supply.last_supply_index = lending_pool.supply_index;

    lending_pool.total_supply = lending_pool.total_supply + interest_earned;

    supply
}
