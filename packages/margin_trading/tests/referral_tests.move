// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::referral_tests;

use margin_trading::{
    margin_pool::{
        Self,
        MarginPool,
        register_referral_code,
        supply_with_referral,
        get_referral_info,
        claim_referral_yield,
        referral_total_deposits
    },
    margin_state::new_interest_params
};
use std::string;
use sui::{
    coin,
    clock,
    test_scenario::{Self as ts, Scenario},
    test_utils::destroy
};

const ADMIN: address = @0x1;
const FRONTEND_A: address = @0x2;
const USER1: address = @0x4;

public struct USDC has drop {}

fun create_test_pool(scenario: &mut Scenario): ID {
    scenario.next_tx(ADMIN);
    let clock = clock::create_for_testing(scenario.ctx());
    
    let pool_id = margin_pool::create_margin_pool<USDC>(
        new_interest_params(
            50_000_000, // 5% base rate
            100_000_000, // 10% base slope
            800_000_000, // 80% optimal utilization
            3_000_000_000, // 300% excess slope
        ),
        1_000_000_000_000, // supply cap
        800_000_000, // 80% max borrow percentage  
        50_000_000, // 5% protocol spread
        &clock,
        scenario.ctx()
    );
    
    destroy(clock);
    pool_id
}

#[test]
fun test_referral_yield_on_withdrawal_with_profit() {
    let mut scenario = ts::begin(ADMIN);
    let pool_id = create_test_pool(&mut scenario);
    
    // Register referral code with 10% yield share
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        register_referral_code<USDC>(
            &mut pool,
            string::utf8(b"FRONTEND_A"),
            FRONTEND_A,
            1000, // 10% yield share
        );
        ts::return_shared(pool);
    };
    
    // User deposits 1000 USDC with referral
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
        
        supply_with_referral<USDC>(
            &mut pool,
            coin,
            option::some(string::utf8(b"FRONTEND_A")),
            &clock,
            scenario.ctx()
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Simulate time passing and interest accruing by adding liquidation rewards
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let reward_coin = coin::mint_for_testing<USDC>(100, scenario.ctx()); // 100 profit
        
        margin_pool::add_liquidation_reward<USDC>(
            &mut pool,
            reward_coin,
            object::id_from_address(@0x123), // dummy manager id
            &clock
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // User withdraws everything (should get profit minus referral fee)
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        
        let withdrawn_coin = margin_pool::withdraw<USDC>(
            &mut pool,
            option::none(), // withdraw everything
            &clock,
            scenario.ctx()
        );
        
        let withdrawn_amount = coin::value(&withdrawn_coin);
        
        // User had 1000 principal + 100 profit = 1100 total
        // Profit = 100, referral yield = 100 * 10% = 10
        // User should receive 1100 - 10 = 1090
        assert!(withdrawn_amount == 1090, withdrawn_amount);
        
        destroy(withdrawn_coin);
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Frontend claims the accumulated yield
    scenario.next_tx(FRONTEND_A);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let yield_coin = claim_referral_yield<USDC>(
            &mut pool,
            string::utf8(b"FRONTEND_A"),
            scenario.ctx()
        );
        
        let yield_amount = coin::value(&yield_coin);
        assert!(yield_amount == 10, yield_amount); // 10% of 100 profit
        
        destroy(yield_coin);
        ts::return_shared(pool);
    };
    
    scenario.end();
}

#[test]
fun test_principal_vs_interest_tracking() {
    let mut scenario = ts::begin(ADMIN);
    let pool_id = create_test_pool(&mut scenario);
    
    // Register referral code
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        register_referral_code<USDC>(
            &mut pool,
            string::utf8(b"TEST_REF"),
            FRONTEND_A,
            2000, // 20% yield share
        );
        ts::return_shared(pool);
    };
    
    // User deposits 1000 USDC with referral
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
        
        supply_with_referral<USDC>(
            &mut pool,
            coin,
            option::some(string::utf8(b"TEST_REF")),
            &clock,
            scenario.ctx()
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Add liquidation reward to simulate interest
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let reward_coin = coin::mint_for_testing<USDC>(200, scenario.ctx());
        
        margin_pool::add_liquidation_reward<USDC>(
            &mut pool,
            reward_coin,
            object::id_from_address(@0x123),
            &clock
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // User withdraws only part of their balance (should be proportional)
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        
        // Withdraw 600 out of 1200 total (50%)
        let withdrawn_coin = margin_pool::withdraw<USDC>(
            &mut pool,
            option::some(600),
            &clock,
            scenario.ctx()
        );
        
        let withdrawn_amount = coin::value(&withdrawn_coin);
        
        // User has 1000 principal + 200 profit = 1200 total
        // Withdrawing 600 (50% of total)
        // Profit portion = 600 * 200/1200 = 100
        // Referral yield = 100 * 20% = 20
        // User receives 600 - 20 = 580
        assert!(withdrawn_amount == 580, withdrawn_amount);
        
        destroy(withdrawn_coin);
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // User withdraws remaining balance
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        
        let withdrawn_coin = margin_pool::withdraw<USDC>(
            &mut pool,
            option::none(), // withdraw everything remaining
            &clock,
            scenario.ctx()
        );
        
        let withdrawn_amount = coin::value(&withdrawn_coin);
        
        // Remaining profit = 100 (since we took 100 out of 200 previously)
        // Referral yield = 100 * 20% = 20
        // User receives remaining balance minus referral yield
        // Should be around 600 - 20 = 580
        assert!(withdrawn_amount == 580, withdrawn_amount);
        
        destroy(withdrawn_coin);
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Frontend claims total accumulated yield
    scenario.next_tx(FRONTEND_A);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let yield_coin = claim_referral_yield<USDC>(
            &mut pool,
            string::utf8(b"TEST_REF"),
            scenario.ctx()
        );
        
        let yield_amount = coin::value(&yield_coin);
        // Should be 40 total (20 + 20 from both withdrawals)
        assert!(yield_amount == 40, yield_amount);
        
        destroy(yield_coin);
        ts::return_shared(pool);
    };
    
    scenario.end();
}

