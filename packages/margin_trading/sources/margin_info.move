// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module containing data structures for margin trading information
module margin_trading::margin_info;

use deepbook::{constants, math};
use margin_trading::{
    margin_constants,
    margin_registry::MarginRegistry,
    oracle::calculate_usd_price
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
    base: AssetInfo, // Base asset information
    quote: AssetInfo, // Quote asset information
    risk_ratio: u64, // Risk ratio with 9 decimals
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
