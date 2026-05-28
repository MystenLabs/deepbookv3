// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin-tunable DEEP staking parameters.
///
/// Holds the staking power at which trading benefits reach their maximum (50%
/// fee discount, 100% loss rebate). Benefits scale linearly with power up to
/// this value; power above it earns no extra benefit.
module deepbook_predict::stake_config;

use deepbook_predict::config_constants;

public struct StakeConfig has store {
    /// Staking power for full trading benefits, in raw DEEP units.
    max_benefit_power: u64,
}

// === Public-Package Functions ===

public(package) fun max_benefit_power(config: &StakeConfig): u64 {
    config.max_benefit_power
}

public(package) fun new(): StakeConfig {
    StakeConfig {
        max_benefit_power: config_constants::default_max_benefit_power!(),
    }
}

public(package) fun set_max_benefit_power(config: &mut StakeConfig, value: u64) {
    config_constants::assert_max_benefit_power(value);
    config.max_benefit_power = value;
}
