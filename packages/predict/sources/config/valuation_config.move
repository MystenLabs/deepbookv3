// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored flush-acceptance policy for per-market valuation marks.
///
/// ProtocolConfig owns this mutable policy. The pool flush reads it when deciding
/// whether a market's stored valuation mark is still usable: a hard freshness
/// ceiling on mark age plus the oracle-drift tolerance the drift guard scales by.
module deepbook_predict::valuation_config;

use deepbook_predict::config_constants;

/// Acceptance parameters for stored valuation marks at the pool flush.
public struct ValuationConfig has store {
    /// Hard ceiling on stored-mark age in milliseconds, regardless of oracle drift.
    nav_mark_freshness_ms: u64,
    /// How far the oracle may move before a stored mark is rejected, in
    /// FLOAT_SCALING (0.02 = 2%). Feeds keep moving after a market's refresh,
    /// so the flush re-reads them and rejects the mark when contract prices
    /// could have moved materially since it was computed. Two checks, one knob:
    /// the forward may move at most `epsilon` of one standard deviation of the
    /// price move still expected before expiry, and that expected-move level
    /// itself may shift at most `epsilon` relative. Near expiry the expected
    /// move is small, so the allowed forward drift tightens automatically.
    /// Within tolerance, no contract's fair value can have drifted by more
    /// than about `0.4 * epsilon` of its full payout (~0.8% at the default) —
    /// for the moves these checks see; a wing reshape at a fixed variance floor
    /// passes unexamined (`pricing::assert_mark_drift_within`, known blind spot).
    nav_mark_drift_epsilon: u64,
}

// === Public-Package Functions ===

public(package) fun nav_mark_freshness_ms(config: &ValuationConfig): u64 {
    config.nav_mark_freshness_ms
}

public(package) fun nav_mark_drift_epsilon(config: &ValuationConfig): u64 {
    config.nav_mark_drift_epsilon
}

public(package) fun new(): ValuationConfig {
    ValuationConfig {
        nav_mark_freshness_ms: config_constants::default_nav_mark_freshness_ms!(),
        nav_mark_drift_epsilon: config_constants::default_nav_mark_drift_epsilon!(),
    }
}

public(package) fun set_nav_mark_freshness_ms(config: &mut ValuationConfig, value: u64) {
    config_constants::assert_nav_mark_freshness_ms(value);
    config.nav_mark_freshness_ms = value;
}

public(package) fun set_nav_mark_drift_epsilon(config: &mut ValuationConfig, value: u64) {
    config_constants::assert_nav_mark_drift_epsilon(value);
    config.nav_mark_drift_epsilon = value;
}
