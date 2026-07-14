// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored per-market valuation mark: a dumb measurement component.
///
/// A mark memoizes one market's exact oracle-priced per-order liability (the
/// payout-tree walk) so the pool flush can read the market without walking any
/// tree. This module owns only the mark's data discipline; acceptance policy
/// (freshness) is `plp`'s, and order valuation is `strike_exposure`'s — the
/// mark hands back its anchors as a `Pricer` and accumulates what the owner
/// valued.
module deepbook_predict::valuation_mark;

use deepbook_predict::pricing::{Self, Pricer};
use propbook::block_scholes_svi_feed::SVIParams;
use sui::clock::Clock;

/// One market's stored valuation mark. Free cash is never stored — the flush
/// reads it live, so cash moves need no mark maintenance. Every component is
/// valued at the SAME stored anchors: the walked number by the refresh, the
/// trade write-through by `strike_exposure` pricing each added/removed order
/// via `anchor_pricer` — never at an op's own oracle. One valuation basis is
/// what lets the endpoint drift envelope bound the whole current book
/// (op-priced deltas are path-dependent: an oracle round trip between refresh
/// and flush leaves endpoint drift near zero while an op priced at the peak
/// stays in the sum).
public struct ValuationMark has copy, drop, store {
    /// Exact oracle-priced per-order liability the refresh walk computed at
    /// `computed_at_ms`. Never mutated between refreshes.
    computed_liability: u64,
    /// Σ anchor-priced value of orders added since the walk.
    added_at_anchor: u64,
    /// Σ anchor-priced value of orders removed since the walk (live redeems
    /// and liquidations).
    removed_at_anchor: u64,
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

/// The mark's current liability: the walked number plus all trade deltas
/// since, netted once here. All components share the anchor basis, but the
/// walk aggregates quantities per tree range before multiplying while
/// write-through prices per order, so netting can exceed the sum by
/// fixed-point association dust — clamp that dust rather than abort a read in
/// the mandatory flush path.
public(package) fun liability(mark: &ValuationMark): u64 {
    (mark.computed_liability + mark.added_at_anchor).saturating_sub(mark.removed_at_anchor)
}

public(package) fun computed_at_ms(mark: &ValuationMark): u64 {
    mark.computed_at_ms
}

/// Measure this mark's potential oracle drift against the live inputs in
/// `pricer`: an upper bound on how far ANY single contract's fair price can
/// have moved since the walk, as a fraction of full payout in FLOAT_SCALING
/// (`pricing::drift_envelope` between the stored anchors and the live
/// snapshot). Oracle movement only — trade deltas are already inside
/// `liability`.
public(package) fun drift(mark: &ValuationMark, pricer: &Pricer): u64 {
    pricer.drift_envelope(mark.anchor_forward, &mark.anchor_svi)
}

/// Rebuild the stored anchors as a `Pricer` so the mark's owner can value
/// write-through orders at the SAME snapshot the walk priced.
public(package) fun anchor_pricer(mark: &ValuationMark, expiry_market_id: ID): Pricer {
    pricing::from_anchors(expiry_market_id, mark.anchor_forward, mark.anchor_svi)
}

/// Snapshot a fresh mark: the just-walked liability with zeroed trade deltas,
/// anchored to the oracle inputs the walk priced at.
public(package) fun new(liability: u64, pricer: &Pricer, clock: &Clock): ValuationMark {
    ValuationMark {
        computed_liability: liability,
        added_at_anchor: 0,
        removed_at_anchor: 0,
        computed_at_ms: clock.timestamp_ms(),
        anchor_forward: pricer.forward(),
        anchor_svi: pricer.svi_params(),
    }
}

/// Accumulate an added order's anchor-priced value (produced against
/// `anchor_pricer`).
public(package) fun add_value(mark: &mut ValuationMark, value: u64) {
    mark.added_at_anchor = mark.added_at_anchor + value;
}

/// Accumulate a removed order's anchor-priced value (produced against
/// `anchor_pricer`). Never clamps here — the dust netting happens once, in
/// `liability`.
public(package) fun remove_value(mark: &mut ValuationMark, value: u64) {
    mark.removed_at_anchor = mark.removed_at_anchor + value;
}
