// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module margin_trading::manager_info;

use deepbook::{constants, math};
use margin_trading::{
    margin_constants,
    margin_registry::MarginRegistry,
    oracle::calculate_target_amount
};
use pyth::price_info::PriceInfoObject;
use sui::clock::Clock;

// === Structs ===
/// Information about a single asset (base or quote)
public struct AssetInfo has copy, drop {
    asset: u64, // Asset amount in native units
    debt: u64, // Debt amount in native units
    usd_asset: u64, // Asset value in USD
    usd_debt: u64, // Debt value in USD
}

/// Combined information about a margin manager's position
public struct ManagerInfo has copy, drop {
    base: AssetInfo,
    quote: AssetInfo,
    debt: u64,
    asset_usd: u64, // Asset value in USD
    debt_usd: u64, // Debt value in USD
    risk_ratio: u64, // Risk ratio with 9 decimals
    base_per_dollar: u64, // Base asset per dollar with 9 decimals
    quote_per_dollar: u64, // Quote asset per dollar with 9 decimals
    debt_per_dollar: u64, // Debt per dollar with 9 decimals
    user_liquidation_reward: u64, // User liquidation reward with 9 decimals
    pool_liquidation_reward: u64, // Pool liquidation reward with 9 decimals
    target_ratio: u64, // Target ratio with 9 decimals
}

public struct Fulfillment {
    manager_id: ID,
    repay_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    base_exit_amount: u64,
    quote_exit_amount: u64,
    risk_ratio: u64,
}

// === Public Functions ===
public fun risk_ratio(manager_info: &ManagerInfo): u64 {
    manager_info.risk_ratio
}

/// === Public(package) Functions ===
/// Calculate ManagerInfo from raw asset/debt data and oracle information
/// This centralizes all USD calculation and risk ratio computation logic
public(package) fun new_manager_info<BaseAsset, QuoteAsset>(
    base_asset: u64,
    quote_asset: u64,
    base_debt: u64,
    quote_debt: u64,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
    pool_id: ID,
): ManagerInfo {
    let base_per_dollar = calculate_target_amount<BaseAsset>(
        base_price_info_object,
        registry,
        constants::float_scaling(),
        clock,
    );

    let quote_per_dollar = calculate_target_amount<QuoteAsset>(
        quote_price_info_object,
        registry,
        constants::float_scaling(),
        clock,
    );

    let debt_per_dollar = if (base_debt > 0) {
        base_per_dollar
    } else {
        quote_per_dollar
    };

    // Calculate debt in USD
    let base_usd_debt = if (base_debt > 0) {
        math::div(base_debt, base_per_dollar)
    } else {
        0
    };

    let quote_usd_debt = if (quote_debt > 0) {
        math::div(quote_debt, quote_per_dollar)
    } else {
        0
    };

    // Calculate asset values in USD
    let base_usd_asset = math::div(base_asset, base_per_dollar);
    let quote_usd_asset = math::div(quote_asset, quote_per_dollar);

    // Calculate risk ratio
    let total_usd_debt = base_usd_debt + quote_usd_debt;
    let total_usd_asset = base_usd_asset + quote_usd_asset;
    let max_risk_ratio = margin_constants::max_risk_ratio();

    let risk_ratio = if (
        total_usd_debt == 0 || total_usd_asset > math::mul(total_usd_debt, max_risk_ratio)
    ) {
        max_risk_ratio
    } else {
        math::div(total_usd_asset, total_usd_debt) // 9 decimals
    };

    // Construct and return ManagerInfo
    ManagerInfo {
        base: AssetInfo {
            asset: base_asset,
            debt: base_debt,
            usd_asset: base_usd_asset,
            usd_debt: base_usd_debt,
        },
        quote: AssetInfo {
            asset: quote_asset,
            debt: quote_debt,
            usd_asset: quote_usd_asset,
            usd_debt: quote_usd_debt,
        },
        debt: base_debt.max(quote_debt),
        asset_usd: total_usd_asset,
        debt_usd: total_usd_debt,
        debt_per_dollar,
        risk_ratio,
        base_per_dollar,
        quote_per_dollar,
        user_liquidation_reward: registry.user_liquidation_reward(pool_id),
        pool_liquidation_reward: registry.pool_liquidation_reward(pool_id),
        target_ratio: registry.target_liquidation_risk_ratio(pool_id),
    }
}

