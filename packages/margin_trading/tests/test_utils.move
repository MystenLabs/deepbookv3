// // Copyright (c) Mysten Labs, Inc.
// // SPDX-License-Identifier: Apache-2.0

// #[test_only]
// module margin_trading::test_utils;

// use margin_trading::margin_pool::{Self, MarginPool};
// use margin_trading::margin_registry::{
//     Self,
//     MarginRegistry,
//     MarginAdminCap,
//     MaintainerCap,
//     MarginPoolCap
// };
// use margin_trading::protocol_config;
// use sui::clock::{Self, Clock};
// use sui::coin::{Self, Coin};
// use sui::test_scenario::{Self as test, Scenario};
// use sui::test_utils::destroy;

// const ADMIN: address = @0x1;
// const ALICE: address = @0xAAAA;
// const BOB: address = @0xBBBB;

// public fun setup_test(): (Scenario, Clock, MarginRegistry, MarginAdminCap, MaintainerCap, ID) {
//     let mut scenario = test::begin(ADMIN);
//     let clock = clock::create_for_testing(scenario.ctx());

//     let (mut registry, admin_cap) = margin_registry::new_for_testing(scenario.ctx());
//     let maintainer_cap = margin_registry::mint_maintainer_cap(
//         &mut registry,
//         &admin_cap,
//         &clock,
//         scenario.ctx(),
//     );

//     let margin_pool_config = protocol_config::new_margin_pool_config(
//         SUPPLY_CAP,
//         MAX_UTILIZATION_RATE,
//         PROTOCOL_SPREAD,
//     );
//     let interest_config = protocol_config::new_interest_config(
//         50_000_000, // base_rate: 5% with 9 decimals
//         100_000_000, // base_slope: 10% with 9 decimals
//         800_000_000, // optimal_utilization: 80% with 9 decimals
//         2_000_000_000, // excess_slope: 200% with 9 decimals
//     );
//     let protocol_config = protocol_config::new_protocol_config(margin_pool_config, interest_config);
//     let pool_id = margin_pool::create_margin_pool<USDC>(
//         &mut registry,
//         protocol_config,
//         &maintainer_cap,
//         &clock,
//         scenario.ctx(),
//     );

//     (scenario, clock, registry, admin_cap, maintainer_cap, pool_id)
// }
