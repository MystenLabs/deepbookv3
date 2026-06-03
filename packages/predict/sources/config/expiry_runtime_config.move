// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Mutable per-expiry runtime controls owned by ProtocolConfig.
///
/// This config is not snapshotted into the expiry market. Runtime flows read the
/// current row for the expiry market they are operating on.
module deepbook_predict::expiry_runtime_config;

use deepbook_predict::config_constants;

/// Runtime controls for one expiry market.
public struct ExpiryRuntimeConfig has store {
    /// When true, new mints abort. Other expiry flows remain available.
    mint_paused: bool,
    /// Max net DUSDC the pool may have funded into this expiry.
    max_expiry_funding: u64,
}

// === Public-Package Functions ===

public(package) fun mint_paused(config: &ExpiryRuntimeConfig): bool {
    config.mint_paused
}

public(package) fun max_expiry_funding(config: &ExpiryRuntimeConfig): u64 {
    config.max_expiry_funding
}

public(package) fun new(): ExpiryRuntimeConfig {
    ExpiryRuntimeConfig {
        mint_paused: false,
        max_expiry_funding: config_constants::default_max_expiry_funding!(),
    }
}

public(package) fun set_mint_paused(config: &mut ExpiryRuntimeConfig, paused: bool) {
    config.mint_paused = paused;
}

public(package) fun set_max_expiry_funding(config: &mut ExpiryRuntimeConfig, funding: u64) {
    config_constants::assert_max_expiry_funding(funding);
    config.max_expiry_funding = funding;
}
