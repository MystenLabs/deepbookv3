// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_tests;

use deepbook_predict::registry;
use sui::test_scenario;

#[test]
fun test_registry_init() {
    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);
    
    let registry_id = registry::init_for_testing(scenario.ctx());
    scenario.next_tx(admin);
    
    assert!(registry::registry_exists_for_testing(registry_id), 0);
    
    let admin_cap = scenario.take_from_sender<registry::AdminCap>();
    registry::destroy_admin_cap_for_testing(admin_cap);
    
    scenario.end();
}
