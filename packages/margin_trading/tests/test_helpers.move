// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module margin_trading::test_helpers;

use margin_trading::{
    margin_pool,
    margin_registry::{Self, MarginRegistry, MarginAdminCap, MaintainerCap},
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    test_scenario::{Scenario, begin, return_shared}
};

public fun setup_test(): (Scenario, MarginAdminCap) {
    let mut test = begin(test_constants::admin());
    let clock = clock::create_for_testing(test.ctx());

    let admin_cap = margin_registry::new_for_testing(test.ctx());

    clock.share_for_testing();

    (test, admin_cap)
}

public fun create_margin_pool<Asset>(
    test: &mut Scenario,
    maintainer_cap: &MaintainerCap,
    protocol_config: ProtocolConfig,
    clock: &Clock,
): ID {
    test.next_tx(test_constants::admin());

    let mut registry = test.take_shared<MarginRegistry>();

    let pool_id = margin_pool::create_margin_pool<Asset>(
        &mut registry,
        protocol_config,
        maintainer_cap,
        clock,
        test.ctx(),
    );
    return_shared(registry);

    pool_id
}

public fun default_protocol_config(): ProtocolConfig {
    let margin_pool_config = protocol_config::new_margin_pool_config(
        test_constants::supply_cap(),
        test_constants::max_utilization_rate(),
        test_constants::protocol_spread(),
    );
    let interest_config = protocol_config::new_interest_config(
        test_constants::base_rate(), // base_rate: 5% with 9 decimals
        test_constants::base_slope(), // base_slope: 10% with 9 decimals
        test_constants::optimal_utilization(), // optimal_utilization: 80% with 9 decimals
        test_constants::excess_slope(), // excess_slope: 200% with 9 decimals
    );

    protocol_config::new_protocol_config(margin_pool_config, interest_config)
}

public fun mint_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint_for_testing<T>(amount, ctx)
}
