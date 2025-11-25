#[test_only]
module deepbook_margin::rate_limiter_tests;

use deepbook_margin::{
    margin_pool::{Self, MarginPool},
    margin_registry::MarginRegistry,
    test_constants::{USDC, admin, user1},
    test_helpers::{Self, return_shared_2, destroy_3, destroy_4}
};
use sui::{clock, coin, test_scenario, test_utils::destroy};

const HOUR_MS: u64 = 3_600_000;

#[test]
fun test_basic_rate_limiting() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    // capacity = 10_000, refill_rate = 10 per ms (full refill in 1000ms = 1 second)
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000, // supply cap
        10_000, // capacity
        10, // refill_rate_per_ms (10K per second)
        true, // enabled
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    // Supply $20K
    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // Withdraw $10K (at the limit)
    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 10_000, 0);

    // Should not be able to withdraw more (bucket is empty)
    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 0, 1);

    destroy_3!(withdrawn1, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_capacity_refills_over_time() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    // capacity = 10_000, refill_rate = 10 per ms
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000, // capacity
        10, // refill 10 per ms
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(30_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // Withdraw full capacity
    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 10_000, 0);

    // Bucket is now empty
    assert!(pool.get_available_withdrawal(&clock) == 0, 1);

    // Wait 500ms - should have 5000 available (500 * 10 = 5000)
    clock::increment_for_testing(&mut clock, 500);

    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 5_000, 2);

    // Withdraw 5000
    let withdrawn2 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(5_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 5_000, 3);

    // Wait another 1000ms - should be back to full capacity (10_000)
    clock::increment_for_testing(&mut clock, 1_000);
    let available_after = pool.get_available_withdrawal(&clock);
    assert!(available_after == 10_000, 4);

    destroy_4!(withdrawn1, withdrawn2, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_capacity_caps_at_max() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000, // capacity
        10, // refill rate
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // Wait a very long time - capacity should cap at max (10_000)
    clock::increment_for_testing(&mut clock, 10 * HOUR_MS);

    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 10_000, 0);

    // Withdraw exactly capacity
    let withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() == 10_000, 1);

    destroy_3!(withdrawn, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = deepbook_margin::margin_pool::ERateLimitExceeded)]
fun test_withdrawal_exceeds_limit_fails() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000, // capacity
        10, // refill rate
        true,
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(20_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // Try to withdraw more than capacity - should fail
    let withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(15_000),
        &clock,
        scenario.ctx(),
    );

    abort // won't reach here
}

#[test]
fun test_disabled_rate_limiter() {
    let (
        mut scenario,
        mut clock,
        admin_cap,
        maintainer_cap,
    ) = test_helpers::setup_margin_registry();

    scenario.next_tx(admin());
    let mut registry = scenario.take_shared<MarginRegistry>();
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000,
        10_000, // capacity
        10, // refill rate
        false, // DISABLED
        &clock,
        &mut scenario,
    );
    test_scenario::return_shared(registry);

    scenario.next_tx(user1());
    let mut pool = scenario.take_shared<MarginPool<USDC>>();
    let registry = scenario.take_shared<MarginRegistry>();
    let supplier_cap = margin_pool::mint_supplier_cap(&registry, &clock, scenario.ctx());

    let supply_coin = coin::mint_for_testing<USDC>(100_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, supply_coin, option::none(), &clock);

    // Should be able to withdraw any amount when disabled
    let withdrawn = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(50_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn.value() == 50_000, 0);

    destroy_3!(withdrawn, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}
