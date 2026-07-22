// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards for ProtocolConfig-owned aggregate policy.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__protocol_config_tests;

use deepbook_predict::{config_constants, test_values, test_world};
use sui::test_scenario::return_shared;

#[test, expected_failure(abort_code = config_constants::EInvalidProtocolReserveProfitShare)]
fun reserve_profit_share_one_above_full_aborts() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_protocol_reserve_profit_share(&admin_cap, 1_000_000_001);
    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun trade_liquidation_budget_one_below_minimum_aborts() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_trade_liquidation_budget(&admin_cap, 23);
    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidTradeLiquidationBudget)]
fun trade_liquidation_budget_one_above_maximum_aborts() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut config = test_world::take_config(&world);
    config.set_trade_liquidation_budget(&admin_cap, 3_001);
    return_shared(config);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}
