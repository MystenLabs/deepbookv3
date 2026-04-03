// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Permissionless maker incentive platform for DeepBook pools.
///
/// Anyone can create an incentive fund by depositing DEEP tokens,
/// targeting a DeepBook pool, and choosing scoring parameters. Multiple funds
/// can target the same pool — makers earn from all active funds simultaneously,
/// scored independently by each fund's parameters.
///
/// Scores are computed off-chain inside a Nautilus secure enclave and verified
/// on-chain via Ed25519 attestation.
///
/// Per-maker, per-window score:
///   effective_size   = sqrt(total_bid_size × total_ask_size)
///   spread_factor    = (pool_median_spread / maker_spread) ^ alpha
///   time_fraction    = active_duration / window_duration
///   window_score     = effective_size × spread_factor × time_fraction
///
/// Window weighting (higher-volume windows count more):
///   window_weight    = max(window_volume / total_epoch_volume, floor)
///
/// Epoch aggregation:
///   maker_epoch_score = Σ (window_score × window_weight)
///   payout            = fund_allocation × maker_score / total_score
module maker_incentives::maker_incentives;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};
use deepbook::balance_manager::BalanceManager;
use enclave::enclave::{Self, Enclave};
use token::deep::DEEP;

// === Constants ===
const INCENTIVE_INTENT: u8 = 1;

// === Errors ===
const EInvalidSignature: u64 = 0;
const EFundNotActive: u64 = 1;
const EInvalidEpochRange: u64 = 2;
const ENoRewardToClaim: u64 = 3;
const ERewardAlreadyClaimed: u64 = 4;
const ENotBalanceManagerOwner: u64 = 5;
const EZeroTotalScore: u64 = 6;
const EEpochAlreadySubmitted: u64 = 7;
const ENotFundOwner: u64 = 8;
const EEpochBeforeFundCreation: u64 = 9;
const EInvalidEpochDuration: u64 = 10;

// === OTW ===
public struct MAKER_INCENTIVES has drop {}

/// Ownership capability for an IncentiveFund. Returned to the fund creator.
/// Transferable — the fund creator can hand off management to another address.
public struct FundOwnerCap has key, store {
    id: UID,
    fund_id: ID,
}

/// Permissionless incentive fund. All rewards are denominated in DEEP.
public struct IncentiveFund has key, store {
    id: UID,
    pool_id: address,
    treasury: Balance<DEEP>,
    reward_per_epoch: u64,
    /// Spread-factor exponent, scaled by 10 000 (e.g. 15 000 = 1.5).
    alpha_bps: u64,
    epoch_duration_ms: u64,
    window_duration_ms: u64,
    is_active: bool,
    submitted_epochs: Table<u64, bool>,
    /// Clock timestamp (ms) when the fund was created. Epochs before this
    /// time cannot be submitted, preventing retroactive reward drains.
    created_at_ms: u64,
}

/// BCS payload signed by the enclave. Field order must match the Rust
/// `EpochResults` struct exactly. Includes `fund_id` to prevent cross-fund
/// signature replay.
public struct EpochResults has copy, drop {
    pool_id: address,
    fund_id: address,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_score: u64,
    maker_rewards: vector<MakerRewardEntry>,
}

public struct MakerRewardEntry has copy, drop, store {
    balance_manager_id: address,
    score: u64,
}

/// On-chain record for a completed epoch. Created by `submit_epoch_results`,
/// consumed by `claim_reward`.
public struct EpochRecord has key, store {
    id: UID,
    pool_id: address,
    fund_id: address,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_allocation: u64,
    total_score: u64,
    rewards: Balance<DEEP>,
    maker_scores: vector<MakerRewardEntry>,
    claimed: vector<address>,
}

// === Events ===
public struct FundCreated has copy, drop {
    pool_id: address,
    fund_id: ID,
    reward_per_epoch: u64,
    creator: address,
    created_at_ms: u64,
}

public struct EpochResultsSubmitted has copy, drop {
    pool_id: address,
    fund_id: address,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_allocation: u64,
    num_makers: u64,
}

public struct RewardClaimed has copy, drop {
    pool_id: address,
    fund_id: address,
    epoch_start_ms: u64,
    balance_manager_id: address,
    amount: u64,
}

// === Init ===
fun init(otw: MAKER_INCENTIVES, ctx: &mut TxContext) {
    let cap = enclave::new_cap(otw, ctx);

    cap.create_enclave_config(
        b"DeepBook Maker Incentives".to_string(),
        x"377b6a16231d44a255d222a9932051847d3fbba53f2e8fc02efbc24f2b4f51797f7c9e951dcd8c45a2d3045323ef8c78",
        x"377b6a16231d44a255d222a9932051847d3fbba53f2e8fc02efbc24f2b4f51797f7c9e951dcd8c45a2d3045323ef8c78",
        x"21b9efbc184807662e966d34f390821309eeac6802309798826296bf3e8bec7c10edb30948c90ba67310f7b964fc500a",
        ctx,
    );

    transfer::public_transfer(cap, ctx.sender());
}

