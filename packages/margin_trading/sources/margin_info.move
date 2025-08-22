// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module containing data structures for margin trading information
#[allow(duplicate_alias)]
module margin_trading::margin_info;

use deepbook::{constants, math};
use margin_trading::{
    margin_constants,
    margin_registry::MarginRegistry,
    oracle::{calculate_usd_price, calculate_target_amount}
};
use pyth::price_info::PriceInfoObject;
use sui::{clock::Clock, coin::Coin, object::ID};

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
}

/// Raw position data without USD calculations
public struct PositionInfo has copy, drop {
    base_debt: u64,
    quote_debt: u64,
    base_asset: u64,
    quote_asset: u64,
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

/// Create a new AssetInfo struct
public fun new_asset_info(asset: u64, debt: u64, usd_asset: u64, usd_debt: u64): AssetInfo {
    AssetInfo {
        asset,
        debt,
        usd_asset,
        usd_debt,
    }
}

/// Create a new ManagerInfo struct
public fun new_manager_info(base: AssetInfo, quote: AssetInfo, risk_ratio: u64): ManagerInfo {
    ManagerInfo {
        base,
        quote,
        risk_ratio,
    }
}

/// Create a new PositionInfo struct
public fun new_position_info(
    base_debt: u64,
    quote_debt: u64,
    base_asset: u64,
    quote_asset: u64,
): PositionInfo {
    PositionInfo {
        base_debt,
        quote_debt,
        base_asset,
        quote_asset,
    }
}

/// Create a new LiquidationAmounts struct
public fun new_liquidation_amounts(
    debt_is_base: bool,
    repay_amount: u64,
    pool_reward_amount: u64,
    default_amount: u64,
    repay_usd: u64,
    repay_amount_with_pool_reward: u64,
): LiquidationAmounts {
    LiquidationAmounts {
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        repay_usd,
        repay_amount_with_pool_reward,
    }
}

/// Returns the risk ratio from the ManagerInfo
public fun risk_ratio(manager_info: &ManagerInfo): u64 {
    manager_info.risk_ratio
}

/// Returns the base and quote AssetInfo from the ManagerInfo
public fun asset_info(manager_info: &ManagerInfo): (AssetInfo, AssetInfo) {
    (manager_info.base, manager_info.quote)
}

/// Returns the base AssetInfo from the ManagerInfo
public fun base_info(manager_info: &ManagerInfo): AssetInfo {
    manager_info.base
}

/// Returns the quote AssetInfo from the ManagerInfo
public fun quote_info(manager_info: &ManagerInfo): AssetInfo {
    manager_info.quote
}

/// Get asset amount from AssetInfo
public fun asset_amount(asset_info: &AssetInfo): u64 {
    asset_info.asset
}

/// Get debt amount from AssetInfo
public fun debt_amount(asset_info: &AssetInfo): u64 {
    asset_info.debt
}

/// Get USD asset value from AssetInfo
public fun usd_asset_amount(asset_info: &AssetInfo): u64 {
    asset_info.usd_asset
}

/// Get USD debt value from AssetInfo
public fun usd_debt_amount(asset_info: &AssetInfo): u64 {
    asset_info.usd_debt
}

/// Returns the details in PositionInfo as a tuple
public fun position_info(position_info: &PositionInfo): (u64, u64, u64, u64) {
    (
        position_info.base_debt,
        position_info.quote_debt,
        position_info.base_asset,
        position_info.quote_asset,
    )
}

/// Calculate ManagerInfo from raw asset/debt data and oracle information
/// This centralizes all USD calculation and risk ratio computation logic
public fun calculate_manager_info<BaseAsset, QuoteAsset>(
    base_asset: u64,
    quote_asset: u64,
    base_debt: u64,
    quote_debt: u64,
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    clock: &Clock,
): ManagerInfo {
    // Calculate debt in USD
    let base_usd_debt = if (base_debt > 0) {
        calculate_usd_price<BaseAsset>(
            base_price_info_object,
            registry,
            base_debt,
            clock,
        )
    } else {
        0
    };

    let quote_usd_debt = if (quote_debt > 0) {
        calculate_usd_price<QuoteAsset>(
            quote_price_info_object,
            registry,
            quote_debt,
            clock,
        )
    } else {
        0
    };

    // Calculate asset values in USD
    let base_usd_asset = calculate_usd_price<BaseAsset>(
        base_price_info_object,
        registry,
        base_asset,
        clock,
    );

    let quote_usd_asset = calculate_usd_price<QuoteAsset>(
        quote_price_info_object,
        registry,
        quote_asset,
        clock,
    );

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
    new_manager_info(
        new_asset_info(base_asset, base_debt, base_usd_asset, base_usd_debt),
        new_asset_info(quote_asset, quote_debt, quote_usd_asset, quote_usd_debt),
        risk_ratio,
    )
}

/// Calculate liquidation amounts with USD pricing logic
/// This centralizes all oracle-dependent calculations for liquidation
public fun calculate_liquidation_amounts<DebtAsset>(
    manager_info: &ManagerInfo,
    registry: &MarginRegistry,
    pool_id: ID,
    liquidation_coin: &Coin<DebtAsset>,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    user_liquidation_reward: u64,
    pool_liquidation_reward: u64,
    clock: &Clock,
): LiquidationAmounts {
    let base_info = manager_info.base_info();
    let quote_info = manager_info.quote_info();

    let debt_is_base = base_info.debt_amount() > 0;

    // Get debt and asset totals
    let debt = base_info.debt_amount().max(quote_info.debt_amount());
    let debt_in_usd = base_info.usd_debt_amount().max(quote_info.usd_debt_amount()); // 1000 USDT
    let assets_in_usd = base_info.usd_asset_amount() + quote_info.usd_asset_amount(); // $1100

    // Calculate ratios once
    let target_ratio = registry.target_liquidation_risk_ratio(pool_id); // 1.25
    let total_liquidation_reward = user_liquidation_reward + pool_liquidation_reward; // 5%
    let float_scaling = constants::float_scaling();
    let pool_reward_ratio = float_scaling + pool_liquidation_reward; // 1.03
    let liquidation_reward_ratio = float_scaling + total_liquidation_reward; // 1.05

    // Calculate maximum USD to repay for target ratio
    let numerator = math::mul(target_ratio, debt_in_usd) - assets_in_usd; // 150
    let denominator = target_ratio - liquidation_reward_ratio; // 0.2
    let max_usd_amount_to_repay = math::div(numerator, denominator); // 750

    // Get liquidation coin value in USD
    let debt_oracle = if (debt_is_base) base_price_info_object else quote_price_info_object;
    let coin_in_usd = calculate_usd_price<DebtAsset>(
        debt_oracle,
        registry,
        liquidation_coin.value(),
        clock,
    ); // $700
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

    let repay_amount = calculate_target_amount<DebtAsset>(debt_oracle, registry, repay_usd, clock); // 679.61 USDT
    let repay_amount_with_pool_reward = math::mul(repay_amount, pool_reward_ratio); // 699.99 USDT
    let pool_reward_amount = repay_amount_with_pool_reward - repay_amount; // 20.38 USDT

    let default_amount = if (loan_defaulted) debt - repay_amount else 0;

    new_liquidation_amounts(
        debt_is_base,
        repay_amount,
        pool_reward_amount,
        default_amount,
        repay_usd,
        repay_amount_with_pool_reward,
    )
}

/// Destructure LiquidationAmounts for use outside the module
public fun liquidation_amounts_info(amounts: &LiquidationAmounts): (bool, u64, u64, u64, u64, u64) {
    (
        amounts.debt_is_base,
        amounts.repay_amount,
        amounts.pool_reward_amount,
        amounts.default_amount,
        amounts.repay_usd,
        amounts.repay_amount_with_pool_reward,
    )
} /// Convert USD amounts to asset amounts using oracle pricing

public fun calculate_asset_amounts<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    base_usd: u64,
    quote_usd: u64,
    clock: &Clock,
): (u64, u64) {
    (
        calculate_target_amount<BaseAsset>(base_price_info_object, registry, base_usd, clock),
        calculate_target_amount<QuoteAsset>(quote_price_info_object, registry, quote_usd, clock),
    )
}

/// Convert USD amount to debt asset amount using oracle pricing
public fun calculate_debt_repay_amount<DebtAsset>(
    registry: &MarginRegistry,
    base_price_info_object: &PriceInfoObject,
    quote_price_info_object: &PriceInfoObject,
    debt_is_base: bool,
    usd_amount: u64,
    clock: &Clock,
): u64 {
    let debt_oracle = if (debt_is_base) {
        base_price_info_object
    } else {
        quote_price_info_object
    };

    calculate_target_amount<DebtAsset>(
        debt_oracle,
        registry,
        usd_amount,
        clock,
    )
}
