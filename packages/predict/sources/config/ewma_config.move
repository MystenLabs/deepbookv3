// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored parameters for the gas-price EWMA trade penalty.
///
/// `ExpiryMarket` holds the evolving `EwmaState`; this config holds the
/// admin-tunable knobs shared by every market. The penalty is disabled by default.
module deepbook_predict::ewma_config;

use deepbook_predict::config_constants;

/// Admin-tunable EWMA penalty policy. All values are in FLOAT_SCALING.
public struct EwmaConfig has store {
    /// Smoothing factor for the gas-price mean and variance; higher reacts faster.
    alpha: u64,
    /// Standard deviations above the smoothed mean required before a penalty applies.
    z_score_threshold: u64,
    /// Per-unit fee added to a penalized trade's trading fee.
    additional_fee: u64,
    /// Master switch; no penalty applies while false.
    enabled: bool,
}

// === Public-Package Functions ===

public(package) fun alpha(config: &EwmaConfig): u64 {
    config.alpha
}

public(package) fun z_score_threshold(config: &EwmaConfig): u64 {
    config.z_score_threshold
}

public(package) fun additional_fee(config: &EwmaConfig): u64 {
    config.additional_fee
}

public(package) fun enabled(config: &EwmaConfig): bool {
    config.enabled
}

public(package) fun new(): EwmaConfig {
    EwmaConfig {
        alpha: config_constants::default_ewma_alpha!(),
        z_score_threshold: config_constants::default_ewma_z_score_threshold!(),
        additional_fee: config_constants::default_ewma_additional_fee!(),
        enabled: false,
    }
}

public(package) fun set_params(
    config: &mut EwmaConfig,
    alpha: u64,
    z_score_threshold: u64,
    additional_fee: u64,
) {
    config_constants::assert_ewma_alpha(alpha);
    config_constants::assert_ewma_z_score_threshold(z_score_threshold);
    config_constants::assert_ewma_additional_fee(additional_fee);
    config.alpha = alpha;
    config.z_score_threshold = z_score_threshold;
    config.additional_fee = additional_fee;
}

public(package) fun set_enabled(config: &mut EwmaConfig, enabled: bool) {
    config.enabled = enabled;
}
