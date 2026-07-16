// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical strike-range codec for Predict.
///
/// Predict's canonical strike representation is an absolute tick from zero
/// (`finite_strike = tick * tick_size`). Ranges travel as the pair
/// `(lower_tick, higher_tick)` everywhere on-chain — public entrypoints, events,
/// and (packed) order IDs — so there is no standalone packed range key. This module
/// owns every tick <-> raw-strike crossing: tick-to-raw for the pricing boundary,
/// and raw-to-tick for oracle facts (the settlement prefix threshold and the
/// reference grid snap). It is stateless: every conversion
/// takes the owning market's `tick_size`. Range-shape validity (lower < higher,
/// sentinels) is enforced by `order` when ticks are packed into an order ID, so this
/// codec does not re-check it. Finite ticks occupy
/// `1..pos_inf_tick - 1`; tick `0` is the negative-infinity sentinel as a lower tick
/// and `pos_inf_tick` is the positive-infinity sentinel as a higher tick.
module deepbook_predict::range_codec;

use deepbook_predict::constants;

/// A raw price-axis value derived from a tick. `strike_from_tick` is the sole
/// constructor, so a `Strike`-typed consumer cannot receive a bare `u64` (a tick,
/// quantity, or fee) that skipped this codec.
public struct Strike(u64) has copy, drop;

/// Raw strike for one boundary tick, mapping the open-ended sentinels: tick `0`
/// is `neg_inf`, `pos_inf_tick` is `pos_inf`. Position-free because range-shape
/// validation (`order::assert_valid_order_shape`) makes the sentinels exclusive:
/// `0` occurs only as a lower tick and `pos_inf_tick` only as a higher tick.
/// The only `Strike` constructor; `public` so PTB/devInspect pricing reads can
/// chain it into `pricing::up_price`/`range_price`.
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

/// Smallest tick whose strike is `>= settlement`: every finite boundary with
/// `tick < prefix_limit_tick` satisfies `tick * tick_size < settlement` and is
/// therefore active in the settlement prefix walk, which preserves the half-open
/// `(lower, higher]` payoff (settlement equal to a higher boundary does not apply
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

/// Half-open `(lower, higher]` — the payout-side pair of the tree's prefix-walk
/// reserve (R1); diverges only at settlement 0 (unreachable), which the walk reserves.
public(package) fun settlement_in_range(
    lower_tick: u64,
    higher_tick: u64,
    settlement: u64,
    tick_size: u64,
): bool {
    let limit = prefix_limit_tick(settlement, tick_size);
    lower_tick < limit && (higher_tick == constants::pos_inf_tick!() || limit <= higher_tick)
}
