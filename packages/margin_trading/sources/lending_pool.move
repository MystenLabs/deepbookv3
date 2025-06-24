// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::lending_pool;

use deepbook::pool::Pool;
use margin_trading::{
    constants,
    margin_manager::MarginManager,
    margin_math,
    margin_registry::{LendingAdminCap, MarginRegistry},
    oracle::calculate_usd_price
};
use pyth::price_info::PriceInfoObject;
use sui::{balance::{Self, Balance}, borrow, clock::Clock, coin::Coin, table::{Self, Table}};

// === Constants ===
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;
const ESupplyCapExceeded: u64 = 2;
const ENoSupplyFound: u64 = 3;
const ECannotWithdrawMoreThanSupply: u64 = 4;
const EMaxPoolBorrowPercentageExceeded: u64 = 5;

// === Structs ===
public struct Loan has drop, store {
    principle_loan_amount: u64, // total loan amount without interest
    total_repayments: u64, // total repaid amount
    loan_amount: u64, // total loan remaining, including interest
    last_borrow_index: u64, // 9 decimals
}

public struct Supply has drop, store {
    user: address, // address of the user who supplied
    supplied_amount: u64, // amount supplied in this transaction
    last_supply_index: u64, // 9 decimals
}

// public struct LoanRepayed has drop, store {
//     balance_manager: ID, // ID of the loan
//     repaid_amount: u64, // amount repaid in this transaction
// }

