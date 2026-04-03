// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module maker_incentives::maker_incentives_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin;
use sui::clock;
use token::deep::DEEP;
use deepbook::balance_manager::{Self, BalanceManager};
use maker_incentives::maker_incentives::{
    Self, IncentiveFund, EpochRecord, FundOwnerCap,
};

const CREATOR: address = @0xC0;
const MAKER_A: address = @0xA;
const MAKER_B: address = @0xB;
const RELAYER: address = @0xCC;
const POOL_ADDR: address = @0xBEEF;

const REWARD_PER_EPOCH: u64 = 1_000_000_000;
const ALPHA_BPS: u64 = 5_000;
const EPOCH_DURATION: u64 = 86_400_000;
const WINDOW_DURATION: u64 = 3_600_000;

// ─── Helpers ────────────────────────────────────────────────────────

fun setup_fund(test: &mut Scenario): ID {
    ts::next_tx(test, CREATOR);
    {
        let clock = clock::create_for_testing(ts::ctx(test));
        let cap = maker_incentives::create_fund(
            POOL_ADDR,
            REWARD_PER_EPOCH,
            ALPHA_BPS,
            EPOCH_DURATION,
            WINDOW_DURATION,
            &clock,
            ts::ctx(test),
        );
        transfer::public_transfer(cap, CREATOR);
        clock.destroy_for_testing();
    };

    ts::next_tx(test, CREATOR);
    let fund = ts::take_shared<IncentiveFund>(test);
    let fund_id = object::id(&fund);
    ts::return_shared(fund);
    fund_id
}

fun fund_with(test: &mut Scenario, funder: address, amount: u64) {
    ts::next_tx(test, funder);
    let mut fund = ts::take_shared<IncentiveFund>(test);
    let payment = coin::mint_for_testing<DEEP>(amount, ts::ctx(test));
    maker_incentives::fund(&mut fund, payment);
    ts::return_shared(fund);
}

fun create_balance_manager(test: &mut Scenario, owner: address): ID {
    ts::next_tx(test, owner);
    let bm = balance_manager::new(ts::ctx(test));
    let bm_id = object::id(&bm);
    transfer::public_share_object(bm);
    bm_id
}

// ─── Tests ──────────────────────────────────────────────────────────

#[test]
fun test_create_fund_and_view_functions() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    ts::next_tx(&mut test, CREATOR);
    let fund = ts::take_shared<IncentiveFund>(&test);

    assert!(maker_incentives::fund_reward_per_epoch(&fund) == REWARD_PER_EPOCH);
    assert!(maker_incentives::fund_is_active(&fund));
    assert!(maker_incentives::fund_alpha_bps(&fund) == ALPHA_BPS);
    assert!(maker_incentives::fund_epoch_duration_ms(&fund) == EPOCH_DURATION);
    assert!(maker_incentives::fund_window_duration_ms(&fund) == WINDOW_DURATION);
    assert!(maker_incentives::fund_treasury_balance(&fund) == 0);
    assert!(maker_incentives::fund_funded_epochs(&fund) == 0);
    assert!(maker_incentives::fund_pool_id(&fund) == POOL_ADDR);

    ts::return_shared(fund);
    ts::end(test);
}

#[test]
fun test_fund_deposit() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    fund_with(&mut test, CREATOR, 5 * REWARD_PER_EPOCH);

    ts::next_tx(&mut test, CREATOR);
    let fund = ts::take_shared<IncentiveFund>(&test);
    assert!(maker_incentives::fund_treasury_balance(&fund) == 5 * REWARD_PER_EPOCH);
    assert!(maker_incentives::fund_funded_epochs(&fund) == 5);
    ts::return_shared(fund);
    ts::end(test);
}

#[test]
fun test_anyone_can_fund() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    fund_with(&mut test, @0xBBBB, 2 * REWARD_PER_EPOCH);

    ts::next_tx(&mut test, CREATOR);
    let fund = ts::take_shared<IncentiveFund>(&test);
    assert!(maker_incentives::fund_treasury_balance(&fund) == 2 * REWARD_PER_EPOCH);
    ts::return_shared(fund);
    ts::end(test);
}

