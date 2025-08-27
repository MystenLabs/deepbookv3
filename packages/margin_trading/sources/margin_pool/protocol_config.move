module margin_trading::protocol_config;

use deepbook::{constants, math};
use margin_trading::margin_constants;

const EInvalidRiskParam: u64 = 1;
const EInvalidProtocolSpread: u64 = 2;

public struct ProtocolConfig has copy, drop, store {
    margin_pool_config: MarginPoolConfig,
    interest_config: InterestConfig,
}

public struct MarginPoolConfig has copy, drop, store {
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
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
    ProtocolConfig {
        margin_pool_config,
        interest_config,
    }
}

public fun new_margin_pool_config(
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
): MarginPoolConfig {
    MarginPoolConfig {
        supply_cap,
        max_utilization_rate,
        protocol_spread,
    }
}

public fun new_interest_config(
    base_rate: u64,
    base_slope: u64,
    optimal_utilization: u64,
    excess_slope: u64,
): InterestConfig {
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
    assert!(config.protocol_spread <= constants::float_scaling(), EInvalidProtocolSpread);
    assert!(config.max_utilization_rate <= constants::float_scaling(), EInvalidRiskParam);
    assert!(
        config.max_utilization_rate >= self.interest_config.optimal_utilization,
        EInvalidRiskParam,
    );
    self.margin_pool_config = config;
}

public(package) fun time_adjusted_rate(
    self: &ProtocolConfig,
    utilization_rate: u64,
    time_elapsed: u64,
): u64 {
    let interest_rate = self.interest_rate(utilization_rate);
    math::div(
        math::mul(time_elapsed, interest_rate),
        margin_constants::year_ms(),
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
