// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::margin_pool_tests;

use margin_trading::{
    margin_pool::{Self, MarginPool},
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap, MarginPoolCap},
    protocol_config,
    test_constants::{Self, USDC, USDT},
    test_helpers::{Self, mint_coin}
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

public fun test_borrow<Asset>(
    pool: &mut MarginPool<Asset>,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Asset> {
    pool.borrow(amount, clock, ctx)
}

#[test]
fun test_supply_and_withdraw_basic() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens with 9 decimals
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    let withdrawn = pool.withdraw<USDC>(
        &registry,
        option::some(50_000_000_000),
        &clock,
        scenario.ctx(),
    ); // 50 tokens
    assert!(withdrawn.value() == 50_000_000_000);

    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ESupplyCapExceeded)]
fun test_supply_cap_enforcement() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(test_constants::supply_cap() + 1, scenario.ctx());

    // This should fail due to supply cap
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_multiple_users_supply_withdraw() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    // User1 supplies
    scenario.next_tx(test_constants::user1());
    let supply_coin1 = mint_coin<USDC>(50_000_000_000, scenario.ctx()); // 50 tokens
    pool.supply<USDC>(&registry, supply_coin1, &clock, scenario.ctx());

    // User2 supplies
    scenario.next_tx(test_constants::user2());
    let supply_coin2 = mint_coin<USDC>(30_000_000_000, scenario.ctx()); // 30 tokens
    pool.supply<USDC>(&registry, supply_coin2, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user1());
    let withdrawn1 = pool.withdraw<USDC>(
        &registry,
        option::some(25_000_000_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 25_000_000_000);

    scenario.next_tx(test_constants::user2());
    let withdrawn2 = pool.withdraw<USDC>(
        &registry,
        option::some(15_000_000_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 15_000_000_000);

    destroy(withdrawn1);
    destroy(withdrawn2);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_withdraw_all() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_amount = 100_000_000_000; // 100 tokens
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());
    assert!(withdrawn.value() == supply_amount);

    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ECannotWithdrawMoreThanSupply)]
fun test_withdraw_more_than_supplied() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(50_000_000_000, scenario.ctx()); // 50 tokens
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    let withdrawn = pool.withdraw<USDC>(
        &registry,
        option::some(60_000_000_000),
        &clock,
        scenario.ctx(),
    );

    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_create_margin_pool_with_config() {
    let (mut scenario, clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    scenario.next_tx(test_constants::admin());
    let pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test]
fun test_interest_accrual_over_time() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();
    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_amount = 100_000_000_000; // 100 tokens
    let supply_coin = mint_coin<USDC>(supply_amount, scenario.ctx());
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    // Advance time by 1 day
    clock.set_for_testing(1000 + 86400000);

    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());
    assert!(withdrawn.value() >= supply_amount);

    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::ENotEnoughAssetInPool)]
fun test_not_enough_asset_in_pool() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(&mut pool, 80_000_000_000, &clock, scenario.ctx()); // 80 tokens
    destroy(borrowed_coin);

    // Should fail due to outstanding loan
    scenario.next_tx(test_constants::user1());
    let withdrawn = pool.withdraw<USDC>(&registry, option::none(), &clock, scenario.ctx());

    destroy(withdrawn);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[
    test,
    expected_failure(
        abort_code = margin_trading::margin_pool::EMaxPoolBorrowPercentageExceeded,
    ),
]
fun test_max_pool_borrow_percentage_exceeded() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();
    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    // Above max utilization rate
    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(&mut pool, 85_000_000_000, &clock, scenario.ctx()); // 85 tokens > 80%

    destroy(borrowed_coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EInvalidLoanQuantity)]
fun test_invalid_loan_quantity() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    scenario.next_tx(test_constants::user1());
    let supply_coin = mint_coin<USDC>(100_000_000_000, scenario.ctx()); // 100 tokens
    pool.supply<USDC>(&registry, supply_coin, &clock, scenario.ctx());

    scenario.next_tx(test_constants::user2());
    let borrowed_coin = test_borrow(&mut pool, 0, &clock, scenario.ctx());

    destroy(borrowed_coin);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EDeepbookPoolAlreadyAllowed)]
fun test_deepbook_pool_already_allowed() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    clock.set_for_testing(1000);

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
    let registry = scenario.take_shared<MarginRegistry>();

    let margin_pool_cap = scenario.take_from_sender<MarginPoolCap>();

    let deepbook_pool_id = object::id_from_address(@0x123);

    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &margin_pool_cap, &clock);

    scenario.return_to_sender(margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}

#[test, expected_failure(abort_code = margin_trading::margin_pool::EInvalidMarginPoolCap)]
fun test_invalid_margin_pool_cap() {
    let (mut scenario, mut clock, admin_cap, maintainer_cap, pool_id) = setup_test();

    clock.set_for_testing(1000);

    // Create a second margin pool to get a different MarginPoolCap
    scenario.next_tx(test_constants::admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let margin_pool_config2 = protocol_config::new_margin_pool_config(
        500_000_000_000, // Different supply cap
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
    );
    let interest_config2 = protocol_config::new_interest_config(
        50_000_000,
        100_000_000,
        800_000_000,
        2_000_000_000,
    );
    let protocol_config2 = protocol_config::new_protocol_config(
        margin_pool_config2,
        interest_config2,
    );
    let _pool_id2 = margin_pool::create_margin_pool<USDT>(
        &mut registry,
        protocol_config2,
        &maintainer_cap,
        &clock,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::admin());
    let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);

    let wrong_margin_pool_cap = scenario.take_from_sender<MarginPoolCap>(); // This cap belongs to pool2, not pool

    let deepbook_pool_id = object::id_from_address(@0x123);

    // Try to use wrong cap with the first pool (should fail)
    pool.enable_deepbook_pool_for_loan(&registry, deepbook_pool_id, &wrong_margin_pool_cap, &clock);

    scenario.return_to_sender(wrong_margin_pool_cap);
    test::return_shared(pool);
    cleanup_test(registry, admin_cap, maintainer_cap, clock, scenario);
}