#[test]
fun test_anyone_can_create_fund() {
    let mut test = ts::begin(@0xF1);
    {
        let clock = clock::create_for_testing(ts::ctx(&mut test));
        let cap = maker_incentives::create_fund(
            POOL_ADDR,
            500_000,
            10_000,
            43_200_000,
            1_800_000,
            &clock,
            ts::ctx(&mut test),
        );
        transfer::public_transfer(cap, @0xF1);
        clock.destroy_for_testing();
    };

    ts::next_tx(&mut test, @0xF1);
    let fund = ts::take_shared<IncentiveFund>(&test);
    assert!(maker_incentives::fund_reward_per_epoch(&fund) == 500_000);
    assert!(maker_incentives::fund_alpha_bps(&fund) == 10_000);
    ts::return_shared(fund);
    ts::end(test);
}

#[test]
fun test_owner_update_reward() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    ts::next_tx(&mut test, CREATOR);
    let cap = ts::take_from_sender<FundOwnerCap>(&test);
    let mut fund = ts::take_shared<IncentiveFund>(&test);

    maker_incentives::update_reward_per_epoch(&cap, &mut fund, 999);
    assert!(maker_incentives::fund_reward_per_epoch(&fund) == 999);

    ts::return_shared(fund);
    ts::return_to_sender(&test, cap);
    ts::end(test);
}

#[test]
fun test_owner_update_alpha() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    ts::next_tx(&mut test, CREATOR);
    let cap = ts::take_from_sender<FundOwnerCap>(&test);
    let mut fund = ts::take_shared<IncentiveFund>(&test);

    maker_incentives::update_alpha(&cap, &mut fund, 10_000);
    assert!(maker_incentives::fund_alpha_bps(&fund) == 10_000);

    ts::return_shared(fund);
    ts::return_to_sender(&test, cap);
    ts::end(test);
}

#[test]
fun test_owner_set_fund_active() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    ts::next_tx(&mut test, CREATOR);
    let cap = ts::take_from_sender<FundOwnerCap>(&test);
    let mut fund = ts::take_shared<IncentiveFund>(&test);

    maker_incentives::set_fund_active(&cap, &mut fund, false);
    assert!(!maker_incentives::fund_is_active(&fund));

    maker_incentives::set_fund_active(&cap, &mut fund, true);
    assert!(maker_incentives::fund_is_active(&fund));

    ts::return_shared(fund);
    ts::return_to_sender(&test, cap);
    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::ENotFundOwner)]
fun test_wrong_owner_update_aborts() {
    let mut test = ts::begin(CREATOR);
    let fund_id = setup_fund(&mut test);

    // Second user creates their own fund — gets a different cap.
    ts::next_tx(&mut test, @0xF2);
    {
        let clock = clock::create_for_testing(ts::ctx(&mut test));
        let other_cap = maker_incentives::create_fund(
            @0xDEAD,
            1,
            1,
            1,
            1,
            &clock,
            ts::ctx(&mut test),
        );
        transfer::public_transfer(other_cap, @0xF2);
        clock.destroy_for_testing();
    };

    // Try to use other_cap on the first fund.
    ts::next_tx(&mut test, @0xF2);
    let other_cap = ts::take_from_sender<FundOwnerCap>(&test);
    let mut fund = ts::take_shared_by_id<IncentiveFund>(&test, fund_id);

    maker_incentives::update_reward_per_epoch(&other_cap, &mut fund, 999);

    ts::return_shared(fund);
    ts::return_to_sender(&test, other_cap);
    ts::end(test);
}

#[test]
fun test_submit_and_claim_happy_path() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, 2 * REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);
    let bm_b_id = create_balance_manager(&mut test, MAKER_B);

    let total_score = 100;
    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            70,
        ));
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_b_id),
            30,
        ));

        maker_incentives::submit_epoch_results_test(
            &mut fund,
            0,
            EPOCH_DURATION,
            total_score,
            rewards,
            ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    // Verify treasury was debited.
    ts::next_tx(&mut test, CREATOR);
    {
        let fund = ts::take_shared<IncentiveFund>(&test);
        assert!(maker_incentives::fund_treasury_balance(&fund) == REWARD_PER_EPOCH);
        ts::return_shared(fund);
    };

    // Maker A claims.
    ts::next_tx(&mut test, MAKER_A);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        let payout = maker_incentives::claim_reward(
            &mut record,
            &bm,
            ts::ctx(&mut test),
        );
        let expected = ((REWARD_PER_EPOCH as u128) * 70 / 100) as u64;
        assert!(coin::value(&payout) == expected);
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    // Maker B claims.
    ts::next_tx(&mut test, MAKER_B);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_b_id);
        let payout = maker_incentives::claim_reward(
            &mut record,
            &bm,
            ts::ctx(&mut test),
        );
        let expected = ((REWARD_PER_EPOCH as u128) * 30 / 100) as u64;
        assert!(coin::value(&payout) == expected);
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    // Verify remaining rewards are 0.
    ts::next_tx(&mut test, CREATOR);
    {
        let record = ts::take_shared<EpochRecord>(&test);
        assert!(maker_incentives::record_remaining_rewards(&record) == 0);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::ERewardAlreadyClaimed)]
