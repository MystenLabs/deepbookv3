// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored per-market valuation mark: a dumb measurement component.
///
/// A mark memoizes one market's exact oracle-priced per-order liability (the
/// payout-tree walk) so the pool flush can read the market without walking any
/// tree. This module owns the mark's lifecycle: construction at refresh, the
/// write-through maintenance trade flows apply (mint adds its `net_premium`,
/// live redeem subtracts its `redeem_amount`, liquidation subtracts the
/// knocked-out order's live value), and measuring `drift` — the potential
/// dollar impact of oracle movement since the walk, against a fresh `Pricer`.
/// It deliberately owns NO acceptance policy: whether a mark is fresh enough or
/// the measured drift acceptable is decided downstream by `plp`, which
/// aggregates across markets. It does not own the walk or the market's cash —
/// `expiry_market` composes those.
module deepbook_predict::valuation_mark;

use deepbook_predict::pricing::{Self, Pricer};
use fixed_math::math;
use propbook::block_scholes_svi_feed::SVIParams;
use sui::clock::Clock;

/// One market's stored valuation mark. Free cash is never stored — the flush
/// reads it live, so cash moves need no mark maintenance. Trade write-through
/// accumulates in the two delta fields rather than mutating the walked number:
/// the walk's output stays auditable against a fresh walk at the same anchors,
/// and the mixed-anchor netting is applied once at read time, order-independent,
/// instead of destructively clamping op by op.
public struct ValuationMark has copy, drop, store {
    /// Exact oracle-priced per-order liability the refresh walk computed at
    /// `computed_at_ms`. Never mutated between refreshes.
    computed_liability: u64,
    /// Σ liability added by trades since the walk: each added order's value
    /// priced at THIS MARK'S STORED ANCHORS, never at the op's own oracle —
    /// so every component of `liability` shares one valuation time and the
    /// anchor-to-live drift envelope bounds the whole current book. (Op-priced
    /// deltas would be path-dependent: an oracle round trip between refresh
    /// and flush leaves endpoint drift near zero while an op priced at the
    /// peak stays in the sum.)
    added_since_compute: u64,
    /// Σ liability removed by trades since the walk (live redeems and
    /// liquidated orders), each priced at this mark's stored anchors.
    removed_since_compute: u64,
    /// On-chain landing time of the refresh that computed this mark.
    computed_at_ms: u64,
    /// Forward the walk priced at (drift anchor). Raw snapshot, not derived
    /// terms: `drift` derives both sides with the same code at read time, so
    /// the envelope formula can change without stored state aging.
    anchor_forward: u64,
    /// SVI params the walk priced at (drift anchor).
    anchor_svi: SVIParams,
}

// === Public-Package Functions ===

/// The mark's current liability: the walked number plus all trade deltas since,
/// netted once here. The deltas are priced at their ops' oracles while the
/// walked sum is anchored at the refresh oracle (drift-bounded), so the netting
/// can exceed the sum by that bounded residual — clamp it rather than abort a
/// read in the mandatory flush path.
public(package) fun liability(mark: &ValuationMark): u64 {
    (mark.computed_liability + mark.added_since_compute).saturating_sub(mark.removed_since_compute)
}

public(package) fun computed_at_ms(mark: &ValuationMark): u64 {
    mark.computed_at_ms
}

/// Measure this mark's potential oracle drift against the live inputs in
/// `pricer`: an upper bound on how far ANY single contract's fair price can
/// have moved since the walk, as a fraction of full payout in FLOAT_SCALING
/// (`pricing::drift_envelope` between the stored anchors and the live
/// snapshot). Oracle movement only — trade deltas are already inside
/// `liability`. The caller converts to dollars and judges in aggregate; this
/// component measures, it does not accept or reject.
public(package) fun drift(mark: &ValuationMark, pricer: &Pricer): u64 {
    pricer.drift_envelope(mark.anchor_forward, &mark.anchor_svi)
}

/// Snapshot a fresh mark: the just-walked liability with zeroed trade deltas,
/// anchored to the oracle inputs the walk priced at.
public(package) fun new(liability: u64, pricer: &Pricer, clock: &Clock): ValuationMark {
    ValuationMark {
        computed_liability: liability,
        added_since_compute: 0,
        removed_since_compute: 0,
        computed_at_ms: clock.timestamp_ms(),
        anchor_forward: pricer.forward(),
        anchor_svi: pricer.svi_params(),
    }
}

/// Write an added order through to the mark, valued at the stored anchors.
public(package) fun add_order(
    mark: &mut ValuationMark,
    lower: u64,
    higher: u64,
    quantity: u64,
    floor_amount: u64,
) {
    let value = mark.order_value_at_anchor(lower, higher, quantity, floor_amount);
    mark.added_since_compute = mark.added_since_compute + value;
}

/// Write a removed order (live redeem or liquidation) through to the mark,
/// valued at the stored anchors. Never clamps here — the residual netting
/// happens once, in `liability`.
public(package) fun remove_order(
    mark: &mut ValuationMark,
    lower: u64,
    higher: u64,
    quantity: u64,
    floor_amount: u64,
) {
    let value = mark.order_value_at_anchor(lower, higher, quantity, floor_amount);
    mark.removed_since_compute = mark.removed_since_compute + value;
}

/// One order's live value under this mark's anchors: the anchor-priced range
/// value net of the static floor, floored at zero (the same per-order shape the
/// walk aggregates).
fun order_value_at_anchor(
    mark: &ValuationMark,
    lower: u64,
    higher: u64,
    quantity: u64,
    floor_amount: u64,
): u64 {
    let price = pricing::range_price_at(&mark.anchor_svi, mark.anchor_forward, lower, higher);
    math::mul(quantity, price).saturating_sub(floor_amount)
}
