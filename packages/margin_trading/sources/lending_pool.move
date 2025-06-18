// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::lending_pool;

use deepbook::pool::Pool;
use margin_trading::{
    constants,
    margin_manager::MarginManager,
    margin_math::{Self, div as div},
    margin_registry::{LendingAdminCap, MarginRegistry},
    oracle::calculate_usd_price
};
use pyth::price_info::PriceInfoObject;
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, table::{Self, Table}};

// === Constants ===
const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

// === Errors ===
const ENotEnoughAssetInPool: u64 = 1;

// === Structs ===
public struct Loan has drop, store {
    loan_amount: u64, // total loan, including interest
    last_interest_index: u64, // 9 decimals
}

// TODO: update interest params as needed
public struct InterestParams has store {
    base_rate: u64, // 9 decimals
    multiplier: u64, // 9 decimals
}

public struct LendingPool<phantom Asset> has key, store {
    id: UID,
    vault: Balance<Asset>,
    loans: Table<ID, Loan>, // maps margin_manager id to Loan
    interest_index: u64, // 9 decimals
    last_index_update_timestamp: u64,
    interest_params: InterestParams,
    utilization_rate: u64, // 9 decimals
}

public fun create_lending_pool<Asset>(
    registry: &mut MarginRegistry,
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
        interest_index: 1_000_000_000, // start at 1.0
        last_index_update_timestamp: clock.timestamp_ms(),
        interest_params,
        utilization_rate: 0,
    };

    let lending_pool_id = object::id(&lending_pool);
    registry.register_lending_pool<Asset>(lending_pool_id);

    transfer::share_object(lending_pool);
}

// TODO: update interest params as needed
public fun update_interest_params<Asset>(
    pool: &mut LendingPool<Asset>,
    base_rate: u64,
    multiplier: u64,
    _cap: &LendingAdminCap,
) {
    pool.interest_params.base_rate = base_rate;
    pool.interest_params.multiplier = multiplier;
}

// Only admin can fund lending pool for MVP
// Should we just lock the funds in here?
public fun fund_lending_pool<Asset>(
    pool: &mut LendingPool<Asset>,
    coin: Coin<Asset>,
    _cap: &LendingAdminCap,
) {
    let balance = coin.into_balance();
    pool.vault.join(balance);
}

// Only admin can withdraw from lending pool for MVP
public fun withdraw_from_lending_pool<Asset>(
    pool: &mut LendingPool<Asset>,
    amount: u64,
    _cap: &LendingAdminCap,
    ctx: &mut TxContext,
): Coin<Asset> {
    // TODO: perform checks to make sure withdrawal is possible without error
    pool.vault.split(amount).into_coin(ctx)
}

public fun borrow_base<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<BaseAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_interest_index<BaseAsset>(lending_pool, clock);
    lending_pool.borrow<BaseAsset, QuoteAsset, BaseAsset>(margin_manager, loan_amount, ctx);
}

public fun borrow_quote<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_interest_index<QuoteAsset>(lending_pool, clock);
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
            lending_pool.interest_index,
            loan.last_interest_index,
        );
        loan.loan_amount = margin_math::mul(loan.loan_amount, interest_multiplier); // previous loan with interest
        loan.loan_amount = loan.loan_amount + loan_amount; // new loan
        loan.last_interest_index = lending_pool.interest_index;
        lending_pool.loans.add(manager_id, loan);
    } else {
        let loan = Loan {
            loan_amount,
            last_interest_index: lending_pool.interest_index,
        };
        lending_pool.loans.add(manager_id, loan);
    };
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
    update_interest_index<BaseAsset>(lending_pool, clock);
    lending_pool.repay<BaseAsset, QuoteAsset, BaseAsset>(margin_manager, repay_amount, ctx);
}

public fun repay_quote<BaseAsset, QuoteAsset>(
    lending_pool: &mut LendingPool<QuoteAsset>,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    repay_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_interest_index<QuoteAsset>(lending_pool, clock);
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
        let mut repay_amount = repay_amount;
        if (repay_amount > loan.loan_amount) {
            // if user tries to repay more than owed, just repay the full amount
            repay_amount = loan.loan_amount;
        };

        let coin = margin_manager.withdraw<BaseAsset, QuoteAsset, RepayAsset>(repay_amount, ctx);
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
    update_interest_index<Asset>(lending_pool, clock);

    // TODO: need to refresh loan value to include interest

    lending_pool.loans.borrow(margin_manager.id()).loan_amount
}

public(package) fun update_interest_index<Asset>(self: &mut LendingPool<Asset>, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let ms_elapsed = current_time - self.last_index_update_timestamp;
    let interest_rate = self.interest_params.base_rate; // TODO: more complex interest rate model, can update params on chain as needed
    let new_index =
        self.interest_index * (constants::float_scaling() + margin_math::div(margin_math::mul(ms_elapsed, interest_rate),YEAR_MS));
    self.interest_index = new_index;
    self.last_index_update_timestamp = current_time;
}

/// Get the ID of the pool given the asset types.
public fun get_lending_pool_id_by_asset<Asset>(registry: &MarginRegistry): ID {
    registry.get_lending_pool_id<Asset>()
}
