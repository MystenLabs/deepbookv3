// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_tests;

use deepbook_predict::{market_key, oracle, predict, predict_manager, registry::{Self, AdminCap, Registry}};
use sui::{clock::{Self, Clock}, coin, test_scenario::{Self, Scenario}};
use std::string;

public struct USDC has drop {}

fun setup_registry(scenario: &mut Scenario): (Registry, AdminCap) {
    let registry_id = registry::init_for_testing(scenario.ctx());
    scenario.next_tx(@0x1);
    let registry = scenario.take_shared_by_id<Registry>(registry_id);
    let admin_cap = scenario.take_from_sender<AdminCap>();
    (registry, admin_cap)
}

#[test]
fun test_end_to_end_trading() {
    let admin = @0xAD;
    let trader = @0x74;
    let operator = @0x09;
    let mut scenario = test_scenario::begin(admin);
    
    let (mut registry, admin_cap) = setup_registry(&mut scenario);
    let clk = clock::create_for_testing(scenario.ctx());

    // 1. Create Predict shared object
    scenario.next_tx(admin);
    let currency = sui::coin_registry::create_currency_for_testing<USDC>(scenario.ctx());
    let lp_treasury_cap = coin::create_treasury_cap_for_testing<deepbook_predict::plp::PLP>(scenario.ctx());
    
    registry.create_predict<USDC>(&admin_cap, &currency, lp_treasury_cap, &clk, scenario.ctx());
    
    scenario.next_tx(admin);
    let mut predict = scenario.take_shared<predict::Predict>();

    // 2. Setup Oracle
    scenario.next_tx(admin);
    let oracle_cap = registry.create_oracle_cap(&admin_cap, scenario.ctx());
    sui::transfer::public_transfer(oracle_cap, operator);
    
    scenario.next_tx(admin);
    predict.set_asset_feed_id(&admin_cap, string::utf8(b"SUI"), 1);

    scenario.next_tx(operator);
    let operator_cap = scenario.take_from_sender<oracle::OracleSVICap>();
    let oracle_id = registry.create_oracle(
        &mut predict,
        &operator_cap,
        string::utf8(b"SUI"),
        10000, // expiry
        100,   // min strike
        10,    // tick size
        &clk,
        scenario.ctx()
    );

    scenario.next_tx(operator);
    let mut oracle = scenario.take_shared_by_id<oracle::OracleSVI>(oracle_id);
    
    // Initial price push
    oracle.update_prices(
        &operator_cap,
        500, // spot
        500, // forward
        &clk
    );

    // 3. Trader actions
    scenario.next_tx(trader);
    let mut manager = registry.create_manager(scenario.ctx());
    
    // Deposit some USDC
    let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
    manager.deposit(coin, scenario.ctx());

    // Mint UP position
    let up_key = market_key::new(oracle_id, 10000, 500, true);
    predict.mint<USDC>(&mut manager, &oracle, up_key, 100, &clk, scenario.ctx());

    let (free, locked) = manager.position(up_key);
    assert!(free == 100, 10);

    // Mint collateralized
    let down_key = market_key::new(oracle_id, 10000, 500, false);
    predict.mint_collateralized<USDC>(&mut manager, &oracle, up_key, down_key, 50, &clk, scenario.ctx());

    let (up_free, up_locked) = manager.position(up_key);
    assert!(up_free == 150 && up_locked == 50, 11);

    // Cleanup
    scenario.next_tx(admin);
    predict_manager::share(manager);
    test_scenario::return_shared(predict);
    test_scenario::return_shared(oracle);
    test_scenario::return_shared(registry);
    scenario.return_to_sender(admin_cap);
    scenario.return_to_address(operator, operator_cap);
    clk.destroy_for_testing();
    scenario.end();
}
