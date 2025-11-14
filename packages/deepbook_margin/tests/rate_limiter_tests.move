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
    let _pool_id = test_helpers::create_pool_with_rate_limit<USDC>(
        &mut registry,
        &maintainer_cap,
        1_000_000, // 1M supply cap
        10_000, // 100K max net withdrawal
        HOUR_MS, // 24 hour window
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

    // Move clock past window
    clock::increment_for_testing(&mut clock, 2 * HOUR_MS);

    // withdraw $10K (at the limit)
    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn1.value() == 10_000, 0);

    // Should not be able to withdraw
    let available = pool.get_available_withdrawal(&clock);
    assert!(available == 0, 1);

    let current_net = pool.get_current_net_withdrawal(&clock);
    assert!(current_net == 10_000, 2);

    destroy_3!(withdrawn1, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_deposit_increases_capacity() {
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
        10_000, // 10K max net withdrawal
        HOUR_MS,
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
    clock::increment_for_testing(&mut clock, 2 * HOUR_MS);

    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );

    let deposit_coin = coin::mint_for_testing<USDC>(5_000, scenario.ctx());
    pool.supply(&registry, &supplier_cap, deposit_coin, option::none(), &clock);

    // Should now be able to withdraw $5K more
    let withdrawn2 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(5_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 5_000, 0);

    // Current net withdrawal is 10K (15K withdrawn - 5K deposited)
    assert!(pool.get_current_net_withdrawal(&clock) == 10_000, 1);

    destroy_4!(withdrawn1, withdrawn2, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun test_sliding_window_cleanup() {
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
        10_000,
        HOUR_MS, // 1 hour window
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

    clock::increment_for_testing(&mut clock, 2 * HOUR_MS);

    let withdrawn1 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );

    clock::increment_for_testing(&mut clock, 2 * HOUR_MS);

    // Old withdrawal should be outside window, can withdraw another $10K
    let withdrawn2 = pool.withdraw(
        &registry,
        &supplier_cap,
        option::some(10_000),
        &clock,
        scenario.ctx(),
    );
    assert!(withdrawn2.value() == 10_000, 0);

    // Current net withdrawal should only be 10K (from second withdrawal)
    assert!(pool.get_current_net_withdrawal(&clock) == 10_000, 1);

    destroy_4!(withdrawn1, withdrawn2, supplier_cap, maintainer_cap);
    destroy(admin_cap);
    return_shared_2!(pool, registry);
    clock.destroy_for_testing();
    scenario.end();
}
