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
    /// Acceptance threshold for aggregate mark drift at the flush, in
    /// FLOAT_SCALING. Intended interpretation: the counted marks' combined
    /// measured dollar drift may not exceed this fraction of pool NAV, putting
    /// the bound directly in PLP-price units
    /// (`plp::assert_aggregate_drift_acceptable`). PLACEHOLDER semantics while
    /// the drift model (`valuation_mark::drift`) is stubbed.
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
