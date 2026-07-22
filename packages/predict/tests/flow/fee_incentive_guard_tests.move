// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The sponsorship minimum: dust contributions are rejected at the entrypoint.
#[test_only]
module deepbook_predict::scope_flow__intent_guard__fee_incentive_tests;

use deepbook_predict::{plp, test_values, test_world};
use dusdc::dusdc::DUSDC;
use sui::coin;

const BELOW_MINIMUM_SPONSORSHIP: u64 = 9_999_999; // one below the 10 DUSDC minimum

#[test, expected_failure(abort_code = plp::EBelowMinFeeIncentiveSponsorship)]
fun sponsor_below_minimum_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::bob());
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let payment = coin::mint_for_testing<DUSDC>(
        BELOW_MINIMUM_SPONSORSHIP,
        test_world::ctx(&mut world),
    );
    vault.sponsor_fee_incentives(&config, payment, test_world::ctx(&mut world));

    abort 999
}
