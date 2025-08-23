module margin_trading::supply_config;

public struct SupplyConfig has store {
    supply_cap: u64,
    max_utilization_rate: u64,
}

public(package) fun new_supply_config(
    supply_cap: u64,
    max_utilization_rate: u64,
): SupplyConfig {
    SupplyConfig {
        supply_cap,
        max_utilization_rate,
    }
}