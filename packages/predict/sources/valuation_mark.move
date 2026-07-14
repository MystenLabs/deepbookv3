// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored per-market valuation mark and its flush-acceptance policy.
///
/// A mark memoizes one market's exact oracle-priced per-order liability (the
/// payout-tree walk) plus the pricing anchors it was computed at, so the pool
/// flush can read the market without walking any tree. This module owns the
/// mark's lifecycle: construction at refresh, the freshness/drift acceptance
/// checks, and the write-through maintenance trade flows apply (mint adds its
/// `net_premium`, live redeem subtracts its `redeem_amount`, liquidation
/// subtracts the knocked-out order's live value). It does not own the walk or
/// the market's cash — `expiry_market` composes those.
module deepbook_predict::valuation_mark;

use deepbook_predict::{pricing::Pricer, valuation_config::ValuationConfig};
use sui::clock::Clock;

const EValuationMarkStale: u64 = 0;

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
    /// Σ liability added by trades since the walk (mint `net_premium`s), each
    /// priced at its own op's oracle.
    added_since_compute: u64,
    /// Σ liability removed by trades since the walk (live-redeem
    /// `redeem_amount`s and liquidated orders' live values), each priced at its
    /// own op's oracle.
    removed_since_compute: u64,
    /// On-chain landing time of the refresh that computed this mark.
    computed_at_ms: u64,
    /// Probe contract strikes fanned around the refresh-time forward
    /// (drift-guard anchors; `pricing::price_probes`).
    probe_strikes: vector<u64>,
    /// Fair UP price of each probe at refresh, parallel to `probe_strikes`.
    probe_prices: vector<u64>,
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

/// Snapshot a fresh mark: the just-walked liability plus the pricer's probe
/// anchors, with zeroed trade deltas.
public(package) fun new(liability: u64, pricer: &Pricer, clock: &Clock): ValuationMark {
    let (probe_strikes, probe_prices) = pricer.price_probes();
    ValuationMark {
        computed_liability: liability,
        added_since_compute: 0,
        removed_since_compute: 0,
        computed_at_ms: clock.timestamp_ms(),
        probe_strikes,
        probe_prices,
    }
}

/// Abort unless this mark is still usable by the flush: younger than the
/// freshness ceiling, and every stored probe contract still pricing within the
/// drift tolerance on the live surface in `pricer`.
public(package) fun assert_flushable(
    mark: &ValuationMark,
    valuation_config: &ValuationConfig,
    pricer: &Pricer,
    clock: &Clock,
) {
    assert!(
        clock.timestamp_ms() - mark.computed_at_ms <= valuation_config.nav_mark_freshness_ms(),
        EValuationMarkStale,
    );
    pricer.assert_probe_prices_within(
        &mark.probe_strikes,
        &mark.probe_prices,
        valuation_config.nav_mark_drift_epsilon(),
    );
}

/// Write a trade's liability increase through to the mark's delta accumulator.
public(package) fun add_liability(mark: &mut ValuationMark, amount: u64) {
    mark.added_since_compute = mark.added_since_compute + amount;
}

/// Write a trade's liability decrease through to the mark's delta accumulator.
/// Never clamps here — the mixed-anchor netting happens once, in `liability`.
public(package) fun remove_liability(mark: &mut ValuationMark, amount: u64) {
    mark.removed_since_compute = mark.removed_since_compute + amount;
}
