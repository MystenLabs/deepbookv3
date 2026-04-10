// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Permissionless maker incentive platform for DeepBook pools.
///
/// Anyone can create an incentive fund by depositing DEEP tokens,
/// targeting a DeepBook pool, and choosing scoring parameters. Multiple funds
/// can target the same pool — makers earn from all active funds simultaneously,
/// scored independently by each fund's parameters.
///
/// Treasury withdrawal (fund owner only): DEEP in excess of a two-epoch
/// commitment at `reward_per_epoch` is withdrawable. Concretely, the contract
/// locks `min(treasury, 2 * reward_per_epoch)` — the budget for the current
/// and next full epoch at the configured rate — so owners can reclaim deep
/// runway without pulling rewards already earmarked for near-term epochs.
///
/// Scoring parameter changes (`reward_per_epoch`, `alpha_bps`, `quality_p`) are
/// **delayed**: the owner schedules a full replacement snapshot that takes
/// effect after `param_change_delay_epochs()` full incentive epochs (fixed 24h
/// each) from the time of scheduling. `set_fund_active` remains immediate
/// for emergency pause. Pending values apply automatically when due on
/// `submit_epoch_results`, `withdraw_treasury`, or `finalize_pending_params`.
///
/// Scores are computed off-chain inside a Nautilus secure enclave and verified
/// on-chain via Ed25519 attestation.
///
/// Per-maker, per-window score:
///   depth            = sqrt(time-averaged bid_qty × ask_qty)  (effective size)
///   spread_factor    = (pool_median_spread / maker_spread) ^ alpha
///   time_fraction    = active_duration / window_duration
///   activity         = maker_base_fill_volume / window_base_volume  (floored)
///   quality          = spread_factor × time_fraction × activity
///   window_inner     = depth × loyalty × quality^(1/quality_p)
///
/// Loyalty is an integer in [1, 3] from consecutive prior epochs with scored
/// participation (off-chain indexed); see deepbook-server loyalty API.
///
/// Window weighting (higher-volume windows count more):
///   window_weight    = max(window_volume / total_epoch_volume, floor)
///
/// Epoch aggregation:
///   maker_epoch_score = Σ (window_inner × window_weight)
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

/// Fixed incentive epoch length: 24 hours (must match off-chain scoring).
const EPOCH_DURATION_MS: u64 = 86_400_000;
/// Fixed scoring window length within an epoch: 1 hour.
const WINDOW_DURATION_MS: u64 = 3_600_000;
/// Parameter updates take effect this many full epochs after scheduling (~N+2).
const PARAM_CHANGE_DELAY_EPOCHS: u64 = 2;

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
const EInvalidQualityP: u64 = 11;
const EWithdrawAmountTooLarge: u64 = 12;
const EWithdrawZero: u64 = 13;

// === OTW ===
public struct MAKER_INCENTIVES has drop {}

/// Ownership capability for an IncentiveFund. Returned to the fund creator.
/// Transferable — the fund creator can hand off management to another address.
public struct FundOwnerCap has key, store {
    id: UID,
    fund_id: ID,
}

/// Snapshot of scoring parameters scheduled to replace the active ones after
/// `params_effective_at_ms`.
public struct PendingFundParams has copy, drop, store {
    reward_per_epoch: u64,
    alpha_bps: u64,
    quality_p: u64,
}

