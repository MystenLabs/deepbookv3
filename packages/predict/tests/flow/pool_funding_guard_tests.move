// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Bootstrap guards: the permanent minimum-liquidity lock happens exactly once
/// and never below the floor.
#[test_only]
module deepbook_predict::scope_flow__intent_guard__pool_funding_tests;

use deepbook_predict::{plp, test_values, test_world};
use dusdc::dusdc::DUSDC;
use sui::{coin, test_scenario::return_shared};

const MIN_BOOTSTRAP: u64 = 10_000_000;

#[test, expected_failure(abort_code = plp::EAlreadyBootstrapped)]
fun lock_capital_twice_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(MIN_BOOTSTRAP, test_world::ctx(&mut world));
    vault.lock_capital(&config, &admin_cap, capital);
    return_shared(config);
    return_shared(vault);
    test_world::return_predict_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(MIN_BOOTSTRAP, test_world::ctx(&mut world));
    vault.lock_capital(&config, &admin_cap, capital);

    abort 999
}

#[test, expected_failure(abort_code = plp::EBelowMinBootstrapLiquidity)]
fun lock_capital_below_floor_aborts() {
    let (mut world, _resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let capital = coin::mint_for_testing<DUSDC>(MIN_BOOTSTRAP - 1, test_world::ctx(&mut world));
    vault.lock_capital(&config, &admin_cap, capital);

    abort 999
}
