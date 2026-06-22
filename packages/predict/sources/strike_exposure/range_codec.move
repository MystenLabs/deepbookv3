// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Canonical strike-range codec for Predict.
///
/// Predict's canonical strike representation is an absolute tick from zero
/// (`finite_strike = tick * tick_size`). Ranges travel as the pair
/// `(lower_tick, higher_tick)` everywhere on-chain — public entrypoints, events,
/// and (packed) order IDs — so there is no standalone packed range key. This module
/// owns only the boundary conversions: tick-to-raw strike for the pricing/settlement
/// boundary and the settlement prefix threshold. It is stateless: every conversion
/// takes the owning market's `tick_size`. Range-shape validity (lower < higher,
/// sentinels, leveraged one-sidedness) is enforced by `order` when ticks are packed
/// into an order ID, so this codec does not re-check it. Finite ticks occupy
/// `1..pos_inf_tick - 1`; tick `0` is the negative-infinity sentinel as a lower tick
/// and `pos_inf_tick` is the positive-infinity sentinel as a higher tick.
module deepbook_predict::range_codec;

use deepbook_predict::constants;

/// Convert an order's `(lower_tick, higher_tick)` to raw `(lower_strike,
/// higher_strike)` for pricing, mapping the open-ended sentinels: lower tick `0`
/// is `neg_inf`, higher tick `pos_inf_tick` is `pos_inf`.
public(package) fun strikes_from_ticks(
    lower_tick: u64,
    higher_tick: u64,
    tick_size: u64,
): (u64, u64) {
    let lower = if (lower_tick == 0) constants::neg_inf!() else lower_tick * tick_size;
    let higher = if (higher_tick == constants::pos_inf_tick!()) {
        constants::pos_inf!()
    } else {
        higher_tick * tick_size
    };
    (lower, higher)
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
