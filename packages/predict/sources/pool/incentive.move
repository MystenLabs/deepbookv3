// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A single admin-deposited incentive asset on a linear vesting schedule.
///
/// Owns the locked/released split, the linear vesting math, and oracle valuation
/// for one incentive coin type. The pool (`plp`) holds one `IncentiveState` per
/// fixed incentive asset (`SUI`, `DEEP`) as a field and drives it through this
/// module's API. It does not own pool accounting, share pricing, or custody of
/// the pool's DUSDC.
module deepbook_predict::incentive;

use deepbook_predict::{
    constants,
    math as predict_math,
    pricing,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource
};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin};

const EZeroDeposit: u64 = 0;
const EZeroStreamDuration: u64 = 1;
const EStreamDurationTooLong: u64 = 2;
const EFeedMismatch: u64 = 3;

/// Per-incentive holdings on a linear vesting schedule, plus the oracle binding
/// cached from the registry at deposit time (decimals + Lazer feed id) so the
/// pool can value the asset during a sync without reading the registry (which
/// depends on `plp`).
///
/// A deposit lands in `locked` and vests linearly into `released` over the
/// window `[last_compound_ms, end_ms]`. Only `released` is folded into pool NAV
/// and paid out in-kind on withdrawal, so a deposit accrues to holders gradually
/// rather than instantly — and an instant supply+withdraw cannot capture the
/// still-locked remainder (compounding advances on wall-clock time only).
public struct IncentiveState<phantom T> has store {
    /// Vested, claimable balance: priced into NAV and paid out in-kind.
    released: Balance<T>,
    /// Unvested balance still streaming into `released`.
    locked: Balance<T>,
    /// Start of the current release interval (last compound time), in ms.
    last_compound_ms: u64,
    /// End of the linear release window, in ms; 0 once fully vested (no schedule).
    end_ms: u64,
    /// Coin decimals and Lazer feed id, cached from the registry on deposit; 0
    /// until the first deposit (the state is empty and unvalued until then).
    decimals: u8,
    feed_id: u32,
}

// === Public-Package Functions ===

/// An empty, unscheduled incentive state. Used to initialize the pool's fixed
/// incentive fields at vault creation.
public(package) fun empty<T>(): IncentiveState<T> {
    IncentiveState<T> {
        released: balance::zero<T>(),
        locked: balance::zero<T>(),
        last_compound_ms: 0,
        end_ms: 0,
        decimals: 0,
        feed_id: 0,
    }
}

/// Vested (claimable) balance — the portion folded into NAV and paid out in-kind.
public(package) fun released_value<T>(state: &IncentiveState<T>): u64 {
    state.released.value()
}

/// Unvested (still-streaming) balance.
public(package) fun locked_value<T>(state: &IncentiveState<T>): u64 {
    state.locked.value()
}

/// Whether this incentive has no holdings (no released and no locked balance),
/// so it need not be valued during a pool sync.
public(package) fun is_empty<T>(state: &IncentiveState<T>): bool {
    state.released.value() == 0 && state.locked.value() == 0
}

/// Add a deposit and (re)arm the linear vesting window. Vests any prior schedule
/// to now first, so its already-vested portion stays in `released` and only the
/// unvested remainder is re-stretched over the new window with the new deposit.
public(package) fun fund<T>(
    state: &mut IncentiveState<T>,
    deposit: Coin<T>,
    decimals: u8,
    feed_id: u32,
    duration_ms: u64,
    clock: &Clock,
) {
    assert!(deposit.value() > 0, EZeroDeposit);
    assert!(duration_ms > 0, EZeroStreamDuration);
    assert!(duration_ms <= constants::max_incentive_stream_ms!(), EStreamDurationTooLong);
    let now_ms = clock.timestamp_ms();
    state.compound(now_ms);
    state.decimals = decimals;
    state.feed_id = feed_id;
    state.locked.join(deposit.into_balance());
    state.last_compound_ms = now_ms;
    state.end_ms = now_ms + duration_ms;
}

/// Verify the source binding + freshness, vest to now, and return the released
/// balance's DUSDC value. Same freshness bound the market path applies.
public(package) fun sync_value<T>(
    state: &mut IncentiveState<T>,
    config: &ProtocolConfig,
    pyth_source: &PythSource,
    clock: &Clock,
): u64 {
    assert!(pyth_source.feed_id() == state.feed_id, EFeedMismatch);
    pricing::assert_pyth_spot_fresh(config.pricing_config(), pyth_source, clock);
    state.compound(clock.timestamp_ms());
    pyth_source.value_in_dusdc(state.released.value(), state.decimals)
}

/// Vest to `now_ms`, then split the pro-rata `lp_amount / total_supply` share of
/// the released balance, rounding down. `lp_amount <= total_supply`, so the share
/// never exceeds the released balance.
public(package) fun claim<T>(
    state: &mut IncentiveState<T>,
    lp_amount: u64,
    total_supply: u64,
    now_ms: u64,
    ctx: &mut TxContext,
): Coin<T> {
    state.compound(now_ms);
    let amount = predict_math::mul_div_round_down(lp_amount, state.released.value(), total_supply);
    state.released.split(amount).into_coin(ctx)
}

// === Private Functions ===

/// Vest the linear schedule up to `now_ms`, moving the elapsed fraction of the
/// locked balance into the released balance:
///   release = locked * (now_ms - last_compound_ms) / (end_ms - last_compound_ms)
/// No-op when there is no active schedule (`end_ms == 0`) or no time has passed.
/// Once `now_ms` reaches `end_ms`, releases the entire locked remainder and
/// clears the schedule (`end_ms = 0`), so later compounds are no-ops until the
/// next deposit re-arms it.
fun compound<T>(state: &mut IncentiveState<T>, now_ms: u64) {
    if (state.end_ms == 0) return;
    if (now_ms <= state.last_compound_ms) return;

    let locked = state.locked.value();
    let remaining = state.end_ms - state.last_compound_ms;
    let amount = if (now_ms >= state.end_ms) {
        state.last_compound_ms = 0;
        state.end_ms = 0;
        locked
    } else {
        let elapsed = now_ms - state.last_compound_ms;
        state.last_compound_ms = now_ms;
        predict_math::mul_div_round_down(locked, elapsed, remaining)
    };
    if (amount > 0) {
        state.released.join(state.locked.split(amount));
    };
}
