// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_cap_tests;

use deepbook_predict::registry;
use std::unit_test::destroy;

#[test]
fun admin_can_create_market_oracle_cap() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = registry::create_admin_cap_for_testing(ctx);
    let market_oracle_cap = registry::create_market_oracle_cap(&admin_cap, ctx);

    destroy(market_oracle_cap);
    destroy(admin_cap);
}
