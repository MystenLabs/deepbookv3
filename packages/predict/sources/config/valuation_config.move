// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored flush-acceptance policy for per-market valuation marks.
///
/// ProtocolConfig owns this mutable policy. The pool flush reads it when
/// deciding whether a market's stored valuation mark is still usable: a hard
/// freshness ceiling on mark age — the backstop against a stalled feed, which
/// shows zero measured drift and so cannot be caught by the drift spread.
/// Oracle drift itself needs no tolerance knob: the measured worst-case drift
/// is priced into the flush mark as a bid/ask spread borne by the transactor.
module deepbook_predict::valuation_config;

use deepbook_predict::config_constants;

/// Acceptance parameters for stored valuation marks at the pool flush.
public struct ValuationConfig has store {
    /// Hard ceiling on stored-mark age in milliseconds, regardless of oracle drift.
    nav_mark_freshness_ms: u64,
}

// === Public-Package Functions ===

public(package) fun nav_mark_freshness_ms(config: &ValuationConfig): u64 {
    config.nav_mark_freshness_ms
}

public(package) fun new(): ValuationConfig {
    ValuationConfig {
        nav_mark_freshness_ms: config_constants::default_nav_mark_freshness_ms!(),
    }
}

public(package) fun set_nav_mark_freshness_ms(config: &mut ValuationConfig, value: u64) {
    config_constants::assert_nav_mark_freshness_ms(value);
    config.nav_mark_freshness_ms = value;
}