fun test_double_claim_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::next_tx(&mut test, MAKER_A);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    // Second claim should abort.
    ts::next_tx(&mut test, MAKER_A);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::ENotBalanceManagerOwner)]
fun test_claim_wrong_owner_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    // MAKER_B tries to claim MAKER_A's reward.
    ts::next_tx(&mut test, MAKER_B);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::ENoRewardToClaim)]
fun test_claim_no_score_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);
    let bm_b_id = create_balance_manager(&mut test, MAKER_B);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    // Maker B tries to claim — not in the list.
    ts::next_tx(&mut test, MAKER_B);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_b_id);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::EFundNotActive)]
fun test_submit_inactive_fund_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    ts::next_tx(&mut test, CREATOR);
    {
        let cap = ts::take_from_sender<FundOwnerCap>(&test);
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        maker_incentives::set_fund_active(&cap, &mut fund, false);
        ts::return_shared(fund);
        ts::return_to_sender(&test, cap);
    };

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let rewards = vector::empty();
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 0, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::EInvalidEpochRange)]
fun test_submit_bad_epoch_range_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let rewards = vector::empty();
        maker_incentives::submit_epoch_results_test(
            &mut fund, 2000, 1000, 0, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::EInvalidEpochDuration)]
fun test_submit_wrong_epoch_duration_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let rewards = vector::empty();
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, 3_600_000, 0, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::EEpochBeforeFundCreation)]
fun test_submit_epoch_before_fund_creation_aborts() {
    let mut test = ts::begin(CREATOR);

    // Create fund with clock at time 5000.
    ts::next_tx(&mut test, CREATOR);
    {
        let mut clock = clock::create_for_testing(ts::ctx(&mut test));
        clock.set_for_testing(5000);
        let cap = maker_incentives::create_fund(
            POOL_ADDR,
            REWARD_PER_EPOCH,
            ALPHA_BPS,
            EPOCH_DURATION,
            WINDOW_DURATION,
            &clock,
            ts::ctx(&mut test),
        );
        transfer::public_transfer(cap, CREATOR);
        clock.destroy_for_testing();
    };

    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    // Submit epoch that starts before the fund was created — should abort.
    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let rewards = vector::empty();
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 0, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test]
fun test_treasury_underfunded_allocates_remaining() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);

    let half = REWARD_PER_EPOCH / 2;
    fund_with(&mut test, CREATOR, half);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        assert!(maker_incentives::fund_treasury_balance(&fund) == 0);
        ts::return_shared(fund);
    };

    ts::next_tx(&mut test, MAKER_A);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        assert!(maker_incentives::record_total_allocation(&record) == half);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        assert!(coin::value(&payout) == half);
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test]
fun test_estimate_payout() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    ts::next_tx(&mut test, CREATOR);
    {
        let fund = ts::take_shared<IncentiveFund>(&test);

        let est = maker_incentives::estimate_payout(&fund, 50, 100);
        assert!(est == REWARD_PER_EPOCH / 2);

        let est_zero = maker_incentives::estimate_payout(&fund, 0, 100);
        assert!(est_zero == 0);

        let est_no_total = maker_incentives::estimate_payout(&fund, 50, 0);
        assert!(est_no_total == 0);

        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test]
