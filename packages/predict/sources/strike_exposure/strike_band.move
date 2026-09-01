// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Create-time strike-band derivation for Predict expiry markets.
///
/// A market admits at most `max_unique_strike_ticks` finite ticks on the
/// absolute ladder `raw_strike = tick * tick_size`. Create inverts the live UP
/// digital at the mint-probability bounds, pads that belly multiplicatively, and
/// freezes a 900-wide tick window that covers the padded interval. The grid does
/// not move after creation.
module deepbook_predict::strike_band;

use deepbook_predict::{config_constants, constants, pricing::Pricer, range_codec};
use fixed_math::math;

const ECannotInvertStrikeBand: u64 = 0;
const EInvalidStrikeBand: u64 = 1;

/// Frozen tick geometry for one expiry: `raw_strike = tick * tick_size` on
/// finite ticks `[min_tick, min_tick + max_unique_strike_ticks - 1]`.
public struct StrikeBand has copy, drop {
    tick_size: u64,
    min_tick: u64,
}

// === Public Functions ===

public fun tick_size(band: &StrikeBand): u64 {
    band.tick_size
}

public fun min_tick(band: &StrikeBand): u64 {
    band.min_tick
}

// === Public-Package Functions ===

/// Cadence tick size with the from-zero 900-wide window.
public(package) fun cadence_band(tick_size: u64): StrikeBand {
    config_constants::assert_market_tick_size_bounds(tick_size);
    band(tick_size, 1)
}

/// Invert the live UP digital at the mint-probability bounds, pad that belly,
/// and align a 900-wide absolute tick window that covers the padded interval.
///
/// `min_tick_size` is the cadence tick size and is a floor on derived granularity.
/// `belly_pad` is FLOAT_SCALING-scaled and must be a nonzero validated pad.
public(package) fun derive(
    pricer: &Pricer,
    min_entry_probability: u64,
    max_entry_probability: u64,
    belly_pad: u64,
    min_tick_size: u64,
): StrikeBand {
    config_constants::assert_belly_pad(belly_pad);
    assert!(belly_pad >= config_constants::min_belly_pad!(), EInvalidStrikeBand);
    let k_low = invert_up_price_le(pricer, max_entry_probability);
    let mut k_high = invert_up_price_le(pricer, min_entry_probability);
    // A near-step digital can invert both bounds to the same raw strike.
    if (k_high <= k_low) {
        k_high = k_low + min_tick_size;
    };
    from_inverted_strikes(k_low, k_high, belly_pad, min_tick_size)
}

/// Pad and align an already-inverted `[k_low, k_high]` belly. Exposed so unit
/// tests can check the arithmetic with independently computed strikes.
public(package) fun from_inverted_strikes(
    k_low: u64,
    k_high: u64,
    belly_pad: u64,
    min_tick_size: u64,
): StrikeBand {
    config_constants::assert_belly_pad(belly_pad);
    assert!(belly_pad >= config_constants::min_belly_pad!(), EInvalidStrikeBand);
    config_constants::assert_market_tick_size_bounds(min_tick_size);
    assert!(k_low > 0 && k_high > k_low, EInvalidStrikeBand);

    let scale = math::float_scaling!() as u128;
    let pad = belly_pad as u128;
    let padded_low = ((k_low as u128) * scale) / pad;
    let padded_high = ((k_high as u128) * pad) / scale;
    assert!(padded_low > 0 && padded_high > padded_low, EInvalidStrikeBand);
    assert!(padded_high <= (std::u64::max_value!() as u128), EInvalidStrikeBand);

    let span = (padded_high - padded_low) as u64;
    let slots = constants::max_unique_strike_ticks!() - 1;
    let raw_per_tick = span.div_ceil(slots);
    let mut tick_size = align_ceil(raw_per_tick, constants::market_tick_size_unit!());
    if (tick_size < min_tick_size) {
        tick_size = min_tick_size;
    };

    // Flooring min_tick can leave (min_tick + 899) * tick_size short of
    // padded_high; grow tick_size until the frozen window covers both ends.
    let padded_high_u64 = padded_high as u64;
    let padded_low_u64 = padded_low as u64;
    loop {
        config_constants::assert_market_tick_size_bounds(tick_size);
        let mut min_tick = padded_low_u64 / tick_size;
        if (min_tick == 0) {
            min_tick = 1;
        };
        let max_tick = constants::max_tick_in_band!(min_tick);
        let covered_high = (max_tick as u128) * (tick_size as u128);
        if (covered_high >= padded_high) {
            assert!(
                (min_tick as u128) * (tick_size as u128) <= padded_low,
                EInvalidStrikeBand,
            );
            return band(tick_size, min_tick)
        };
        let needed = padded_high_u64.div_ceil(max_tick);
        let bumped = if (needed > tick_size) { needed } else { tick_size + 1 };
        tick_size = align_ceil(bumped, constants::market_tick_size_unit!());
        assert!(tick_size >= min_tick_size, EInvalidStrikeBand);
    }
}

/// Smallest raw strike whose UP digital is `<= target`. The digital is
/// nonincreasing in strike, so this is the left edge of the `<= target` region.
public(package) fun invert_up_price_le(pricer: &Pricer, target: u64): u64 {
    assert!(target > 0 && target < math::float_scaling!(), ECannotInvertStrikeBand);
    let mut lo = 1u64;
    let mut hi = pricer.forward();
    assert!(hi >= lo, ECannotInvertStrikeBand);

    let mut grow = 0u64;
    while (pricer.up_price(range_codec::strike_from_raw(hi)) > target) {
        assert!(hi <= std::u64::max_value!() / 2, ECannotInvertStrikeBand);
        hi = hi * 2;
        grow = grow + 1;
        assert!(grow < 64, ECannotInvertStrikeBand);
    };

    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        if (pricer.up_price(range_codec::strike_from_raw(mid)) > target) {
            lo = mid + 1;
        } else {
            hi = mid;
        };
    };
    assert!(pricer.up_price(range_codec::strike_from_raw(lo)) <= target, ECannotInvertStrikeBand);
    lo
}

// === Private Functions ===

fun band(tick_size: u64, min_tick: u64): StrikeBand {
    assert!(min_tick > 0, EInvalidStrikeBand);
    assert!(
        constants::max_tick_in_band!(min_tick) < constants::pos_inf_tick!(),
        EInvalidStrikeBand,
    );
    StrikeBand { tick_size, min_tick }
}

fun align_ceil(value: u64, unit: u64): u64 {
    assert!(value > 0, EInvalidStrikeBand);
    if (value % unit == 0) {
        value
    } else {
        let rem = value % unit;
        assert!(value <= std::u64::max_value!() - (unit - rem), EInvalidStrikeBand);
        value + (unit - rem)
    }
}
