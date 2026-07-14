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
/// reads it live, so cash moves need no mark maintenance.
public struct ValuationMark has copy, drop, store {
    /// Exact oracle-priced per-order liability as of `computed_at_ms`, kept
    /// current by trade write-through between refreshes.
    liability: u64,
    /// On-chain landing time of the refresh that computed this mark.
    computed_at_ms: u64,
    /// Forward the mark was priced at (drift-guard anchor).
    forward: u64,
    /// sqrt of the SVI minimum total variance at refresh (drift-guard tolerance scale).
    sqrt_min_total_variance: u64,
}

// === Public-Package Functions ===

public(package) fun liability(mark: &ValuationMark): u64 {
    mark.liability
}

public(package) fun computed_at_ms(mark: &ValuationMark): u64 {
    mark.computed_at_ms
}

/// Snapshot a fresh mark: the just-walked liability plus the pricer's anchors.
public(package) fun new(liability: u64, pricer: &Pricer, clock: &Clock): ValuationMark {
    ValuationMark {
        liability,
        computed_at_ms: clock.timestamp_ms(),
        forward: pricer.forward(),
        sqrt_min_total_variance: pricer.sqrt_min_total_variance(),
    }
}

/// Abort unless this mark is still usable by the flush: younger than the
/// freshness ceiling, and its oracle anchors within the drift tolerance of the
/// live inputs in `pricer`.
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
    pricer.assert_mark_drift_within(
        mark.forward,
        mark.sqrt_min_total_variance,
        valuation_config.nav_mark_drift_epsilon(),
    );
}

/// Write a trade's exact liability increase through to the mark.
public(package) fun add_liability(mark: &mut ValuationMark, amount: u64) {
    mark.liability = mark.liability + amount;
}

/// Write a trade's liability decrease through to the mark. The delta is priced
/// at the op's oracle while the mark's sum is anchored at its refresh oracle
/// (drift-bounded), so clamp the mixed-anchor residual rather than abort a user
/// exit or liquidation pass.
public(package) fun remove_liability(mark: &mut ValuationMark, amount: u64) {
    mark.liability = mark.liability.saturating_sub(amount);
}
