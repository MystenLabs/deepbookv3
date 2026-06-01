// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::risk_config_tests;

use deepbook_predict::{config_constants, risk_config};
use std::unit_test::{assert_eq, destroy};

const VALID_VALUATION_BUDGET: u64 = 256;
const VALID_TRADE_BUDGET: u64 = 48;

// === Construction and getters ===

#[test]
fun defaults_match_config_constants() {
    let config = risk_config::new();
    assert_eq!(
        config.valuation_liquidation_budget(),
        config_constants::default_valuation_liquidation_budget!(),
    );
    assert_eq!(
        config.trade_liquidation_budget(),
        config_constants::default_trade_liquidation_budget!(),
    );
    destroy(config);
}

// === set_valuation_liquidation_budget ===

#[test]
fun set_valuation_liquidation_budget_updates() {
    let mut config = risk_config::new();
    config.set_valuation_liquidation_budget(VALID_VALUATION_BUDGET);
    assert_eq!(config.valuation_liquidation_budget(), VALID_VALUATION_BUDGET);
    destroy(config);
}

#[test]
fun set_valuation_liquidation_budget_accepts_endpoints() {
    let mut config = risk_config::new();
    config.set_valuation_liquidation_budget(config_constants::min_valuation_liquidation_budget!());
    assert_eq!(
        config.valuation_liquidation_budget(),
        config_constants::min_valuation_liquidation_budget!(),
    );
    config.set_valuation_liquidation_budget(config_constants::max_valuation_liquidation_budget!());
    assert_eq!(
        config.valuation_liquidation_budget(),
        config_constants::max_valuation_liquidation_budget!(),
    );
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidValuationLiquidationBudget)]
fun set_valuation_liquidation_budget_below_min_aborts() {
    let mut config = risk_config::new();
    config.set_valuation_liquidation_budget(
        config_constants::min_valuation_liquidation_budget!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidValuationLiquidationBudget)]
fun set_valuation_liquidation_budget_above_max_aborts() {
    let mut config = risk_config::new();
    config.set_valuation_liquidation_budget(
        config_constants::max_valuation_liquidation_budget!() + 1,
    );
    abort 999
}

// === set_trade_liquidation_budget ===

#[test]
fun set_trade_liquidation_budget_updates() {
    let mut config = risk_config::new();
    config.set_trade_liquidation_budget(VALID_TRADE_BUDGET);
    assert_eq!(config.trade_liquidation_budget(), VALID_TRADE_BUDGET);
    destroy(config);
}

#[test]
fun set_trade_liquidation_budget_accepts_endpoints() {
    let mut config = risk_config::new();
    config.set_trade_liquidation_budget(config_constants::min_trade_liquidation_budget!());
    assert_eq!(
        config.trade_liquidation_budget(),
        config_constants::min_trade_liquidation_budget!(),
    );
    config.set_trade_liquidation_budget(config_constants::max_trade_liquidation_budget!());
    assert_eq!(
        config.trade_liquidation_budget(),
        config_constants::max_trade_liquidation_budget!(),
    );
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun set_trade_liquidation_budget_below_min_aborts() {
    let mut config = risk_config::new();
    config.set_trade_liquidation_budget(config_constants::min_trade_liquidation_budget!() - 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun set_trade_liquidation_budget_above_max_aborts() {
    let mut config = risk_config::new();
    config.set_trade_liquidation_budget(config_constants::max_trade_liquidation_budget!() + 1);
    abort 999
}