// === Fund creation (permissionless) ===

/// Create a new incentive fund targeting a DeepBook pool. Anyone can call this.
/// Returns a `FundOwnerCap` that grants management rights over the fund.
public fun create_fund(
    pool_id: address,
    reward_per_epoch: u64,
    alpha_bps: u64,
    epoch_duration_ms: u64,
    window_duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): FundOwnerCap {
    let created_at_ms = clock.timestamp_ms();
    let fund = IncentiveFund {
        id: object::new(ctx),
        pool_id,
        treasury: balance::zero(),
        reward_per_epoch,
        alpha_bps,
        epoch_duration_ms,
        window_duration_ms,
        is_active: true,
        submitted_epochs: table::new(ctx),
        created_at_ms,
    };

    let fund_id = object::id(&fund);

    event::emit(FundCreated {
        pool_id,
        fund_id,
        reward_per_epoch,
        creator: ctx.sender(),
        created_at_ms,
    });

    transfer::share_object(fund);

    FundOwnerCap {
        id: object::new(ctx),
        fund_id,
    }
}

// === Fund management (owner only) ===

public fun update_reward_per_epoch(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    reward_per_epoch: u64,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    fund.reward_per_epoch = reward_per_epoch;
}

public fun update_alpha(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    alpha_bps: u64,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    fund.alpha_bps = alpha_bps;
}

public fun set_fund_active(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    active: bool,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    fund.is_active = active;
}

// === Funding (permissionless) ===

/// Anyone can deposit DEEP into a fund's treasury.
public fun fund(fund: &mut IncentiveFund, payment: Coin<DEEP>) {
    fund.treasury.join(payment.into_balance());
}

// === Epoch settlement ===

/// Submit enclave-attested scores for a completed epoch.
/// Permissionless — anyone can relay; the enclave signature is the authority.
public fun submit_epoch_results(
    fund: &mut IncentiveFund,
    enclave: &Enclave<MAKER_INCENTIVES>,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_score: u64,
    maker_rewards: vector<MakerRewardEntry>,
    timestamp_ms: u64,
    signature: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(fund.is_active, EFundNotActive);
    assert!(epoch_end_ms > epoch_start_ms, EInvalidEpochRange);
    assert!(epoch_end_ms - epoch_start_ms == fund.epoch_duration_ms, EInvalidEpochDuration);
    assert!(epoch_start_ms >= fund.created_at_ms, EEpochBeforeFundCreation);
    assert!(!fund.submitted_epochs.contains(epoch_start_ms), EEpochAlreadySubmitted);

    let fund_id = object::id(fund).to_address();
    let results = EpochResults {
        pool_id: fund.pool_id,
        fund_id,
        epoch_start_ms,
        epoch_end_ms,
        total_score,
        maker_rewards,
    };

    let valid = enclave.verify_signature(
        INCENTIVE_INTENT,
        timestamp_ms,
        results,
        &signature,
    );
    assert!(valid, EInvalidSignature);

    let allocation = if (total_score == 0) {
        0
    } else if (fund.treasury.value() >= fund.reward_per_epoch) {
        fund.reward_per_epoch
    } else {
        fund.treasury.value()
    };

    let num_makers = results.maker_rewards.length();

    let record = EpochRecord {
        id: object::new(ctx),
        pool_id: fund.pool_id,
        fund_id,
        epoch_start_ms,
        epoch_end_ms,
        total_allocation: allocation,
        total_score: results.total_score,
        rewards: fund.treasury.split(allocation),
        maker_scores: results.maker_rewards,
        claimed: vector::empty(),
    };

    event::emit(EpochResultsSubmitted {
        pool_id: fund.pool_id,
        fund_id,
        epoch_start_ms,
        epoch_end_ms,
        total_allocation: allocation,
        num_makers,
    });

    fund.submitted_epochs.add(epoch_start_ms, true);
    transfer::share_object(record);
}

// === Claiming ===

/// Maker claims their share of an epoch's DEEP rewards.
/// Caller must be the owner of the BalanceManager that earned the reward.
public fun claim_reward(
    record: &mut EpochRecord,
    balance_manager: &BalanceManager,
    ctx: &mut TxContext,
): Coin<DEEP> {
    assert!(record.total_score > 0, EZeroTotalScore);

    let bm_id = object::id(balance_manager).to_address();
    assert!(balance_manager.owner() == ctx.sender(), ENotBalanceManagerOwner);
    assert!(!record.claimed.contains(&bm_id), ERewardAlreadyClaimed);

    let mut score = 0u64;
    let len = record.maker_scores.length();
    let mut i = 0;
    while (i < len) {
        let entry = &record.maker_scores[i];
        if (entry.balance_manager_id == bm_id) {
            score = entry.score;
            break
        };
        i = i + 1;
    };

    assert!(score > 0, ENoRewardToClaim);

    let payout_amount = (
        (record.total_allocation as u128) * (score as u128)
            / (record.total_score as u128)
    ) as u64;

    let payout = record.rewards.split(payout_amount);
    record.claimed.push_back(bm_id);

    event::emit(RewardClaimed {
        pool_id: record.pool_id,
        fund_id: record.fund_id,
        epoch_start_ms: record.epoch_start_ms,
        balance_manager_id: bm_id,
        amount: payout_amount,
    });

    coin::from_balance(payout, ctx)
}

