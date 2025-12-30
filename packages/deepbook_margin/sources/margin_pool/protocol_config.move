// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::protocol_config;

use deepbook::{constants, math};
use deepbook_margin::margin_constants;
use std::string::String;
use sui::vec_map::{Self, VecMap};

const EInvalidRiskParam: u64 = 1;

public struct ProtocolConfig has copy, drop, store {
    margin_pool_config: MarginPoolConfig,
    interest_config: InterestConfig,
    extra_fields: VecMap<String, u64>,
}

public struct MarginPoolConfig has copy, drop, store {
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    min_borrow: u64,
    rate_limit_capacity: u64,
    rate_limit_refill_rate_per_ms: u64,
    rate_limit_enabled: bool,
}

public struct InterestConfig has copy, drop, store {
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
}

public fun new_protocol_config(
    margin_pool_config: MarginPoolConfig,
    interest_config: InterestConfig,
): ProtocolConfig {
    // Validate cross-config constraints
    assert!(
        margin_pool_config.max_utilization_rate >= interest_config.optimal_utilization,
        EInvalidRiskParam,
    );

    ProtocolConfig {
        margin_pool_config,
        interest_config,
        extra_fields: vec_map::empty(),
    }
}

public fun new_margin_pool_config(
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    min_borrow: u64,
): MarginPoolConfig {
    // Validate margin pool config parameters
    assert!(max_utilization_rate <= constants::float_scaling(), EInvalidRiskParam);
    assert!(min_borrow >= margin_constants::min_min_borrow(), EInvalidRiskParam);
    assert!(protocol_spread <= margin_constants::max_protocol_spread(), EInvalidRiskParam);

    let default_capacity = supply_cap / 10; // 10% of supply cap
    let default_window_ms = margin_constants::day_ms();
    let default_refill_rate = default_capacity / default_window_ms;

    MarginPoolConfig {
        supply_cap,
        max_utilization_rate,
        protocol_spread,
        min_borrow,
        rate_limit_capacity: default_capacity,
        rate_limit_refill_rate_per_ms: default_refill_rate,
        rate_limit_enabled: false,
    }
}

public fun new_margin_pool_config_with_rate_limit(
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
    min_borrow: u64,
    rate_limit_capacity: u64,
    rate_limit_refill_rate_per_ms: u64,
    rate_limit_enabled: bool,
): MarginPoolConfig {
    MarginPoolConfig {
        supply_cap,
        max_utilization_rate,
        protocol_spread,
        min_borrow,
        rate_limit_capacity,
        rate_limit_refill_rate_per_ms,
        rate_limit_enabled,
    }
}

public fun new_interest_config(
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): InterestConfig {
    // Validate interest config parameters
    assert!(optimal_utilization <= constants::float_scaling(), EInvalidRiskParam);

    InterestConfig {
        base_rate,
        base_slope,
        optimal_utilization,
        excess_slope,
    }
}

public(package) fun set_interest_config(self: &mut ProtocolConfig, config: InterestConfig) {
    assert!(
        self.margin_pool_config.max_utilization_rate >= config.optimal_utilization,
        EInvalidRiskParam,
    );
    self.interest_config = config;
}

public(package) fun set_margin_pool_config(self: &mut ProtocolConfig, config: MarginPoolConfig) {
    assert!(
        config.max_utilization_rate >= self.interest_config.optimal_utilization,
        EInvalidRiskParam,
    );
    self.margin_pool_config = config;
}

/// Calculate interest directly with borrow amount to avoid precision loss
public(package) fun calculate_interest_with_borrow(
    self: &ProtocolConfig,
    utilization_rate: u64,
    time_elapsed: u64,
    total_borrow: u64,
): u64 {
    let interest_rate = self.interest_rate(utilization_rate);

    math::mul(
        math::mul(total_borrow, interest_rate),
        math::div(time_elapsed, margin_constants::year_ms()),
    )
}

public(package) fun interest_rate(self: &ProtocolConfig, utilization_rate: u64): u64 {
    let base_rate = self.interest_config.base_rate;
    let base_slope = self.interest_config.base_slope;
    let optimal_utilization = self.interest_config.optimal_utilization;
    let excess_slope = self.interest_config.excess_slope;

    if (utilization_rate < optimal_utilization) {
        // Use base slope
        math::mul(utilization_rate, base_slope) + base_rate
    } else {
        // Use base slope and excess slope
        let excess_utilization = utilization_rate - optimal_utilization;
        let excess_rate = math::mul(excess_utilization, excess_slope);

        base_rate + math::mul(optimal_utilization, base_slope) + excess_rate
    }
}

public(package) fun supply_cap(self: &ProtocolConfig): u64 {
    self.margin_pool_config.supply_cap
}

public(package) fun max_utilization_rate(self: &ProtocolConfig): u64 {
    self.margin_pool_config.max_utilization_rate
}

public(package) fun protocol_spread(self: &ProtocolConfig): u64 {
    self.margin_pool_config.protocol_spread
}

public(package) fun min_borrow(self: &ProtocolConfig): u64 {
    self.margin_pool_config.min_borrow
}

public(package) fun base_rate(self: &ProtocolConfig): u64 {
    self.interest_config.base_rate
}

public(package) fun base_slope(self: &ProtocolConfig): u64 {
    self.interest_config.base_slope
}

public(package) fun optimal_utilization(self: &ProtocolConfig): u64 {
    self.interest_config.optimal_utilization
}

public(package) fun excess_slope(self: &ProtocolConfig): u64 {
    self.interest_config.excess_slope
}

public(package) fun rate_limit_capacity(self: &ProtocolConfig): u64 {
    self.margin_pool_config.rate_limit_capacity
}

public(package) fun rate_limit_refill_rate_per_ms(self: &ProtocolConfig): u64 {
    self.margin_pool_config.rate_limit_refill_rate_per_ms
}

public(package) fun rate_limit_enabled(self: &ProtocolConfig): bool {
    self.margin_pool_config.rate_limit_enabled
}

public(package) fun rate_limit_capacity_from_config(config: &MarginPoolConfig): u64 {
    config.rate_limit_capacity
}

public(package) fun rate_limit_refill_rate_per_ms_from_config(config: &MarginPoolConfig): u64 {
    config.rate_limit_refill_rate_per_ms
}

public(package) fun rate_limit_enabled_from_config(config: &MarginPoolConfig): bool {
    config.rate_limit_enabled
}
