// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::reward_pool_tests;

use margin_trading::margin_pool::{Self, MarginPool};
use margin_trading::reward_pool::{Self};
use sui::{
    test_scenario::{Self as test, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_utils::destroy,
};

// Test coin types
public struct USDC has drop {}
public struct SUI has drop {}
public struct REWARD_TOKEN has drop {}

const ADMIN: address = @0xAD;
const USER1: address = @0x1;
const USER2: address = @0x2;

// Test constants
const SUPPLY_CAP: u64 = 1_000_000_000_000; // 1M tokens with 6 decimals
const MAX_BORROW_PERCENTAGE: u64 = 800_000_000; // 80% with 9 decimals
const HOUR_SECONDS: u64 = 3600;

fun setup_test(): (Scenario, Clock, MarginPool<USDC>) {
    let mut scenario = test::begin(@0x0);
    let clock = clock::create_for_testing(scenario.ctx());
    let pool = margin_pool::create_margin_pool<USDC>(
        SUPPLY_CAP,
        MAX_BORROW_PERCENTAGE,
        &clock,
        scenario.ctx()
    );
    (scenario, clock, pool)
}

fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}


#[test]
fun test_add_reward_pool_success() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    scenario.next_tx(ADMIN);
    let reward_coin = mint_coin<SUI>(10000, scenario.ctx());
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    
    clock.set_for_testing(500); // Before start time
    
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = reward_pool::ERewardAmountTooSmall)] 
fun test_add_reward_pool_amount_too_small() {
    let (mut scenario, clock, mut pool) = setup_test();
    
    scenario.next_tx(ADMIN);
    let reward_coin = mint_coin<SUI>(999, scenario.ctx()); // Below minimum
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = reward_pool::ERewardPeriodTooShort)] 
fun test_add_reward_pool_period_too_short() {
    let (mut scenario, clock, mut pool) = setup_test();
    
    scenario.next_tx(ADMIN);
    let reward_coin = mint_coin<SUI>(10000, scenario.ctx());
    let start_time = 1000;
    let end_time = start_time + 1800; // 30 minutes in seconds, below 1 hour minimum
    
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = reward_pool::EInvalidRewardPeriod)] 
fun test_add_reward_pool_invalid_time_range() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    scenario.next_tx(ADMIN);
    let reward_coin = mint_coin<SUI>(10000, scenario.ctx());
    let current_time = 2000;
    let end_time = 1000; // End before current time
    
    // Set current time to after the end_time to trigger EInvalidRewardPeriod
    clock.set_for_testing(current_time * 1000); // Set to 2000 seconds = 2000000 ms
    
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_replace_reward_pool_same_token() {
    let (mut scenario, clock, mut pool) = setup_test();
    
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    
    // Add first SUI reward pool
    let reward_coin1 = mint_coin<SUI>(10000, scenario.ctx());
    pool.add_reward_pool<USDC, SUI>(
        reward_coin1,
        start_time + HOUR_SECONDS,
        &clock,
    );
    
    // Add second SUI reward pool (replaces the first one)
    let reward_coin2 = mint_coin<SUI>(5000, scenario.ctx());
    pool.add_reward_pool<USDC, SUI>(
        reward_coin2,
        start_time + HOUR_SECONDS * 2,
        &clock,
    );
    
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_single_user_reward_distribution() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // User supplies first
    scenario.next_tx(USER1);
    let start_time = 1000;
    clock.set_for_testing(start_time * 1000); 
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    // Then admin adds rewards
    scenario.next_tx(ADMIN);
    let end_time = start_time + HOUR_SECONDS;
    let reward_amount = 3600; // 1 reward per second
    let reward_coin = mint_coin<SUI>(reward_amount, scenario.ctx());
    
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // Fast forward halfway through reward period
    clock.set_for_testing((start_time + HOUR_SECONDS / 2) * 1000); // Convert back to ms for clock
    
    // User claims rewards
    scenario.next_tx(USER1);
    let claimed_rewards = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    
    // Should get approximately half the rewards (1800)
    let claimed_amount = claimed_rewards.value();
    
    assert!(claimed_amount > 1700 && claimed_amount < 1900, 0); // Allow for rounding
    
    destroy(claimed_rewards);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_multiple_users_reward_distribution() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // Setup rewards first
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    let reward_amount = 3600; // 1 reward per second
    let reward_coin = mint_coin<SUI>(reward_amount, scenario.ctx());
    
    clock.set_for_testing(start_time * 1000);
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // User1 supplies 75% of pool
    scenario.next_tx(USER1);
    let supply_coin1 = mint_coin<USDC>(75000, scenario.ctx());
    pool.supply<USDC>(supply_coin1, &clock, scenario.ctx());
    
    // User2 supplies 25% of pool
    scenario.next_tx(USER2);
    let supply_coin2 = mint_coin<USDC>(25000, scenario.ctx());
    pool.supply<USDC>(supply_coin2, &clock, scenario.ctx());
    
    // Fast forward to end of reward period
    clock.set_for_testing(end_time * 1000); 
    
    // User1 claims (should get ~75% of rewards)
    scenario.next_tx(USER1);
    let claimed1 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let amount1 = claimed1.value();
    
    // User2 claims (should get ~25% of rewards)
    scenario.next_tx(USER2);
    let claimed2 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let amount2 = claimed2.value();
    
    // Verify proportional distribution
    assert!(amount1 > amount2 * 2 && amount1 < amount2 * 4, 0); // Roughly 3:1 ratio
    assert!(amount1 + amount2 <= reward_amount, 1); // Total doesn't exceed pool
    
    destroy(claimed1);
    destroy(claimed2);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_supply_during_reward_period() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // Setup rewards
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    let reward_coin = mint_coin<SUI>(3600, scenario.ctx());
    
    clock.set_for_testing(start_time * 1000); 
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // User1 supplies at start
    scenario.next_tx(USER1);
    let supply_coin1 = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin1, &clock, scenario.ctx());
    
    // Fast forward halfway
    clock.set_for_testing((start_time + HOUR_SECONDS / 2) * 1000); 
    
    // User2 supplies halfway through (should get rewards from this point)
    scenario.next_tx(USER2);
    let supply_coin2 = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin2, &clock, scenario.ctx());
    
    // Fast forward to end
    clock.set_for_testing(end_time * 1000); 
    
    // Both users claim
    scenario.next_tx(USER1);
    let claimed1 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    
    scenario.next_tx(USER2);
    let claimed2 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    
    // User1 should get more rewards since they supplied earlier
    // User1 gets rewards for full period on their portion, User2 gets rewards for half period
    assert!(claimed1.value() > claimed2.value(), 0);
    
    // Verify that total rewards don't exceed the pool
    assert!(claimed1.value() + claimed2.value() <= 3600, 1);
    
    destroy(claimed1);
    destroy(claimed2);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_claim_rewards_multiple_times() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // Setup
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    let reward_coin = mint_coin<SUI>(3600, scenario.ctx());
    
    clock.set_for_testing(start_time * 1000); 
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // Claim at 25% through period
    clock.set_for_testing((start_time + HOUR_SECONDS / 4) * 1000); 
    scenario.next_tx(USER1);
    let claimed1 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let amount1 = claimed1.value();
    
    // Claim at 75% through period
    clock.set_for_testing((start_time + 3 * HOUR_SECONDS / 4) * 1000); 
    let claimed2 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let amount2 = claimed2.value();
    
    // Second claim should be larger (more time elapsed)
    assert!(amount2 >= amount1, 0);
    
    // Claim at end (should be small or zero)
    clock.set_for_testing(end_time * 1000); 
    let claimed3 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let amount3 = claimed3.value();
    
    // Total shouldn't exceed reward pool
    assert!(amount1 + amount2 + amount3 <= 3600, 1);
    
    destroy(claimed1);
    destroy(claimed2);
    destroy(claimed3);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_different_reward_token_pools() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // User supplies first
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    
    // Add SUI reward pool
    clock.set_for_testing(start_time * 1000);
    let reward_coin1 = mint_coin<SUI>(3600, scenario.ctx());
    pool.add_reward_pool<USDC, SUI>(
        reward_coin1,
        start_time + HOUR_SECONDS,
        &clock,
    );
    
    // Add REWARD_TOKEN reward pool (different token type, so allowed)
    let reward_coin2 = mint_coin<REWARD_TOKEN>(3600, scenario.ctx()); // Match SUI amount
    pool.add_reward_pool<USDC, REWARD_TOKEN>(
        reward_coin2,
        start_time + HOUR_SECONDS,
        &clock,
    );
    
    // Claim rewards from both token types
    clock.set_for_testing((start_time + HOUR_SECONDS) * 1000); 
    scenario.next_tx(USER1);
    let sui_claimed = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let reward_token_claimed = pool.claim_rewards<USDC, REWARD_TOKEN>(&clock, scenario.ctx());
    
    // Should get rewards from both token types
    assert!(sui_claimed.value() > 0, 0);
    assert!(reward_token_claimed.value() > 0, 1);
    
    destroy(sui_claimed);
    destroy(reward_token_claimed);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_reward_pool_after_period_ends() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // Setup
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    let reward_coin = mint_coin<SUI>(3600, scenario.ctx());
    
    clock.set_for_testing(start_time * 1000); 
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // Fast forward past end time
    clock.set_for_testing((end_time + HOUR_SECONDS) * 1000); 
    
    // User should still be able to claim accumulated rewards
    scenario.next_tx(USER1);
    let claimed = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    
    // Should get full reward amount
    assert!(claimed.value() > 3500 && claimed.value() <= 3600, 0);
    
    // Second claim should yield nothing
    let claimed2 = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    assert!(claimed2.value() == 0, 1);
    
    destroy(claimed);
    destroy(claimed2);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_no_rewards_before_start_time() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // User supplies
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    // Add reward pool with future start time
    scenario.next_tx(ADMIN);
    let start_time = 2000;
    let end_time = start_time + HOUR_SECONDS;
    let reward_coin = mint_coin<SUI>(3600, scenario.ctx());
    
    clock.set_for_testing(1000 * 1000); // Before start time, in milliseconds
    pool.add_reward_pool<USDC, SUI>(
        reward_coin,
        end_time,
        &clock,
    );
    
    // Try to claim before start time
    scenario.next_tx(USER1);
    let claimed = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    assert!(claimed.value() == 0, 0);
    
    destroy(claimed);
    destroy(pool);
    destroy(clock);
    scenario.end();
}