/// TODO: update interest params as needed
/// Represents all the interest parameters for the lending pool. Can be updated on chain.
public struct InterestParams has store {
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
    // Add more params if needed, like max interest rate, etc.
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

// === Public-Mutative Functions * ADMIN * ===
/// Creates a lending pool as the admin.
public fun create_lending_pool<Asset>(
    registry: &mut MarginRegistry,
    supply_cap: u64,
    max_borrow_percentage: u64,
    base_rate: u64,
    multiplier: u64,
    _cap: &LendingAdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let interest_params = InterestParams {
        base_rate,
        multiplier,
    };
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

/// TODO: actual interest params as needed
/// Updates interest params for the lending pool as the admin.
public fun update_interest_params<Asset>(
    pool: &mut LendingPool<Asset>,
    base_rate: u64,
    multiplier: u64,
    _cap: &LendingAdminCap,
) {
    pool.interest_params.base_rate = base_rate;
    pool.interest_params.multiplier = multiplier;
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

// === Public-Mutative Functions * LENDING * ===
/// Allows anyone to supply the lending pool.
public fun supply_lending_pool<Asset>(
    lending_pool: &mut LendingPool<Asset>,
    coin: Coin<Asset>,
    clock: &Clock,
    ctx: &TxContext,
) {
    update_indices<Asset>(lending_pool, clock);

    let supply_amount = coin.value();
    assert!(
        lending_pool.total_supply + supply_amount <= lending_pool.supply_cap,
        ESupplyCapExceeded,
    );
    let balance = coin.into_balance();
    lending_pool.vault.join(balance);

    let supplier = ctx.sender();
    if (lending_pool.supplies.contains(supplier)) {
        let mut supply = lending_pool.supplies.remove(supplier);
        let interest_multiplier = margin_math::div(
            lending_pool.supply_index,
            supply.last_supply_index,
        );
        let new_supply_amount = margin_math::mul(supply.supplied_amount, interest_multiplier); // previous supply with interest
        let interest_earned = new_supply_amount - supply.supplied_amount; // TODO: event for interest earned?
        lending_pool.total_supply = lending_pool.total_supply + interest_earned + supply_amount;

        supply.supplied_amount = new_supply_amount; // previous supply with interest
        supply.supplied_amount = supply.supplied_amount + supply_amount; // new supply
        supply.last_supply_index = lending_pool.supply_index;
        lending_pool.supplies.add(supplier, supply);
    } else {
        let supply = Supply {
            user: supplier,
            supplied_amount: supply_amount,
            last_supply_index: lending_pool.supply_index,
        };
        lending_pool.supplies.add(supplier, supply);
        lending_pool.total_supply = lending_pool.total_supply + supply_amount;
    };
}

/// Allows withdrawal from the lending pool.
public fun withdraw_from_lending_pool<Asset>(
    lending_pool: &mut LendingPool<Asset>,
    amount: Option<u64>, // if None, withdraw all
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    update_indices<Asset>(lending_pool, clock);

    let supplier = ctx.sender();
    assert!(lending_pool.supplies.contains(supplier), ENoSupplyFound);

    let mut supply = lending_pool.supplies.remove(supplier);
    let interest_multiplier = margin_math::div(
        lending_pool.supply_index,
        supply.last_supply_index,
    );
    let new_supply_amount = margin_math::mul(supply.supplied_amount, interest_multiplier); // previous supply with interest
    let interest_earned = new_supply_amount - supply.supplied_amount; // TODO: event for interest earned?
    let withdrawal_amount = amount.get_with_default(new_supply_amount);

    assert!(withdrawal_amount <= new_supply_amount, ECannotWithdrawMoreThanSupply);
    lending_pool.total_supply = lending_pool.total_supply + interest_earned - withdrawal_amount;

    supply.supplied_amount = new_supply_amount; // previous supply with interest
    supply.supplied_amount = supply.supplied_amount - withdrawal_amount; // new supply
    supply.last_supply_index = lending_pool.supply_index;

    if (supply.supplied_amount > 0) {
        lending_pool.supplies.add(supplier, supply); // update supply
    };

    lending_pool.vault.split(withdrawal_amount).into_coin(ctx)
}

public fun borrow_base<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<BaseAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_indices<BaseAsset>(lending_pool, clock);
    lending_pool.borrow<BaseAsset, QuoteAsset, BaseAsset>(margin_manager, loan_amount, ctx);
}

public fun borrow_quote<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_indices<QuoteAsset>(lending_pool, clock);
    lending_pool.borrow<BaseAsset, QuoteAsset, QuoteAsset>(margin_manager, loan_amount, ctx);
}

public(package) fun borrow<BaseAsset, QuoteAsset, BorrowAsset>(
    lending_pool: &mut LendingPool<BorrowAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    ctx: &mut TxContext,
) {
    assert!(lending_pool.vault.value() >= loan_amount, ENotEnoughAssetInPool);
    let manager_id = margin_manager.id();
    if (lending_pool.loans.contains(manager_id)) {
        let mut loan = lending_pool.loans.remove(manager_id);
        let interest_multiplier = margin_math::div(
            lending_pool.borrow_index,
            loan.last_borrow_index,
        );
        let new_loan_amount = margin_math::mul(loan.loan_amount, interest_multiplier); // previous loan with interest
        let interest = new_loan_amount - loan.loan_amount; // TODO: event for interest earned?
        loan.loan_amount = new_loan_amount; // previous loan with interest
        loan.loan_amount = loan.loan_amount + loan_amount; // new loan
        loan.last_borrow_index = lending_pool.borrow_index;

        lending_pool.total_loan = lending_pool.total_loan + interest + loan_amount;
        lending_pool.loans.add(manager_id, loan);
    } else {
        let loan = Loan {
            principle_loan_amount: loan_amount,
            total_repayments: 0,
            loan_amount,
            last_borrow_index: lending_pool.borrow_index,
        };
        lending_pool.loans.add(manager_id, loan);
        lending_pool.total_loan = lending_pool.total_loan + loan_amount;
    };

    let borrow_percentage = margin_math::div(lending_pool.total_loan, lending_pool.total_supply);
    assert!(
        borrow_percentage <= lending_pool.max_borrow_percentage,
        EMaxPoolBorrowPercentageExceeded,
    );

    let deposit = lending_pool.vault.split(loan_amount).into_coin(ctx);
    margin_manager.deposit<BaseAsset, QuoteAsset, BorrowAsset>(deposit, ctx);

    // TODO: check margin_manager risk level. If too low (<1.25), abort. Complete after oracle integration
}

public fun repay_base<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<BaseAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    repay_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_indices<BaseAsset>(lending_pool, clock);
    lending_pool.repay<BaseAsset, QuoteAsset, BaseAsset>(margin_manager, repay_amount, ctx);
}

public fun repay_quote<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    repay_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_indices<QuoteAsset>(lending_pool, clock);
    lending_pool.repay<BaseAsset, QuoteAsset, QuoteAsset>(margin_manager, repay_amount, ctx);
}