// === View functions ===
public fun fund_treasury_balance(fund: &IncentiveFund): u64 { fund.treasury.value() }
public fun fund_reward_per_epoch(fund: &IncentiveFund): u64 { fund.reward_per_epoch }
public fun fund_is_active(fund: &IncentiveFund): bool { fund.is_active }
public fun fund_alpha_bps(fund: &IncentiveFund): u64 { fund.alpha_bps }
public fun fund_epoch_duration_ms(fund: &IncentiveFund): u64 { fund.epoch_duration_ms }
public fun fund_window_duration_ms(fund: &IncentiveFund): u64 { fund.window_duration_ms }
public fun fund_pool_id(fund: &IncentiveFund): address { fund.pool_id }
public fun fund_created_at_ms(fund: &IncentiveFund): u64 { fund.created_at_ms }

/// How many full epochs can be funded from the current treasury.
public fun fund_funded_epochs(fund: &IncentiveFund): u64 {
    if (fund.reward_per_epoch == 0) { return 0 };
    fund.treasury.value() / fund.reward_per_epoch
}

/// Whether a given epoch_start_ms has already been submitted for this fund.
public fun is_epoch_submitted(fund: &IncentiveFund, epoch_start_ms: u64): bool {
    fund.submitted_epochs.contains(epoch_start_ms)
}

/// Estimate what a maker would earn given their score vs total score.
public fun estimate_payout(
    fund: &IncentiveFund,
    maker_score: u64,
    total_score: u64,
): u64 {
    if (total_score == 0 || maker_score == 0) { return 0 };
    let allocation = if (fund.treasury.value() >= fund.reward_per_epoch) {
        fund.reward_per_epoch
    } else {
        fund.treasury.value()
    };
    ((allocation as u128) * (maker_score as u128) / (total_score as u128)) as u64
}

public fun record_total_allocation(record: &EpochRecord): u64 { record.total_allocation }
public fun record_total_score(record: &EpochRecord): u64 { record.total_score }
public fun record_remaining_rewards(record: &EpochRecord): u64 { record.rewards.value() }
public fun record_fund_id(record: &EpochRecord): address { record.fund_id }

/// Look up a specific maker's score and whether they've claimed.
public fun record_maker_info(
    record: &EpochRecord,
    balance_manager_id: address,
): (u64, bool) {
    let mut score = 0u64;
    let len = record.maker_scores.length();
    let mut i = 0;
    while (i < len) {
        let entry = &record.maker_scores[i];
        if (entry.balance_manager_id == balance_manager_id) {
            score = entry.score;
            break
        };
        i = i + 1;
    };
    let claimed = record.claimed.contains(&balance_manager_id);
    (score, claimed)
}

// === Constructors ===
public fun new_maker_reward_entry(
    balance_manager_id: address,
    score: u64,
): MakerRewardEntry {
    MakerRewardEntry { balance_manager_id, score }
}

// === Test-only helpers ===

/// Submit epoch results without enclave signature verification.
#[test_only]
public fun submit_epoch_results_test(
    fund: &mut IncentiveFund,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_score: u64,
    maker_rewards: vector<MakerRewardEntry>,
    ctx: &mut TxContext,
) {
    assert!(fund.is_active, EFundNotActive);
    assert!(epoch_end_ms > epoch_start_ms, EInvalidEpochRange);
    assert!(epoch_end_ms - epoch_start_ms == fund.epoch_duration_ms, EInvalidEpochDuration);
    assert!(epoch_start_ms >= fund.created_at_ms, EEpochBeforeFundCreation);
    assert!(!fund.submitted_epochs.contains(epoch_start_ms), EEpochAlreadySubmitted);

    let allocation = if (total_score == 0) {
        0
    } else if (fund.treasury.value() >= fund.reward_per_epoch) {
        fund.reward_per_epoch
    } else {
        fund.treasury.value()
    };

    let num_makers = maker_rewards.length();
    let fund_id = object::id(fund).to_address();

    let record = EpochRecord {
        id: object::new(ctx),
        pool_id: fund.pool_id,
        fund_id,
        epoch_start_ms,
        epoch_end_ms,
        total_allocation: allocation,
        total_score,
        rewards: fund.treasury.split(allocation),
        maker_scores: maker_rewards,
        claimed: vector::empty(),
    };

    event::emit(EpochResultsSubmitted {
        pool_id: fund.pool_id,
        fund_id,
        epoch_start_ms,
        epoch_end_ms,
        total_allocation: allocation,
        num_makers,
    });

    fund.submitted_epochs.add(epoch_start_ms, true);
    transfer::share_object(record);
}
