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
use sui::{clock::Clock, coin::Coin};

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
    base: AssetInfo, // Base asset information
    quote: AssetInfo, // Quote asset information
    risk_ratio: u64, // Risk ratio with 9 decimals
    base_per_dollar: u64, // Base asset per dollar with 9 decimals
    quote_per_dollar: u64, // Quote asset per dollar with 9 decimals
    user_liquidation_reward: u64, // User liquidation reward with 9 decimals
    pool_liquidation_reward: u64, // Pool liquidation reward with 9 decimals
    target_ratio: u64, // Target ratio with 9 decimals
}

/// Liquidation calculation results
public struct LiquidationAmounts has drop {
    debt_is_base: bool,
    repay_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    repay_usd: u64,
    repay_amount_with_pool_reward: u64,
}

// === Public Functions ===
public fun risk_ratio(manager_info: &ManagerInfo): u64 {
    manager_info.risk_ratio
}

public fun asset_info(manager_info: &ManagerInfo): (AssetInfo, AssetInfo) {
    (manager_info.base, manager_info.quote)
}

public fun base_info(manager_info: &ManagerInfo): AssetInfo {
    manager_info.base
}

public fun quote_info(manager_info: &ManagerInfo): AssetInfo {
    manager_info.quote
}

public fun asset_amount(asset_info: &AssetInfo): u64 {
    asset_info.asset
}

public fun debt_amount(asset_info: &AssetInfo): u64 {
    asset_info.debt
}

public fun usd_asset_amount(asset_info: &AssetInfo): u64 {
    asset_info.usd_asset
}

public fun usd_debt_amount(asset_info: &AssetInfo): u64 {
    asset_info.usd_debt
}

public fun liquidation_amounts_info(amounts: &LiquidationAmounts): (bool, u64, u64, u64, u64, u64) {
    (
        amounts.debt_is_base,
        amounts.repay_amount,
        amounts.pool_reward_amount,
        amounts.default_amount,
        amounts.repay_usd,
        amounts.repay_amount_with_pool_reward,
    )
}

/// === Public(package) Functions ===
/// Create a new AssetInfo struct
public(package) fun new_asset_info(
    asset: u64,
    debt: u64,
    usd_asset: u64,
    usd_debt: u64,
): AssetInfo {
    AssetInfo {
        asset,
        debt,
        usd_asset,
        usd_debt,
    }
}

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
        base: new_asset_info(base_asset, base_debt, base_usd_asset, base_usd_debt),
        quote: new_asset_info(quote_asset, quote_debt, quote_usd_asset, quote_usd_debt),
        risk_ratio,
        base_per_dollar,
        quote_per_dollar,
        user_liquidation_reward: registry.user_liquidation_reward(pool_id),
        pool_liquidation_reward: registry.pool_liquidation_reward(pool_id),
        target_ratio: registry.target_liquidation_risk_ratio(pool_id),
    }
}

