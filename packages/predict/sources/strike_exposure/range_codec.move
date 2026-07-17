// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical strike-range codec for Predict.
///
/// Finite strikes are absolute ticks from zero: `strike = tick * tick_size`.
/// Ranges use `(lower_tick, higher_tick)` in entrypoints, events, and order IDs.
/// Tick zero and `pos_inf_tick` are the open lower and upper sentinels. This
/// module owns conversion between those ticks and raw oracle-price coordinates;
/// `order` owns range-shape validation.
module deepbook_predict::range_codec;

use deepbook_predict::constants;

/// A raw price-axis value derived from a tick. Range validity is enforced when
/// production orders are constructed, not by this wrapper.
public struct Strike(u64) has copy, drop;

/// Convert a boundary tick to its raw strike, including the open-end sentinels.
/// Non-sentinel ticks multiply directly by `tick_size`; public PTB and dev-inspect
/// callers are responsible for supplying the intended market domain.
public fun strike_from_tick(tick: u64, tick_size: u64): Strike {
    if (tick == 0) return Strike(constants::neg_inf!());
    if (tick == constants::pos_inf_tick!()) return Strike(constants::pos_inf!());
    Strike(tick * tick_size)
}

/// Raw value for pricing math; consumers re-enter the raw domain only through this.
public(package) fun value(strike: Strike): u64 {
    strike.0
}

public(package) fun is_neg_inf(strike: Strike): bool {
    strike.0 == constants::neg_inf!()
}

public(package) fun is_pos_inf(strike: Strike): bool {
    strike.0 == constants::pos_inf!()
}

#[test_only]
/// Raw-strike constructor for reference-fixture tests that price arbitrary raw
/// points; production strikes are only ever tick-derived via `strike_from_tick`.
public fun strike_for_testing(raw: u64): Strike {
    Strike(raw)
}

/// Smallest tick whose strike is `>= settlement`: every finite boundary with
/// `tick < prefix_limit_tick` satisfies `tick * tick_size < settlement` and is
/// therefore active in the settlement prefix walk, which preserves the half-open
/// `(lower, higher]` payoff (settlement equal to a lower boundary does not apply
/// it). Equals `ceil(settlement / tick_size)`, which can legitimately exceed
/// `pos_inf_tick` (settlement above the encodable range) and so is a plain `u64`
/// comparison bound, never validated as a domain tick.
public(package) fun prefix_limit_tick(settlement: u64, tick_size: u64): u64 {
    settlement.div_ceil(tick_size)
}

/// Tick whose grid interval contains a raw spot (floor). Rounds the opposite way
/// from `prefix_limit_tick`: the prefix threshold is a strict-inequality boundary
/// and rounds up; the grid snap places a spot on the fine grid and rounds down.
public(package) fun grid_tick(spot: u64, tick_size: u64): u64 {
    spot / tick_size
}

/// Return whether a positive normalized settlement lies in `(lower, higher]`,
/// using the same rounded-up boundary as the aggregate settlement prefix.
public(package) fun settlement_in_range(
    lower_tick: u64,
    higher_tick: u64,
    settlement: u64,
    tick_size: u64,
): bool {
    let limit = prefix_limit_tick(settlement, tick_size);
    lower_tick < limit && (higher_tick == constants::pos_inf_tick!() || limit <= higher_tick)
}
