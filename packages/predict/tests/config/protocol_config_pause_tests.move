// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::protocol_config_pause_tests;

use deepbook_predict::protocol_config;
use std::unit_test::{assert_eq, destroy};

#[test]
fun mint_pause_cap_records_id_in_allowed_set() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap = config.mint_pause_cap(ctx);
    let cap_id = object::id(&cap);

    let allowed = config.allowed_pause_caps();
    assert_eq!(allowed.length(), 1);
    assert!(allowed.contains(&cap_id));

    destroy(cap);
    destroy(config);
}

#[test]
fun mint_two_pause_caps_both_recorded() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap_a = config.mint_pause_cap(ctx);
    let cap_b = config.mint_pause_cap(ctx);
    let id_a = object::id(&cap_a);
    let id_b = object::id(&cap_b);

    let allowed = config.allowed_pause_caps();
    assert_eq!(allowed.length(), 2);
    assert!(allowed.contains(&id_a));
    assert!(allowed.contains(&id_b));

    destroy(cap_a);
    destroy(cap_b);
    destroy(config);
}

#[test]
fun pause_trading_with_valid_cap_sets_flag() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap = config.mint_pause_cap(ctx);
    assert!(!config.trading_paused());

    config.pause_trading_with_cap(&cap);
    assert!(config.trading_paused());

    destroy(cap);
    destroy(config);
}

#[test]
fun admin_can_unpause_after_cap_triggered_pause() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap = config.mint_pause_cap(ctx);
    config.pause_trading_with_cap(&cap);
    assert!(config.trading_paused());

    config.set_trading_paused(false);
    assert!(!config.trading_paused());

    destroy(cap);
    destroy(config);
}

#[test]
fun revoke_pause_cap_removes_id_from_allowed_set() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap = config.mint_pause_cap(ctx);
    let cap_id = object::id(&cap);

    config.revoke_pause_cap(cap_id);

    let allowed = config.allowed_pause_caps();
    assert_eq!(allowed.length(), 0);
    assert!(!allowed.contains(&cap_id));

    destroy(cap);
    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EPauseCapNotValid)]
fun pause_trading_with_revoked_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let cap = config.mint_pause_cap(ctx);
    let cap_id = object::id(&cap);
    config.revoke_pause_cap(cap_id);

    config.pause_trading_with_cap(&cap);

    abort
}

#[test, expected_failure(abort_code = protocol_config::EPauseCapNotValid)]
fun revoke_pause_cap_with_unknown_id_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    let _cap = config.mint_pause_cap(ctx);
    let other_cap = config.mint_pause_cap(ctx);
    let other_id = object::id(&other_cap);
    config.revoke_pause_cap(other_id);

    config.revoke_pause_cap(other_id);

    abort
}

#[test, expected_failure(abort_code = protocol_config::EPauseCapNotValid)]
fun revoke_pause_cap_before_any_mint_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    config.revoke_pause_cap(object::id_from_address(@0xDEAD));

    abort
}
