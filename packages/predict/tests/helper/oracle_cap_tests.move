// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::oracle_cap_tests;

use deepbook_predict::oracle;
use std::unit_test::destroy;

#[test]
fun unregister_removes_authorization() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::register_cap(&mut o, &cap);
    oracle::assert_authorized_cap(&o, &cap);

    oracle::unregister_cap(&mut o, object::id(&cap));

    destroy(o);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun unregistered_cap_fails_authorization_check() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::register_cap(&mut o, &cap);
    oracle::unregister_cap(&mut o, object::id(&cap));
    oracle::assert_authorized_cap(&o, &cap);

    abort 999
}

#[test, expected_failure(abort_code = oracle::ECapNotRegistered)]
fun unregister_unknown_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::unregister_cap(&mut o, object::id(&cap));

    abort 999
}

#[test, expected_failure(abort_code = oracle::ECapNotRegistered)]
fun double_unregister_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::register_cap(&mut o, &cap);
    oracle::unregister_cap(&mut o, object::id(&cap));
    oracle::unregister_cap(&mut o, object::id(&cap));

    abort 999
}

#[test]
fun self_unregister_removes_authorization() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::register_cap(&mut o, &cap);
    oracle::self_unregister_cap(&mut o, &cap);

    destroy(o);
    destroy(cap);
}

#[test, expected_failure(abort_code = oracle::EInvalidOracleCap)]
fun self_unregistered_cap_fails_authorization_check() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::register_cap(&mut o, &cap);
    oracle::self_unregister_cap(&mut o, &cap);
    oracle::assert_authorized_cap(&o, &cap);

    abort 999
}

#[test, expected_failure(abort_code = oracle::ECapNotRegistered)]
fun self_unregister_unknown_cap_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut o = oracle::create_unshared_oracle_for_testing(ctx);
    let cap = oracle::create_oracle_cap(ctx);

    oracle::self_unregister_cap(&mut o, &cap);

    abort 999
}

#[test]
fun destroy_oracle_cap_consumes_cap() {
    let ctx = &mut tx_context::dummy();
    let cap = oracle::create_oracle_cap(ctx);
    oracle::destroy_oracle_cap(cap);
}
