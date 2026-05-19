// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{oracle_config, range_key, vault};
use sui::{clock, test_scenario};

#[test]
fun test_vault_balances() {
    let mut scenario = test_scenario::begin(@0x1);
    let mut vault = vault::new(scenario.ctx());

    assert!(vault.balance() == 0, 0);

    // Initial deposit
    let coin = sui::coin::mint_for_testing<sui::sui::SUI>(1000, scenario.ctx());
    vault.accept_payment(coin);
    assert!(vault.balance() == 1000, 1);
    assert!(vault.asset_balance<sui::sui::SUI>() == 1000, 2);

    // Payout
    let payout = vault.dispense_payout<sui::sui::SUI>(400, scenario.ctx());
    assert!(payout.value() == 400, 3);
    assert!(vault.balance() == 600, 4);

    sui::coin::burn_for_testing(payout);
    test_scenario::return_shared(vault);
    scenario.end();
}

#[test]
fun test_vault_exposure() {
    let mut scenario = test_scenario::begin(@0x1);
    let mut vault = vault::new(scenario.ctx());
    let clk = clock::create_for_testing(scenario.ctx());

    let oracle_id = @0x123.to_id();
    let min_strike = 1000;
    let max_strike = 2000;
    let tick_size = 100;
    let expiry = 5000;

    vault.init_oracle_matrix(oracle_id, min_strike, max_strike, tick_size, &clk, scenario.ctx());

    let key = range_key::new(oracle_id, expiry, 1200, 1500);
    // Fair price = 0.5 (placeholder)
    let curve = vector[
        oracle_config::new_curve_point(1200, 500_000_000),
        oracle_config::new_curve_point(1500, 500_000_000),
    ];

    vault.insert_live_range(key, 100, curve, &clk);
    
    assert!(vault.total_mtm() > 0, 5);
    assert!(vault.total_max_payout() == 100, 6);

    clk.destroy_for_testing();
    test_scenario::return_shared(vault);
    scenario.end();
}