/// Permissionless incentive fund. All rewards are denominated in DEEP.
public struct IncentiveFund has key, store {
    id: UID,
    pool_id: address,
    treasury: Balance<DEEP>,
    reward_per_epoch: u64,
    /// Spread-factor exponent, scaled by 10 000 (e.g. 15 000 = 1.5).
    alpha_bps: u64,
    /// Root for quality compression: quality term is raised to (1/quality_p).
    /// Must be >= 1. Typical value 3.
    quality_p: u64,
    is_active: bool,
    submitted_epochs: Table<u64, bool>,
    /// Clock timestamp (ms) when the fund was created. Epochs before this
    /// time cannot be submitted, preventing retroactive reward drains.
    created_at_ms: u64,
    /// If set, these values replace the active params once `Clock` >=
    /// `params_effective_at_ms`.
    pending_params: Option<PendingFundParams>,
    /// Milliseconds since epoch when pending params (if any) take effect.
    params_effective_at_ms: u64,
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
    /// Must match `fund.alpha_bps` when verifying the enclave signature.
    alpha_bps: u64,
    /// Must match `fund.quality_p` when verifying the enclave signature.
    quality_p: u64,
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
    alpha_bps: u64,
    quality_p: u64,
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

/// Fund owner withdrew uncommitted treasury DEEP (see module docs).
public struct TreasuryWithdrawn has copy, drop {
    pool_id: address,
    fund_id: address,
    owner: address,
    amount: u64,
    treasury_after: u64,
    locked_after: u64,
    withdrawable_after: u64,
    reward_per_epoch: u64,
}

public struct FundParamsChangeScheduled has copy, drop {
    pool_id: address,
    fund_id: address,
    reward_per_epoch: u64,
    alpha_bps: u64,
    quality_p: u64,
    effective_at_ms: u64,
    scheduled_at_ms: u64,
}

public struct FundParamsChangeApplied has copy, drop {
    pool_id: address,
    fund_id: address,
    reward_per_epoch: u64,
    alpha_bps: u64,
    quality_p: u64,
}

public struct FundParamsChangeCancelled has copy, drop {
    pool_id: address,
    fund_id: address,
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
    quality_p: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): FundOwnerCap {
    assert!(quality_p >= 1, EInvalidQualityP);
    let created_at_ms = clock.timestamp_ms();
    let fund = IncentiveFund {
        id: object::new(ctx),
        pool_id,
        treasury: balance::zero(),
        reward_per_epoch,
        alpha_bps,
        quality_p,
        is_active: true,
        submitted_epochs: table::new(ctx),
        created_at_ms,
        pending_params: option::none(),
        params_effective_at_ms: 0,
    };

    let fund_id = object::id(&fund);

    event::emit(FundCreated {
        pool_id,
        fund_id,
        reward_per_epoch,
        creator: ctx.sender(),
        created_at_ms,
        alpha_bps,
        quality_p,
    });

    transfer::share_object(fund);

    FundOwnerCap {
        id: object::new(ctx),
        fund_id,
    }
}

// === Fund management (owner only) ===

/// Schedule replacement scoring parameters. They take effect when
/// `clock.timestamp_ms() >= scheduled_at + param_change_delay_epochs() * EPOCH_DURATION_MS`.
/// Replaces any prior pending schedule. Pass the full desired future snapshot.
public fun schedule_params_change(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    clock: &Clock,
    reward_per_epoch: u64,
    alpha_bps: u64,
    quality_p: u64,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    assert!(quality_p >= 1, EInvalidQualityP);
    maybe_apply_pending_params(fund, clock);
    let now = clock.timestamp_ms();
    let delay_ms = (PARAM_CHANGE_DELAY_EPOCHS as u128) * (EPOCH_DURATION_MS as u128);
    let at = (now as u128) + delay_ms;
    let effective_at_ms = if (at > (std::u64::max_value!() as u128)) {
        std::u64::max_value!()
    } else {
        (at as u64)
    };
    fund.pending_params = option::some(PendingFundParams {
        reward_per_epoch,
        alpha_bps,
        quality_p,
    });
    fund.params_effective_at_ms = effective_at_ms;
    event::emit(FundParamsChangeScheduled {
        pool_id: fund.pool_id,
        fund_id: object::id(fund).to_address(),
        reward_per_epoch,
        alpha_bps,
        quality_p,
        effective_at_ms,
        scheduled_at_ms: now,
    });
}

/// Drop a scheduled parameter change before it takes effect. No-op if none pending.
public fun cancel_scheduled_params_change(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    if (option::is_none(&fund.pending_params)) {
        return
    };
    fund.pending_params = option::none();
    fund.params_effective_at_ms = 0;
    event::emit(FundParamsChangeCancelled {
        pool_id: fund.pool_id,
        fund_id: object::id(fund).to_address(),
    });
}

public fun set_fund_active(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    active: bool,
) {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    fund.is_active = active;
}

/// Withdraw DEEP from the treasury up to the uncommitted balance (treasury minus
/// the two-epoch lock at `reward_per_epoch`). Recipient is the transaction sender.
public fun withdraw_treasury(
    cap: &FundOwnerCap,
    fund: &mut IncentiveFund,
    clock: &Clock,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DEEP> {
    assert!(cap.fund_id == object::id(fund), ENotFundOwner);
    maybe_apply_pending_params(fund, clock);
    assert!(amount > 0, EWithdrawZero);
    let max_w = withdrawable_treasury_amount(fund);
    assert!(amount <= max_w, EWithdrawAmountTooLarge);

    let pool_id = fund.pool_id;
    let fund_id = object::id(fund).to_address();
    let owner = ctx.sender();
    let rpe = fund.reward_per_epoch;

    let out = fund.treasury.split(amount);
    let treasury_after = fund.treasury.value();
    let locked_after = locked_treasury_amount(fund);
    let withdrawable_after = treasury_after - locked_after;

    event::emit(TreasuryWithdrawn {
        pool_id,
        fund_id,
        owner,
        amount,
        treasury_after,
        locked_after,
        withdrawable_after,
        reward_per_epoch: rpe,
    });

    coin::from_balance(out, ctx)
}

/// Apply scheduled scoring parameters if `clock` has reached `params_effective_at_ms`.
/// Permissionless; also invoked from `submit_epoch_results` and `withdraw_treasury`.
public fun finalize_pending_params(fund: &mut IncentiveFund, clock: &Clock) {
    maybe_apply_pending_params(fund, clock);
}

fun maybe_apply_pending_params(fund: &mut IncentiveFund, clock: &Clock) {
    if (option::is_none(&fund.pending_params)) {
        return
    };
    if (clock.timestamp_ms() < fund.params_effective_at_ms) {
        return
    };
    let p = *option::borrow(&fund.pending_params);
    fund.pending_params = option::none();
    fund.params_effective_at_ms = 0;
    fund.reward_per_epoch = p.reward_per_epoch;
    fund.alpha_bps = p.alpha_bps;
    fund.quality_p = p.quality_p;
    event::emit(FundParamsChangeApplied {
        pool_id: fund.pool_id,
        fund_id: object::id(fund).to_address(),
        reward_per_epoch: p.reward_per_epoch,
        alpha_bps: p.alpha_bps,
        quality_p: p.quality_p,
    });
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
    clock: &Clock,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_score: u64,
    maker_rewards: vector<MakerRewardEntry>,
    timestamp_ms: u64,
    signature: vector<u8>,
    ctx: &mut TxContext,
) {
    maybe_apply_pending_params(fund, clock);
    assert!(fund.is_active, EFundNotActive);
    assert!(epoch_end_ms > epoch_start_ms, EInvalidEpochRange);
    assert!(epoch_end_ms - epoch_start_ms == EPOCH_DURATION_MS, EInvalidEpochDuration);
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
        alpha_bps: fund.alpha_bps,
        quality_p: fund.quality_p,
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
public fun fund_quality_p(fund: &IncentiveFund): u64 { fund.quality_p }

/// Full incentive epochs between scheduling and activation (`2` = ~N+2 notice).
public fun param_change_delay_epochs(): u64 { PARAM_CHANGE_DELAY_EPOCHS }

/// Whether a parameter change is scheduled (not yet applied).
public fun fund_has_pending_params(fund: &IncentiveFund): bool {
    option::is_some(&fund.pending_params)
}

/// When pending params take effect; `0` if none scheduled.
public fun fund_params_effective_at_ms(fund: &IncentiveFund): u64 {
    fund.params_effective_at_ms
}

/// Pending snapshot: `(has_pending, reward_per_epoch, alpha_bps, quality_p, effective_at_ms)`.
/// If `has_pending` is false, other fields are zero.
public fun fund_pending_params_info(fund: &IncentiveFund): (bool, u64, u64, u64, u64) {
    if (option::is_none(&fund.pending_params)) {
        return (false, 0, 0, 0, 0)
    };
    let p = *option::borrow(&fund.pending_params);
    (
        true,
        p.reward_per_epoch,
        p.alpha_bps,
        p.quality_p,
        fund.params_effective_at_ms,
    )
}

/// Active params as of `clock` (pending applied if due, without mutating storage).
public fun fund_effective_reward_per_epoch(fund: &IncentiveFund, clock: &Clock): u64 {
    effective_reward_per_epoch(fund, clock.timestamp_ms())
}

public fun fund_effective_alpha_bps(fund: &IncentiveFund, clock: &Clock): u64 {
    effective_alpha_bps(fund, clock.timestamp_ms())
}

public fun fund_effective_quality_p(fund: &IncentiveFund, clock: &Clock): u64 {
    effective_quality_p(fund, clock.timestamp_ms())
}
/// Protocol-fixed epoch length (24h); retained for stable view-API / tooling.
public fun fund_epoch_duration_ms(_fund: &IncentiveFund): u64 { EPOCH_DURATION_MS }
/// Protocol-fixed window length (1h); retained for stable view-API / tooling.
public fun fund_window_duration_ms(_fund: &IncentiveFund): u64 { WINDOW_DURATION_MS }
public fun fund_pool_id(fund: &IncentiveFund): address { fund.pool_id }
public fun fund_created_at_ms(fund: &IncentiveFund): u64 { fund.created_at_ms }

/// How many full epochs can be funded from the current treasury.
public fun fund_funded_epochs(fund: &IncentiveFund): u64 {
    if (fund.reward_per_epoch == 0) { return 0 };
    fund.treasury.value() / fund.reward_per_epoch
}

/// DEEP reserved for the current and next full epoch at `reward_per_epoch`
/// (capped by the actual treasury balance).
public fun fund_locked_treasury(fund: &IncentiveFund): u64 {
    locked_treasury_amount(fund)
}

/// Treasury balance the owner may withdraw (surplus beyond [`fund_locked_treasury`]).
public fun fund_withdrawable_treasury(fund: &IncentiveFund): u64 {
    withdrawable_treasury_amount(fund)
}

fun two_epoch_lock_cap(reward_per_epoch: u64): u64 {
    if (reward_per_epoch == 0) {
        return 0
    };
    let twice = (reward_per_epoch as u128) * 2;
    let u64_max = (std::u64::max_value!() as u128);
    let cap = if (twice > u64_max) {
        std::u64::max_value!()
    } else {
        (twice as u64)
    };
    cap
}

fun locked_treasury_amount(fund: &IncentiveFund): u64 {
    let t = fund.treasury.value();
    let cap = two_epoch_lock_cap(fund.reward_per_epoch);
    if (t < cap) {
        t
    } else {
        cap
    }
}

fun withdrawable_treasury_amount(fund: &IncentiveFund): u64 {
    let t = fund.treasury.value();
    let locked = locked_treasury_amount(fund);
    t - locked
}

fun effective_reward_per_epoch(fund: &IncentiveFund, now_ms: u64): u64 {
    if (option::is_some(&fund.pending_params) && now_ms >= fund.params_effective_at_ms) {
        return option::borrow(&fund.pending_params).reward_per_epoch
    };
    fund.reward_per_epoch
}

fun effective_alpha_bps(fund: &IncentiveFund, now_ms: u64): u64 {
    if (option::is_some(&fund.pending_params) && now_ms >= fund.params_effective_at_ms) {
        return option::borrow(&fund.pending_params).alpha_bps
    };
    fund.alpha_bps
}

fun effective_quality_p(fund: &IncentiveFund, now_ms: u64): u64 {
    if (option::is_some(&fund.pending_params) && now_ms >= fund.params_effective_at_ms) {
        return option::borrow(&fund.pending_params).quality_p
    };
    fund.quality_p
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
    clock: &Clock,
    epoch_start_ms: u64,
    epoch_end_ms: u64,
    total_score: u64,
    maker_rewards: vector<MakerRewardEntry>,
    ctx: &mut TxContext,
) {
    maybe_apply_pending_params(fund, clock);
    assert!(fund.is_active, EFundNotActive);
    assert!(epoch_end_ms > epoch_start_ms, EInvalidEpochRange);
    assert!(epoch_end_ms - epoch_start_ms == EPOCH_DURATION_MS, EInvalidEpochDuration);
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
