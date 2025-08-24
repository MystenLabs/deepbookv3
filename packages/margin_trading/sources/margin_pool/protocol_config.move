module margin_trading::protocol_config;

public struct ProtocolConfig has drop, store {
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
}

public fun default(
    supply_cap: u64,
    max_utilization_rate: u64,
    protocol_spread: u64,
): ProtocolConfig {
    ProtocolConfig {
        supply_cap,
        max_utilization_rate,
        protocol_spread,
    }
}

public(package) fun supply_cap(self: &ProtocolConfig): u64 {
    self.supply_cap
}

public(package) fun max_utilization_rate(self: &ProtocolConfig): u64 {
    self.max_utilization_rate
}

public(package) fun protocol_spread(self: &ProtocolConfig): u64 {
    self.protocol_spread
}
