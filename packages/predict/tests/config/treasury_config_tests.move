// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::treasury_config_tests;

use deepbook_predict::{constants, currency_helper, treasury_config};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{coin::TreasuryCap, coin_registry::{Self as coin_registry, Currency, MetadataCap}};

const BAD_DECIMALS: u8 = 9;

public struct QUOTEUSD has key { id: UID }
public struct ALTUSD has key { id: UID }
public struct BADDEC has key { id: UID }

fun new_quoteusd_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<QUOTEUSD>, TreasuryCap<QUOTEUSD>, MetadataCap<QUOTEUSD>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<QUOTEUSD>(
        decimals,
        b"QUSD".to_string(),
        b"Quote USD".to_string(),
        b"Quote USD".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

fun new_altusd_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<ALTUSD>, TreasuryCap<ALTUSD>, MetadataCap<ALTUSD>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<ALTUSD>(
        decimals,
        b"AUSD".to_string(),
        b"Alt USD".to_string(),
        b"Alt USD".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

fun new_baddec_currency(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<BADDEC>, TreasuryCap<BADDEC>, MetadataCap<BADDEC>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (builder, treasury_cap) = registry.new_currency<BADDEC>(
        decimals,
        b"BDEC".to_string(),
        b"Bad Decimals".to_string(),
        b"Bad Decimals".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = builder.finalize_unwrap_for_testing(ctx);
    destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

#[test]
fun new_config_starts_empty() {
    let config = treasury_config::new();

    assert!(!treasury_config::is_quote_asset<QUOTEUSD>(&config));
    assert!(!treasury_config::is_quote_asset<ALTUSD>(&config));

    destroy(config);
}

#[test]
fun add_quote_asset_marks_asset_as_supported() {
    let ctx = &mut tx_context::dummy();
    let mut config = treasury_config::new();
    let (currency, treasury_cap, metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );

    treasury_config::add_quote_asset<ALTUSD>(&mut config, &currency);
    assert!(treasury_config::is_quote_asset<ALTUSD>(&config));
    assert!(!treasury_config::is_quote_asset<QUOTEUSD>(&config));

    destroy(config);
    currency_helper::destroy_currency_bundle(currency, treasury_cap, metadata_cap);
}

#[test]
fun accepted_quotes_getter_returns_current_whitelist() {
    let ctx = &mut tx_context::dummy();
    let mut config = treasury_config::new();
    let (quote_currency, quote_treasury_cap, quote_metadata_cap) = new_quoteusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );
    let (alt_currency, alt_treasury_cap, alt_metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );

    treasury_config::add_quote_asset<QUOTEUSD>(&mut config, &quote_currency);
    treasury_config::add_quote_asset<ALTUSD>(&mut config, &alt_currency);

    let accepted_quotes = treasury_config::accepted_quotes(&config);
    assert_eq!(accepted_quotes.length(), 2);
    assert!(accepted_quotes.contains(&type_name::with_defining_ids<QUOTEUSD>()));
    assert!(accepted_quotes.contains(&type_name::with_defining_ids<ALTUSD>()));

    destroy(config);
    currency_helper::destroy_currency_bundle(
        quote_currency,
        quote_treasury_cap,
        quote_metadata_cap,
    );
    currency_helper::destroy_currency_bundle(alt_currency, alt_treasury_cap, alt_metadata_cap);
}

#[test, expected_failure(abort_code = treasury_config::ECoinAlreadyAccepted)]
fun add_quote_asset_twice_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = treasury_config::new();
    let (currency, treasury_cap, metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );

    treasury_config::add_quote_asset<ALTUSD>(&mut config, &currency);
    treasury_config::add_quote_asset<ALTUSD>(&mut config, &currency);

    currency_helper::destroy_currency_bundle(currency, treasury_cap, metadata_cap);

    abort 999
}

#[test]
fun remove_quote_asset_updates_membership() {
    let ctx = &mut tx_context::dummy();
    let mut config = treasury_config::new();
    let (quote_currency, quote_treasury_cap, quote_metadata_cap) = new_quoteusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );
    let (alt_currency, alt_treasury_cap, alt_metadata_cap) = new_altusd_currency(
        constants::required_quote_decimals!(),
        ctx,
    );

    treasury_config::add_quote_asset<QUOTEUSD>(&mut config, &quote_currency);
    treasury_config::add_quote_asset<ALTUSD>(&mut config, &alt_currency);
    treasury_config::remove_quote_asset<QUOTEUSD>(&mut config);

    assert!(!treasury_config::is_quote_asset<QUOTEUSD>(&config));
    assert!(treasury_config::is_quote_asset<ALTUSD>(&config));

    destroy(config);
    currency_helper::destroy_currency_bundle(
        quote_currency,
        quote_treasury_cap,
        quote_metadata_cap,
    );
    currency_helper::destroy_currency_bundle(alt_currency, alt_treasury_cap, alt_metadata_cap);
}

#[test, expected_failure(abort_code = treasury_config::EQuoteAssetNotAccepted)]
fun remove_missing_quote_asset_aborts() {
    let mut config = treasury_config::new();

    treasury_config::remove_quote_asset<QUOTEUSD>(&mut config);

    abort 999
}

#[test, expected_failure(abort_code = treasury_config::EQuoteAssetNotAccepted)]
fun assert_quote_asset_rejects_unapproved_asset() {
    let config = treasury_config::new();

    treasury_config::assert_quote_asset<QUOTEUSD>(&config);

    abort 999
}

#[test, expected_failure(abort_code = treasury_config::EInvalidQuoteDecimals)]
fun add_quote_asset_with_wrong_decimals_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = treasury_config::new();
    let (currency, treasury_cap, metadata_cap) = new_baddec_currency(BAD_DECIMALS, ctx);

    treasury_config::add_quote_asset<BADDEC>(&mut config, &currency);

    currency_helper::destroy_currency_bundle(currency, treasury_cap, metadata_cap);
    abort 999
}
