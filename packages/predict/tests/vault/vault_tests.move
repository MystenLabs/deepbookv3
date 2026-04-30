// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{constants, oracle_config, range_key, vault};
use std::unit_test::destroy;
use sui::clock;

const ORACLE_ID: address = @0x391;
const MIN_STRIKE: u64 = 0;
const MAX_STRIKE: u64 = 200_000_000_000;
const TICK_SIZE: u64 = 100_000_000_000;
const LOWER_STRIKE: u64 = 100_000_000_000;
const HIGHER_STRIKE: u64 = 200_000_000_000;
const SETTLEMENT_INSIDE_RANGE: u64 = 150_000_000_000;
const RANGE_QTY: u64 = 100;
const RANGE_MAX_PAYOUT: u64 = 100;
const EXPIRY: u64 = 1_000;

#[test]
fun compact_settled_range_preserves_total_max_payout() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let oracle_id = object::id_from_address(ORACLE_ID);
    let range_key = range_key::new(oracle_id, EXPIRY, LOWER_STRIKE, HIGHER_STRIKE);
    let curve = vector[
        oracle_config::new_curve_point(MIN_STRIKE, constants::float_scaling!()),
        oracle_config::new_curve_point(LOWER_STRIKE, constants::float_scaling!()),
        oracle_config::new_curve_point(HIGHER_STRIKE, 0),
    ];
    let mut vault = vault::new(ctx);

    vault.init_oracle_matrix(oracle_id, MIN_STRIKE, MAX_STRIKE, TICK_SIZE, &clock, ctx);
    vault.insert_live_range(range_key, RANGE_QTY, curve, &clock);

    assert!(vault.total_max_payout() == RANGE_MAX_PAYOUT);

    vault.compact_settled_oracle_if_needed(oracle_id, SETTLEMENT_INSIDE_RANGE);

    assert!(vault.total_max_payout() == RANGE_MAX_PAYOUT);

    destroy(vault);
    clock.destroy_for_testing();
}
