// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only, allow(unused_use)]
module margin_trading::margin_pool_math_tests;

use margin_trading::{
    margin_constants,
    margin_pool::MarginPool,
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap, MarginPoolCap},
    test_constants::{Self, USDC, USDT},
    test_helpers::{Self, mint_coin, advance_time}
};
use sui::{
    clock::Clock,
    coin::Coin,
    test_scenario::{Self as test, Scenario, return_shared},
    test_utils::destroy
};

fun setup_test(): (Scenario, Clock, MarginAdminCap, MaintainerCap, ID) {
    let (mut scenario, admin_cap) = test_helpers::setup_test();

    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let clock = scenario.take_shared<Clock>();
    let maintainer_cap = margin_registry::mint_maintainer_cap(
        &mut registry,
        &admin_cap,
        &clock,
        scenario.ctx(),
    );
    test::return_shared(registry);

    let protocol_config = test_helpers::default_protocol_config();
    let pool_id = test_helpers::create_margin_pool<USDC>(
        &mut scenario,
        &maintainer_cap,
        protocol_config,
        &clock,
    );

    (scenario, clock, admin_cap, maintainer_cap, pool_id)
}

fun cleanup_test(
    registry: MarginRegistry,
    admin_cap: MarginAdminCap,
    maintainer_cap: MaintainerCap,
    clock: Clock,
    scenario: Scenario,
) {
    return_shared(registry);
    destroy(admin_cap);
    destroy(maintainer_cap);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_borrow_supply_interest_correct() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // At time 0, user1 supplies 100 USDC. User 2 borrows 50 USDC.
    scenario.next_tx(test_constants::user1());
    let coin = mint_coin<USDC>(100 * test_constants::usdc_multiplier(), scenario.ctx());
    pool.supply(&registry, coin, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user2());
    let borrowed_coin = pool.borrow(
        50 * test_constants::usdc_multiplier(),
        &clock,
        scenario.ctx(),
    );
    assert!(borrowed_coin.value() == 50 * test_constants::usdc_multiplier());
    destroy(borrowed_coin);

    // 1 year passes
    // Interest should be 5% + 0.1 * 50% = 10%
    // Repayment should be 55 USDC for user 2
    advance_time(&mut clock, margin_constants::year_ms());
    scenario.next_tx(test_constants::user2());
    let repay_coin = mint_coin<USDC>(55 * test_constants::usdc_multiplier(), scenario.ctx());
    pool.repay(repay_coin, &clock);

    // User 1 withdraws his entire balance
    // Protocol spread is 10% of the 5 interest paid. user 1 should receive 104.5 USDC.
    scenario.next_tx(test_constants::user1());
    let withdrawn_coin = pool.withdraw(&registry, option::none(), &clock, scenario.ctx());
    assert!(withdrawn_coin.value() == 104_500_000 - 1); // -1 offset for precision loss
    destroy(withdrawn_coin);

    // Admin withdraws protocol profits
    // Admin should receive 0.5 USDC
    scenario.next_tx(test_constants::admin());
    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();
    let protocol_profit = pool.withdraw_protocol_profit(
        &registry,
        &margin_pool_cap,
        &clock,
        scenario.ctx(),
    );
    assert!(protocol_profit.value() == 500_000); // -1 offset for precision loss
    destroy(protocol_profit);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
