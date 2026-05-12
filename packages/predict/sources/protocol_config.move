// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration read by expiry markets.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    pricing::{Self, PricingConfig},
    rate_limiter::{Self, RateLimiter},
    risk_config::{Self, RiskConfig}
};
use sui::clock::Clock;

/// Shared protocol policy state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    risk_config: RiskConfig,
    withdrawal_limiter: RateLimiter,
    trading_paused: bool,
}

// === Public Functions ===

/// Return the protocol config object ID.
public fun id(config: &ProtocolConfig): ID {
    object::id(config)
}

/// Return the pricing configuration.
public fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

/// Return the risk configuration.
public fun risk_config(config: &ProtocolConfig): &RiskConfig {
    &config.risk_config
}

/// Return the withdrawal limiter configuration.
public fun withdrawal_limiter(config: &ProtocolConfig): &RateLimiter {
    &config.withdrawal_limiter
}

/// Return whether trading is currently paused.
public fun trading_paused(config: &ProtocolConfig): bool {
    config.trading_paused
}

// === Public-Package Functions ===

/// Create and share the protocol-wide configuration object.
public(package) fun create_and_share(clock: &Clock, ctx: &mut TxContext): ID {
    let config = ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing::new(),
        risk_config: risk_config::new(),
        withdrawal_limiter: rate_limiter::new(clock),
        trading_paused: false,
    };
    let id = object::id(&config);
    transfer::share_object(config);
    id
}