public(package) fun produce_fulfillment(manager_info: &ManagerInfo, manager_id: ID): Fulfillment {
    let (repay_amount, default_amount) = if (
        manager_info.risk_ratio >= constants::float_scaling()
    ) {
        (0, 0)
    } else {
        let liquidation_reward =
            manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward;
        let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;
        let debt = manager_info.base.debt.max(manager_info.quote.debt);
        let repay_with_liquidation_reward = math::mul(debt, manager_info.risk_ratio);
        let quantity_to_repay = math::div(repay_with_liquidation_reward, liquidation_reward_ratio);
        let repay_amount = math::div(quantity_to_repay, manager_info.debt_per_dollar);
        let default_amount = debt - repay_amount;
        (repay_amount, default_amount)
    };

    let pool_reward_amount = manager_info.to_pool_liquidation_reward(repay_amount);
    let (base_exit_amount, quote_exit_amount) = manager_info.calculate_exit_amounts(repay_amount);
    Fulfillment {
        manager_id,
        repay_amount,
        pool_reward_amount,
        default_amount,
        base_exit_amount,
        quote_exit_amount,
        risk_ratio: manager_info.risk_ratio,
    }
}

public(package) fun with_liquidation_reward_ratio(manager_info: &ManagerInfo, amount: u64): u64 {
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward;
    let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;

    math::mul(amount, liquidation_reward_ratio)
}

public(package) fun to_pool_liquidation_reward(manager_info: &ManagerInfo, amount: u64): u64 {
    let pool_liquidation_reward = manager_info.pool_liquidation_reward;

    math::mul(amount, pool_liquidation_reward)
}

public(package) fun with_pool_reward_ratio(manager_info: &ManagerInfo, amount: u64): u64 {
    let pool_reward_ratio = constants::float_scaling() + manager_info.pool_liquidation_reward;
    math::mul(amount, pool_reward_ratio)
}

public(package) fun debt_usd_to_quantity(manager_info: &ManagerInfo, debt_usd: u64): u64 {
    math::div(debt_usd, manager_info.debt_per_dollar)
}

public(package) fun calculate_usd_amount_to_repay(manager_info: &ManagerInfo): u64 {
    let in_default = manager_info.risk_ratio < constants::float_scaling();
    let debt_usd = manager_info.debt_usd;
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward;

    let usd_to_repay = if (in_default) {
        let repay_usd_with_liquidation_reward = math::mul(debt_usd, manager_info.risk_ratio);
        let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;
        let usd_to_repay = math::div(repay_usd_with_liquidation_reward, liquidation_reward_ratio);

        usd_to_repay
    } else {
        let target_ratio = manager_info.target_ratio; // 1.25
        let assets_in_usd = manager_info.asset_usd; // 1100
        let numerator = math::mul(target_ratio, debt_usd) - assets_in_usd; // 1250 - 1100 = 150
        let denominator = target_ratio - (constants::float_scaling() + liquidation_reward); // 1.25 - 1.05 = 0.2

        math::div(numerator, denominator) // 750
    };

    usd_to_repay
}

public(package) fun calculate_exit_amounts(manager_info: &ManagerInfo, repay_usd: u64): (u64, u64) {
    let total_usd_to_exit = manager_info.with_liquidation_reward_ratio(repay_usd);
    let base_usd_asset = manager_info.base.usd_asset;
    let quote_usd_asset = manager_info.quote.usd_asset;
    let (base_usd, quote_usd) = if (manager_info.base.debt > 0) {
        let base_usd = total_usd_to_exit.min(base_usd_asset);
        let total_usd_to_exit = total_usd_to_exit - base_usd;
        let quote_usd = total_usd_to_exit.min(quote_usd_asset);
        (base_usd, quote_usd)
    } else {
        let quote_usd = total_usd_to_exit.min(quote_usd_asset);
        let total_usd_to_exit = total_usd_to_exit - quote_usd;
        let base_usd = total_usd_to_exit.min(base_usd_asset);
        (base_usd, quote_usd)
    };

    let base_to_exit = math::div(base_usd, manager_info.base_per_dollar);
    let quote_to_exit = math::div(quote_usd, manager_info.quote_per_dollar);

    (base_to_exit, quote_to_exit)
}

