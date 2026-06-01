// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored risk configuration for liquidation budgets.
///
/// ProtocolConfig owns this mutable policy. Expiry markets read liquidation
/// budgets before valuation and trade flows.
module deepbook_predict::risk_config;

use deepbook_predict::config_constants;

/// Liquidation maintenance policy.
public struct RiskConfig has store {
    /// Total liquidation candidates checked before live pool valuation.
    valuation_liquidation_budget: u64,
    /// Total liquidation candidates checked before mint and redeem flows.
    trade_liquidation_budget: u64,
}

// === Public-Package Functions ===

public(package) fun valuation_liquidation_budget(config: &RiskConfig): u64 {
    config.valuation_liquidation_budget
}

public(package) fun trade_liquidation_budget(config: &RiskConfig): u64 {
    config.trade_liquidation_budget
}

public(package) fun new(): RiskConfig {
    RiskConfig {
        valuation_liquidation_budget: config_constants::default_valuation_liquidation_budget!(),
        trade_liquidation_budget: config_constants::default_trade_liquidation_budget!(),
    }
}

public(package) fun set_valuation_liquidation_budget(config: &mut RiskConfig, budget: u64) {
    config_constants::assert_valuation_liquidation_budget(budget);
    config.valuation_liquidation_budget = budget;
}

public(package) fun set_trade_liquidation_budget(config: &mut RiskConfig, budget: u64) {
    config_constants::assert_trade_liquidation_budget(budget);
    config.trade_liquidation_budget = budget;
}