#[test]
fun test_different_reward_token_types() {
    let (mut scenario, mut clock, mut pool) = setup_test();
    
    // User supplies
    scenario.next_tx(USER1);
    let supply_coin = mint_coin<USDC>(100000, scenario.ctx());
    pool.supply<USDC>(supply_coin, &clock, scenario.ctx());
    
    scenario.next_tx(ADMIN);
    let start_time = 1000;
    let end_time = start_time + HOUR_SECONDS;
    
    clock.set_for_testing(start_time * 1000); 
    
    // Add SUI reward pool
    let sui_reward = mint_coin<SUI>(3600, scenario.ctx());
    pool.add_reward_pool<USDC, SUI>(
        sui_reward,
        end_time,
        &clock,
    );
    
    // Add different token reward pool
    let other_reward = mint_coin<REWARD_TOKEN>(3600, scenario.ctx()); // Match SUI amount
    pool.add_reward_pool<USDC, REWARD_TOKEN>(
        other_reward,
        end_time,
        &clock,
    );
    
    // Fast forward and claim both types
    clock.set_for_testing(end_time * 1000); 
    
    scenario.next_tx(USER1);
    let sui_claimed = pool.claim_rewards<USDC, SUI>(&clock, scenario.ctx());
    let other_claimed = pool.claim_rewards<USDC, REWARD_TOKEN>(&clock, scenario.ctx());
    
    assert!(sui_claimed.value() > 0, 0);
    assert!(other_claimed.value() > 0, 1);
    
    destroy(sui_claimed);
    destroy(other_claimed);
    destroy(pool);
    destroy(clock);
    scenario.end();
}