#[test]
fun test_withdrawal_with_no_profit() {
    let mut scenario = ts::begin(ADMIN);
    let pool_id = create_test_pool(&mut scenario);
    
    // Register referral code
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        register_referral_code<USDC>(
            &mut pool,
            string::utf8(b"NO_PROFIT_REF"),
            FRONTEND_A,
            1000, // 10% yield share
        );
        ts::return_shared(pool);
    };
    
    // User deposits and immediately withdraws (no time for interest)
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let coin = coin::mint_for_testing<USDC>(1000, scenario.ctx());
        
        supply_with_referral<USDC>(
            &mut pool,
            coin,
            option::some(string::utf8(b"NO_PROFIT_REF")),
            &clock,
            scenario.ctx()
        );
        
        // Immediately withdraw everything
        let withdrawn_coin = margin_pool::withdraw<USDC>(
            &mut pool,
            option::none(),
            &clock,
            scenario.ctx()
        );
        
        let withdrawn_amount = coin::value(&withdrawn_coin);
        
        // No profit, so no referral yield deducted
        // User should get back exactly what they deposited
        assert!(withdrawn_amount == 1000, withdrawn_amount);
        
        destroy(withdrawn_coin);
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Frontend tries to claim yield (should get nothing)
    scenario.next_tx(FRONTEND_A);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let yield_coin = claim_referral_yield<USDC>(
            &mut pool,
            string::utf8(b"NO_PROFIT_REF"),
            scenario.ctx()
        );
        
        let yield_amount = coin::value(&yield_coin);
        assert!(yield_amount == 0, yield_amount);
        
        destroy(yield_coin);
        ts::return_shared(pool);
    };
    
    scenario.end();
}

#[test]
fun test_multiple_deposits_same_referral() {
    let mut scenario = ts::begin(ADMIN);
    let pool_id = create_test_pool(&mut scenario);
    
    // Register referral code
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        register_referral_code<USDC>(
            &mut pool,
            string::utf8(b"MULTI_DEP"),
            FRONTEND_A,
            1500, // 15% yield share
        );
        ts::return_shared(pool);
    };
    
    // USER1 makes first deposit
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let coin = coin::mint_for_testing<USDC>(500, scenario.ctx());
        
        supply_with_referral<USDC>(
            &mut pool,
            coin,
            option::some(string::utf8(b"MULTI_DEP")),
            &clock,
            scenario.ctx()
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // USER1 makes second deposit (should accumulate principal)
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let coin = coin::mint_for_testing<USDC>(500, scenario.ctx());
        
        supply_with_referral<USDC>(
            &mut pool,
            coin,
            option::some(string::utf8(b"MULTI_DEP")),
            &clock,
            scenario.ctx()
        );
        
        // Check total referred deposits
        let referral_info = get_referral_info(&pool, string::utf8(b"MULTI_DEP"));
        let total_deposits = referral_total_deposits(referral_info);
        assert!(total_deposits == 1000, total_deposits);
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Add interest through liquidation reward
    scenario.next_tx(ADMIN);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        let reward_coin = coin::mint_for_testing<USDC>(200, scenario.ctx());
        
        margin_pool::add_liquidation_reward<USDC>(
            &mut pool,
            reward_coin,
            object::id_from_address(@0x456),
            &clock
        );
        
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // USER1 withdraws everything
    scenario.next_tx(USER1);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let clock = clock::create_for_testing(scenario.ctx());
        
        let withdrawn_coin = margin_pool::withdraw<USDC>(
            &mut pool,
            option::none(),
            &clock,
            scenario.ctx()
        );
        
        let withdrawn_amount = coin::value(&withdrawn_coin);
        
        // User has 1000 principal + 200 profit = 1200 total
        // Referral yield = 200 * 15% = 30
        // User receives 1200 - 30 = 1170
        assert!(withdrawn_amount == 1170, withdrawn_amount);
        
        destroy(withdrawn_coin);
        destroy(clock);
        ts::return_shared(pool);
    };
    
    // Frontend claims accumulated yield
    scenario.next_tx(FRONTEND_A);
    {
        let mut pool = scenario.take_shared_by_id<MarginPool<USDC>>(pool_id);
        let yield_coin = claim_referral_yield<USDC>(
            &mut pool,
            string::utf8(b"MULTI_DEP"),
            scenario.ctx()
        );
        
        let yield_amount = coin::value(&yield_coin);
        assert!(yield_amount == 30, yield_amount); // 15% of 200 profit
        
        destroy(yield_coin);
        ts::return_shared(pool);
    };
    
    scenario.end();
}