public(package) fun calculate_quantity_to_exit(manager_info: &ManagerInfo): (u64, u64) {
    let usd_amount_to_repay = manager_info.calculate_usd_amount_to_repay();
    let usd_amount_to_repay_with_reward = manager_info.with_liquidation_reward_ratio(
        usd_amount_to_repay,
    ); // 750 * 1.05 = 787.5

    let base_usd_asset = manager_info.base.usd_asset; // 550
    let quote_usd_asset = manager_info.quote.usd_asset; // 550
    let mut base_to_exit_usd = 0;
    let mut quote_to_exit_usd = 0;

    let same_asset_to_repay_usd = if (manager_info.base.debt > 0) {
        let same_repay = usd_amount_to_repay_with_reward.min(base_usd_asset);
        base_to_exit_usd = base_to_exit_usd + same_repay;

        same_repay
    } else {
        let same_repay = usd_amount_to_repay_with_reward.min(quote_usd_asset);
        quote_to_exit_usd = quote_to_exit_usd + same_repay;

        same_repay
    }; // base_to_exit_usd = 550, quote_to_exit_usd = 0

    if (usd_amount_to_repay_with_reward > same_asset_to_repay_usd) {
        let usd_remaining_to_repay = usd_amount_to_repay_with_reward - same_asset_to_repay_usd;

        if (manager_info.base.debt > 0) {
            quote_to_exit_usd = quote_to_exit_usd + usd_remaining_to_repay.min(quote_usd_asset);
        } else {
            base_to_exit_usd = base_to_exit_usd + usd_remaining_to_repay.min(base_usd_asset);
        };
    }; // base_to_exit_usd = 550, quote_to_exit_usd = 787.5 - 550 = 237.5

    let base_to_exit = math::div(base_to_exit_usd, manager_info.base_per_dollar);
    let quote_to_exit = math::div(quote_to_exit_usd, manager_info.quote_per_dollar);

    (base_to_exit, quote_to_exit)
}

/// Calculate liquidation amounts with USD pricing logic
/// This centralizes all oracle-dependent calculations for liquidation
public(package) fun calculate_liquidation_amounts(
    manager_info: &ManagerInfo,
    liquidation_coin_value: u64,
): (u64, u64) {
    let max_usd_amount_to_repay = manager_info.calculate_usd_amount_to_repay();

    // Get debt and asset totals
    let debt = manager_info.debt;
    let assets_in_usd = manager_info.asset_usd; // $1100

    // Calculate ratios once
    let float_scaling = constants::float_scaling();
    let pool_reward_ratio = float_scaling + manager_info.pool_liquidation_reward; // 1.03

    // Get liquidation coin value in USD
    let coin_in_usd = math::div(liquidation_coin_value, manager_info.debt_per_dollar); // $700
    let coin_in_usd_minus_pool_reward = math::div(coin_in_usd, pool_reward_ratio); // $679.61

    // Handle default cases
    let total_liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward; // 5%
    let liquidation_reward_ratio = float_scaling + total_liquidation_reward; // 1.05
    let in_default = manager_info.risk_ratio < float_scaling;
    let max_repay_usd = if (in_default) {
        math::div(assets_in_usd, liquidation_reward_ratio)
    } else {
        max_usd_amount_to_repay
    }; // $750

    // Calculate final repay amounts
    let repay_usd = max_repay_usd.min(coin_in_usd_minus_pool_reward); // $679.61
    let loan_defaulted = in_default && repay_usd == max_repay_usd;

    let repay_amount = math::div(repay_usd, manager_info.debt_per_dollar); // 679.61 USDT
    let default_amount = if (loan_defaulted) debt - repay_amount else 0;

    (default_amount, repay_amount)
}

public(package) fun user_liquidation_reward(manager_info: &ManagerInfo): u64 {
    manager_info.user_liquidation_reward
}

public(package) fun pool_liquidation_reward(manager_info: &ManagerInfo): u64 {
    manager_info.pool_liquidation_reward
}

public(package) fun manager_id(fulfillment: &Fulfillment): ID {
    fulfillment.manager_id
}

public(package) fun repay_amount(fulfillment: &Fulfillment): u64 {
    fulfillment.repay_amount
}

public(package) fun pool_reward_amount(fulfillment: &Fulfillment): u64 {
    fulfillment.pool_reward_amount
}

public(package) fun default_amount(fulfillment: &Fulfillment): u64 {
    fulfillment.default_amount
}

public(package) fun base_exit_amount(fulfillment: &Fulfillment): u64 {
    fulfillment.base_exit_amount
}

public(package) fun quote_exit_amount(fulfillment: &Fulfillment): u64 {
    fulfillment.quote_exit_amount
}

public(package) fun fulfillment_risk_ratio(fulfillment: &Fulfillment): u64 {
    fulfillment.risk_ratio
}

public(package) fun drop(fulfillment: Fulfillment) {
    let Fulfillment {
        manager_id: _,
        repay_amount: _,
        pool_reward_amount: _,
        default_amount: _,
        base_exit_amount: _,
        quote_exit_amount: _,
        risk_ratio: _,
    } = fulfillment;
}