fun test_record_maker_info() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);
    let bm_b_id = create_balance_manager(&mut test, MAKER_B);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            75,
        ));
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_b_id),
            25,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::next_tx(&mut test, CREATOR);
    {
        let record = ts::take_shared<EpochRecord>(&test);

        let (score_a, claimed_a) = maker_incentives::record_maker_info(
            &record,
            object::id_to_address(&bm_a_id),
        );
        assert!(score_a == 75);
        assert!(!claimed_a);

        let (score_b, claimed_b) = maker_incentives::record_maker_info(
            &record,
            object::id_to_address(&bm_b_id),
        );
        assert!(score_b == 25);
        assert!(!claimed_b);

        let (score_none, claimed_none) = maker_incentives::record_maker_info(
            &record,
            @0xDEAD,
        );
        assert!(score_none == 0);
        assert!(!claimed_none);

        ts::return_shared(record);
    };

    // After claiming, record_maker_info reflects it.
    ts::next_tx(&mut test, MAKER_A);
    {
        let mut record = ts::take_shared<EpochRecord>(&test);
        let bm = ts::take_shared_by_id<BalanceManager>(&test, bm_a_id);
        let payout = maker_incentives::claim_reward(&mut record, &bm, ts::ctx(&mut test));
        coin::burn_for_testing(payout);
        ts::return_shared(bm);
        ts::return_shared(record);
    };

    ts::next_tx(&mut test, CREATOR);
    {
        let record = ts::take_shared<EpochRecord>(&test);
        let (score_a, claimed_a) = maker_incentives::record_maker_info(
            &record,
            object::id_to_address(&bm_a_id),
        );
        assert!(score_a == 75);
        assert!(claimed_a);
        ts::return_shared(record);
    };

    ts::end(test);
}

#[test]
fun test_multiple_epochs() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, 3 * REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);

    // Epoch 1.
    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    // Epoch 2.
    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, EPOCH_DURATION, 2 * EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::next_tx(&mut test, CREATOR);
    {
        let fund = ts::take_shared<IncentiveFund>(&test);
        assert!(maker_incentives::fund_treasury_balance(&fund) == REWARD_PER_EPOCH);
        assert!(maker_incentives::fund_funded_epochs(&fund) == 1);
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test, expected_failure(abort_code = maker_incentives::EEpochAlreadySubmitted)]
fun test_duplicate_epoch_submission_aborts() {
    let mut test = ts::begin(CREATOR);
    setup_fund(&mut test);
    fund_with(&mut test, CREATOR, 3 * REWARD_PER_EPOCH);

    let bm_a_id = create_balance_manager(&mut test, MAKER_A);

    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    // Same epoch_start_ms — should abort.
    ts::next_tx(&mut test, RELAYER);
    {
        let mut fund = ts::take_shared<IncentiveFund>(&test);
        let mut rewards = vector::empty();
        rewards.push_back(maker_incentives::new_maker_reward_entry(
            object::id_to_address(&bm_a_id),
            100,
        ));
        maker_incentives::submit_epoch_results_test(
            &mut fund, 0, EPOCH_DURATION, 100, rewards, ts::ctx(&mut test),
        );
        ts::return_shared(fund);
    };

    ts::end(test);
}

#[test]
fun test_multiple_funds_same_pool() {
    let mut test = ts::begin(CREATOR);

    // Fund A: 1000/epoch, alpha=0.5
    ts::next_tx(&mut test, CREATOR);
    {
        let clock = clock::create_for_testing(ts::ctx(&mut test));
        let cap = maker_incentives::create_fund(
            POOL_ADDR, REWARD_PER_EPOCH, 5_000, EPOCH_DURATION, WINDOW_DURATION,
            &clock,
            ts::ctx(&mut test),
        );
        transfer::public_transfer(cap, CREATOR);
        clock.destroy_for_testing();
    };

    // Fund B: different creator, 500/epoch, alpha=1.0
    ts::next_tx(&mut test, @0xF3);
    {
        let clock = clock::create_for_testing(ts::ctx(&mut test));
        let cap = maker_incentives::create_fund(
            POOL_ADDR, REWARD_PER_EPOCH / 2, 10_000, EPOCH_DURATION, WINDOW_DURATION,
            &clock,
            ts::ctx(&mut test),
        );
        transfer::public_transfer(cap, @0xF3);
        clock.destroy_for_testing();
    };

    // Both funds can be funded and used independently.
    fund_with(&mut test, CREATOR, REWARD_PER_EPOCH);

    ts::next_tx(&mut test, CREATOR);
    let fund = ts::take_shared<IncentiveFund>(&test);
    assert!(maker_incentives::fund_treasury_balance(&fund) == REWARD_PER_EPOCH);
    ts::return_shared(fund);

    ts::end(test);
}
