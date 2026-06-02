// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-feed template policy used when creating future expiry markets.
///
/// ProtocolConfig stores one template per Pyth Lazer feed and exposes the
/// admin entrypoints that mutate these values. Expiry markets snapshot the
/// values at creation.
module deepbook_predict::feed_template;

use deepbook_predict::config_constants;

/// Admin-selected template values for future expiry markets of one feed.
public struct FeedTemplate has copy, drop, store {
    /// Strike tick size for the feed's future expiry markets.
    tick_size: u64,
    /// Window before expiry over which trade fees ramp up.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables.
    expiry_fee_max_multiplier: u64,
}

// === Public-Package Functions ===

public(package) fun tick_size(template: &FeedTemplate): u64 {
    template.tick_size
}

public(package) fun expiry_fee_window_ms(template: &FeedTemplate): u64 {
    template.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(template: &FeedTemplate): u64 {
    template.expiry_fee_max_multiplier
}

public(package) fun new(
    tick_size: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
): FeedTemplate {
    config_constants::assert_oracle_tick_size(tick_size);
    config_constants::assert_expiry_fee_window_ms(expiry_fee_window_ms);
    config_constants::assert_expiry_fee_max_multiplier(expiry_fee_max_multiplier);
    FeedTemplate { tick_size, expiry_fee_window_ms, expiry_fee_max_multiplier }
}

public(package) fun set_tick_size(template: &mut FeedTemplate, tick_size: u64) {
    config_constants::assert_oracle_tick_size(tick_size);
    template.tick_size = tick_size;
}

public(package) fun set_expiry_fee_window_ms(template: &mut FeedTemplate, window_ms: u64) {
    config_constants::assert_expiry_fee_window_ms(window_ms);
    template.expiry_fee_window_ms = window_ms;
}

public(package) fun set_expiry_fee_max_multiplier(
    template: &mut FeedTemplate,
    max_multiplier: u64,
) {
    config_constants::assert_expiry_fee_max_multiplier(max_multiplier);
    template.expiry_fee_max_multiplier = max_multiplier;
}
