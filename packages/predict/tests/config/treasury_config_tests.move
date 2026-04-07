// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::treasury_config_tests;

use deepbook_predict::treasury_config;
use std::unit_test::destroy;
use sui::sui::SUI;

public struct ALTUSD has drop {}

#[test]
fun new_config_starts_empty() {
    let config = treasury_config::new();

    assert!(!treasury_config::is_quote_asset<SUI>(&config));
    assert!(!treasury_config::is_quote_asset<ALTUSD>(&config));

    destroy(config);
}

#[test]
fun add_quote_asset_marks_asset_as_supported() {
    let mut config = treasury_config::new();

    treasury_config::add_quote_asset<SUI>(&mut config);
    assert!(treasury_config::is_quote_asset<SUI>(&config));
    assert!(!treasury_config::is_quote_asset<ALTUSD>(&config));

    destroy(config);
}

#[test, expected_failure(abort_code = treasury_config::ECoinAlreadyAccepted)]
fun add_quote_asset_twice_aborts() {
    let mut config = treasury_config::new();

    treasury_config::add_quote_asset<SUI>(&mut config);
    treasury_config::add_quote_asset<SUI>(&mut config);

    abort
}

#[test]
fun remove_quote_asset_updates_membership() {
    let mut config = treasury_config::new();

    treasury_config::add_quote_asset<SUI>(&mut config);
    treasury_config::add_quote_asset<ALTUSD>(&mut config);
    treasury_config::remove_quote_asset<SUI>(&mut config);

    assert!(!treasury_config::is_quote_asset<SUI>(&config));
    assert!(treasury_config::is_quote_asset<ALTUSD>(&config));

    destroy(config);
}

#[test, expected_failure(abort_code = treasury_config::EQuoteAssetNotAccepted)]
fun remove_missing_quote_asset_aborts() {
    let mut config = treasury_config::new();

    treasury_config::remove_quote_asset<SUI>(&mut config);

    abort
}

#[test, expected_failure(abort_code = treasury_config::EQuoteAssetNotAccepted)]
fun assert_quote_asset_rejects_unapproved_asset() {
    let config = treasury_config::new();

    treasury_config::assert_quote_asset<SUI>(&config);

    abort
}