public(package) fun repay<BaseAsset, QuoteAsset, RepayAsset>(
    lending_pool: &mut LendingPool<RepayAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    repay_amount: u64,
    ctx: &mut TxContext,
) {
    let manager_id = margin_manager.id();
    if (lending_pool.loans.contains(manager_id)) {
        let mut loan = lending_pool.loans.remove(manager_id);
        let interest_multiplier = margin_math::div(
            lending_pool.borrow_index,
            loan.last_borrow_index,
        );
        loan.loan_amount = margin_math::mul(loan.loan_amount, interest_multiplier); // previous loan with interest
        loan.last_borrow_index = lending_pool.borrow_index;

        // if user tries to repay more than owed, just repay the full amount
        let repayment = if (repay_amount >= loan.loan_amount) {
            repay_amount
        } else {
            loan.loan_amount
        };

        let coin = margin_manager.withdraw<BaseAsset, QuoteAsset, RepayAsset>(repayment, ctx);
        let balance = coin.into_balance();
        lending_pool.vault.join(balance);

        loan.loan_amount = loan.loan_amount - repay_amount;
        if (loan.loan_amount > 0) {
            lending_pool.loans.add(manager_id, loan);
        };
    }
}

/// Returns (base_amount, quote_amount) for balance manager
public fun margin_manager_asset<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
): (u64, u64) {
    let balance_manager = margin_manager.balance_manager();
    let (mut base, mut quote, _) = pool.locked_balance(balance_manager);
    base = base + balance_manager.balance<BaseAsset>();
    quote = quote + balance_manager.balance<QuoteAsset>();

    (base, quote)
}

// Returns the base and quote debt of the margin manager
public fun margin_manager_debt<BaseAsset, QuoteAsset>(
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    clock: &Clock,
): (u64, u64) {
    let base_debt = base_lending_pool.manager_debt(margin_manager, clock);
    let quote_debt = quote_lending_pool.manager_debt(margin_manager, clock);

    (base_debt, quote_debt)
}

public fun risk_ratio<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    base_lending_pool: &mut LendingPool<BaseAsset>,
    quote_lending_pool: &mut LendingPool<QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): u64 {
    let (base_debt, quote_debt) = margin_manager_debt<BaseAsset, QuoteAsset>(
        base_lending_pool,
        quote_lending_pool,
        margin_manager,
        clock,
    );
    let (base_asset, quote_asset) = margin_manager_asset<BaseAsset, QuoteAsset>(
        pool,
        margin_manager,
    );

    let (base_usd_debt, base_usd_asset) = calculate_usd_price<BaseAsset>(
        registry,
        base_debt,
        base_asset,
        clock,
        base_price_info_object,
    );
    let (quote_usd_debt, quote_usd_asset) = calculate_usd_price<QuoteAsset>(
        registry,
        quote_debt,
        quote_asset,
        clock,
        quote_price_info_object,
    );
    let total_usd_debt = base_usd_debt + quote_usd_debt; // 6 decimals
    let total_usd_asset = base_usd_asset + quote_usd_asset; // 6 decimals

    if (total_usd_debt == 0) {
        return constants::max_u64() // infinite risk ratio if no debt
    };

    // TODO: Think about the edge cases here. Set debt ratio as maximumm if asset > some_number * debt?
    margin_math::div(total_usd_asset, total_usd_debt) // 9 decimals
}

public(package) fun manager_debt<BaseAsset, QuoteAsset, Asset>(
    lending_pool: &mut LendingPool<Asset>,
    margin_manager: &MarginManager<BaseAsset, QuoteAsset>,
    clock: &Clock,
): u64 {
    update_indices<Asset>(lending_pool, clock);

    // TODO: need to refresh loan value to include interest

    lending_pool.loans.borrow(margin_manager.id()).loan_amount
}

/// Updates the borrow and supply indices for the lending pool.
/// This will be called before any borrow or supply operation.
public(package) fun update_indices<Asset>(self: &mut LendingPool<Asset>, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let ms_elapsed = current_time - self.last_index_update_timestamp;
    let (borrow_interest_rate, supply_interest_rate) = self.interest_rates();
    let new_borrow_index =
        self.borrow_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, borrow_interest_rate),YEAR_MS));
    let new_supply_index =
        self.supply_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, supply_interest_rate), YEAR_MS));
    self.borrow_index = new_borrow_index;
    self.supply_index = new_supply_index;
    self.last_index_update_timestamp = current_time;
}

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

/// Get the ID of the pool given the asset types.
public fun get_lending_pool_id_by_asset<Asset>(registry: &MarginRegistry): ID {
    registry.get_lending_pool_id<Asset>()
}
