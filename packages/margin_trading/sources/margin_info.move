// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module containing data structures for margin trading information
module margin_trading::margin_info;

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

/// Returns (asset, debt, usd_asset, usd_debt) from AssetInfo
public fun asset_debt_amount(asset_info: &AssetInfo): (u64, u64, u64, u64) {
    (asset_info.asset, asset_info.debt, asset_info.usd_asset, asset_info.usd_debt)
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
