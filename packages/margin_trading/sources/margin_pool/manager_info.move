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

public(package) fun produce_fulfillment(self: &ManagerInfo, manager_id: ID): Fulfillment {
    let usd_to_repay_with_rewards = self.calculate_usd_amount_to_repay();
    let repay_usd_with_rewards = self.asset_usd.min(usd_to_repay_with_rewards);
    let liquidation_reward = self.user_liquidation_reward + self.pool_liquidation_reward;
    let liquidation_reward_ratio = constants::float_scaling() + liquidation_reward;

    let usd_to_repay = math::div(repay_usd_with_rewards, liquidation_reward_ratio);
    let mut pool_reward_usd = math::mul(usd_to_repay, self.pool_liquidation_reward);

    let in_default = self.debt_usd > self.asset_usd;
    let default_usd = if (in_default) {
        let default_usd = self.debt_usd - usd_to_repay;
        let cancel = default_usd.min(pool_reward_usd);
        pool_reward_usd = pool_reward_usd - cancel;
        default_usd - cancel
    } else {
        0
    };

    let base_usd_asset = self.base.usd_asset;
    let quote_usd_asset = self.quote.usd_asset;
    let (base_usd, quote_usd) = if (self.base.debt > 0) {
        let base_usd = repay_usd_with_rewards.min(base_usd_asset);
        let repay_usd_with_rewards = repay_usd_with_rewards - base_usd;
        let quote_usd = repay_usd_with_rewards.min(quote_usd_asset);
        (base_usd, quote_usd)
    } else {
        let quote_usd = repay_usd_with_rewards.min(quote_usd_asset);
        let repay_usd_with_rewards = repay_usd_with_rewards - quote_usd;
        let base_usd = repay_usd_with_rewards.min(base_usd_asset);
        (base_usd, quote_usd)
    };

    let repay_amount = math::mul(usd_to_repay, self.debt_per_dollar);
    let pool_reward_amount = math::mul(pool_reward_usd, self.debt_per_dollar);
    let default_amount = math::mul(default_usd, self.debt_per_dollar);
    let base_exit_amount = math::mul(base_usd, self.base_per_dollar);
    let quote_exit_amount = math::mul(quote_usd, self.quote_per_dollar);

    Fulfillment {
        manager_id,
        repay_amount,
        pool_reward_amount,
        default_amount,
        base_exit_amount,
        quote_exit_amount,
        risk_ratio: self.risk_ratio,
    }
}

public(package) fun calculate_usd_amount_to_repay(manager_info: &ManagerInfo): u64 {
    let target_ratio = manager_info.target_ratio; // 1.25
    let debt_in_usd = manager_info.base.usd_debt.max(manager_info.quote.usd_debt); // 1000
    let liquidation_reward =
        manager_info.user_liquidation_reward + manager_info.pool_liquidation_reward; // 5%
    let assets_in_usd = manager_info.base.usd_asset + manager_info.quote.usd_asset; // 1100
    let numerator = math::mul(target_ratio, debt_in_usd) - assets_in_usd; // 1250 - 1100 = 150
    let denominator = target_ratio - (constants::float_scaling() + liquidation_reward); // 1.25 - 1.05 = 0.2
    let usd_to_repay = math::div(numerator, denominator); // 750

    math::mul(usd_to_repay, constants::float_scaling() + liquidation_reward)
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