public(package) fun to_user_liquidation_reward(manager_info: &ManagerInfo, amount: u64): u64 {
    let user_liquidation_reward = manager_info.user_liquidation_reward;

    math::mul(amount, user_liquidation_reward)
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

/// Returns (default_amount_to_repay, default_amount)
public(package) fun default_info(manager_info: &ManagerInfo, in_default: bool): (u64, u64) {
    if (!in_default) {
        return (0, 0)
    };

    // We calculate how much will be defaulted.
    // If 0.9 is the risk ratio, then the entire manager should be drained to repay as needed.
    // The total loan repaid in this scenario will be 0.9 * loan / (1 + liquidation_reward)
    // This is already being accounted for in base_out.min(max_base_to_exit) above for example
    // Assume asset is 900, debt is 1000, liquidation reward is 5%
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward;
    let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;
    let debt = manager_info.base.debt.max(manager_info.quote.debt);
    let repay_with_liquidation_reward = math::mul(debt, manager_info.risk_ratio);
    let quantity_to_repay = math::div(repay_with_liquidation_reward, liquidation_reward_ratio);

    // Now we calculate the defaulted amount, which is the debt - quantity_to_repay
    // This is the amount that will be defaulted. 1000 - 857.142 = 142.858
    (quantity_to_repay, debt - quantity_to_repay)
}

public(package) fun calculate_usd_amount_to_repay_in_default(manager_info: &ManagerInfo): u64 {
    let debt_usd = manager_info.base.usd_debt.max(manager_info.quote.usd_debt);
    let repay_usd_with_liquidation_reward = math::mul(debt_usd, manager_info.risk_ratio);
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward;
    let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;
    let usd_to_repay = math::div(repay_usd_with_liquidation_reward, liquidation_reward_ratio);

    usd_to_repay
}

public(package) fun calculate_usd_amount_to_repay(manager_info: &ManagerInfo): u64 {
    let target_ratio = manager_info.target_ratio; // 1.25
    let debt_in_usd = manager_info.base.usd_debt.max(manager_info.quote.usd_debt); // 1000
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward; // 5%
    let assets_in_usd = manager_info.base.usd_asset + manager_info.quote.usd_asset; // 1100

    let numerator = math::mul(target_ratio, debt_in_usd) - assets_in_usd; // 1250 - 1100 = 150
    let denominator = target_ratio - (constants::float_scaling() + liquidation_reward); // 1.25 - 1.05 = 0.2

    math::div(numerator, denominator) // 750
}

public(package) fun calculate_usd_exit_amounts(
    manager_info: &ManagerInfo,
    total_usd_to_exit: u64,
): (u64, u64) {
    let (base_usd, quote_usd) = if (manager_info.base.debt > 0) {
        let base_usd = total_usd_to_exit.min(manager_info.base.usd_asset);
        let total_usd_to_exit = total_usd_to_exit - base_usd;
        let quote_usd = total_usd_to_exit.min(manager_info.quote.usd_asset);
        (base_usd, quote_usd)
    } else {
        let quote_usd = total_usd_to_exit.min(manager_info.quote.usd_asset);
        let total_usd_to_exit = total_usd_to_exit - quote_usd;
        let base_usd = total_usd_to_exit.min(manager_info.base.usd_asset);
        (base_usd, quote_usd)
    };

    (base_usd, quote_usd)
}

public(package) fun calculate_quantity_to_exit(
    manager_info: &ManagerInfo,
    usd_amount_to_repay: u64,
): (u64, u64) {
    let mut base_to_exit_usd = 0;
    let mut quote_to_exit_usd = 0;
    let usd_amount_to_repay_with_reward = manager_info.with_liquidation_reward_ratio(
        usd_amount_to_repay,
    ); // 750 * 1.05 = 787.5

    let base_usd_asset = manager_info.base.usd_asset; // 550
    let quote_usd_asset = manager_info.quote.usd_asset; // 550

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

    let (base_to_exit, quote_to_exit) = manager_info.calculate_asset_amounts(
        base_to_exit_usd,
        quote_to_exit_usd,
    ); // base_to_exit = 550, quote_to_exit = 237.5

    (base_to_exit, quote_to_exit)
}

/// Calculate liquidation amounts with USD pricing logic
/// This centralizes all oracle-dependent calculations for liquidation
public(package) fun calculate_liquidation_amounts<DebtAsset>(
    manager_info: &ManagerInfo,
    liquidation_coin: &Coin<DebtAsset>,
): LiquidationAmounts {
    let max_usd_amount_to_repay = manager_info.calculate_usd_amount_to_repay();

    let debt_is_base = manager_info.base.debt > 0;

    // Get debt and asset totals
    let debt = manager_info.base.debt.max(manager_info.quote.debt);
    let assets_in_usd = manager_info.base.usd_asset + manager_info.quote.usd_asset; // $1100

    // Calculate ratios once
    let total_liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward; // 5%
    let float_scaling = constants::float_scaling();
    let pool_reward_ratio = float_scaling + manager_info.pool_liquidation_reward; // 1.03
    let liquidation_reward_ratio = float_scaling + total_liquidation_reward; // 1.05

    // Get liquidation coin value in USD
    let debt_per_dollar = if (debt_is_base) manager_info.base_per_dollar
    else manager_info.quote_per_dollar;
    let coin_in_usd = math::div(liquidation_coin.value(), debt_per_dollar); // $700
    let coin_in_usd_minus_pool_reward = math::div(coin_in_usd, pool_reward_ratio); // $679.61

    // Handle default cases
    let in_default = manager_info.risk_ratio() < float_scaling;
    let max_repay_usd = if (in_default) {
        math::div(assets_in_usd, liquidation_reward_ratio)
    } else {
        max_usd_amount_to_repay
    }; // $750

    // Calculate final repay amounts
    let repay_usd = max_repay_usd.min(coin_in_usd_minus_pool_reward); // $679.61
    let loan_defaulted = in_default && repay_usd == max_repay_usd;

    let repay_amount = math::mul(repay_usd, debt_per_dollar); // 679.61 USDT
    let repay_amount_with_pool_reward = math::mul(repay_amount, pool_reward_ratio); // 699.99 USDT
    let pool_reward_amount = repay_amount_with_pool_reward - repay_amount; // 20.38 USDT
    let default_amount = if (loan_defaulted) debt - repay_amount else 0;

    LiquidationAmounts {
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        repay_usd,
        repay_amount_with_pool_reward,
    }
}

public(package) fun calculate_asset_amounts(
    manager_info: &ManagerInfo,
    base_usd: u64,
    quote_usd: u64,
): (u64, u64) {
    (
        math::mul(base_usd, manager_info.base_per_dollar),
        math::mul(quote_usd, manager_info.quote_per_dollar),
    )
}

/// Convert USD amount to debt asset amount using oracle pricing
public(package) fun calculate_debt_repay_amount(
    manager_info: &ManagerInfo,
    debt_is_base: bool,
    usd_amount: u64,
): u64 {
    let debt_per_dollar = if (debt_is_base) {
        manager_info.base_per_dollar
    } else {
        manager_info.quote_per_dollar
    };

    math::mul(usd_amount, debt_per_dollar)
}

public(package) fun user_liquidation_reward(manager_info: &ManagerInfo): u64 {
    manager_info.user_liquidation_reward
}

public(package) fun pool_liquidation_reward(manager_info: &ManagerInfo): u64 {
    manager_info.pool_liquidation_reward
}
