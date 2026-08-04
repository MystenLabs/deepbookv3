// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins Propbook's chosen Block Scholes descriptors against explicit calls to the provider-owned
/// SID package. The upstream package's own vectors pin BCS and hashing; these tests pin the asset,
/// exchange, model, scale, timestamp precision, expiry shape, and oracle-package domain Propbook
/// passes into that implementation.
#[test_only]
module propbook::block_scholes_sid_tests;

use bs_oracle::verify::PackageMarker;
use bs_sid::sid;
use propbook::block_scholes_sid;
use std::{string::String, type_name, unit_test::assert_eq};

const EXPIRY_MS: u64 = 1_785_888_000_000;
/// Block Scholes signs every Propbook scalar and SVI value at nine decimal places.
const DECIMALS: u8 = 9;
const ORACLE_VECTOR_SCOPE: address =
    @0x1111111111111111111111111111111111111111111111111111111111111111;
const SPOT_HYPE_OFFICIAL: u256 = 0x215ab77d29adef1066cb6a229a7e74e083bee79b5aff973a36d2ba2aa8f560f3;

#[test]
fun spot_matches_the_official_pinned_id() {
    assert_eq!(
        sid::index_px(
            ORACLE_VECTOR_SCOPE,
            b"spot".to_string(),
            b"HYPE".to_string(),
            option::none(),
            DECIMALS,
            b"ms".to_string(),
        ),
        SPOT_HYPE_OFFICIAL,
    );
}

#[test]
fun spot_matches_the_official_descriptor() {
    let base_asset = btc();
    let expected = sid::index_px(
        oracle_package_id(),
        b"spot".to_string(),
        copy base_asset,
        option::none(),
        DECIMALS,
        b"ms".to_string(),
    );
    assert_eq!(block_scholes_sid::spot(&base_asset), expected);
}

#[test]
fun forward_matches_the_official_descriptor() {
    let base_asset = btc();
    let expected = sid::mark_px(
        oracle_package_id(),
        b"future".to_string(),
        b"composite".to_string(),
        copy base_asset,
        option::some(sid::expiry_at(EXPIRY_MS)),
        DECIMALS,
        b"ms".to_string(),
    );
    assert_eq!(block_scholes_sid::forward(&base_asset, EXPIRY_MS), expected);
}

#[test]
fun svi_matches_the_official_descriptor() {
    let base_asset = btc();
    let expected = sid::model_params(
        oracle_package_id(),
        b"option".to_string(),
        copy base_asset,
        b"SVI".to_string(),
        sid::expiry_at(EXPIRY_MS),
        DECIMALS,
        b"ms".to_string(),
    );
    assert_eq!(block_scholes_sid::svi(&base_asset, EXPIRY_MS), expected);
}

#[test]
fun base_asset_and_expiry_are_part_of_the_identity() {
    let btc = btc();
    let eth = b"ETH".to_string();
    assert!(block_scholes_sid::spot(&btc) != block_scholes_sid::spot(&eth));
    assert!(
        block_scholes_sid::forward(&btc, EXPIRY_MS) !=
        block_scholes_sid::forward(&btc, EXPIRY_MS + 1),
    );
}

#[test]
fun series_shapes_are_distinct() {
    let base_asset = btc();
    let spot = block_scholes_sid::spot(&base_asset);
    let forward = block_scholes_sid::forward(&base_asset, EXPIRY_MS);
    let svi = block_scholes_sid::svi(&base_asset, EXPIRY_MS);
    assert!(spot != forward);
    assert!(spot != svi);
    assert!(forward != svi);
}

fun oracle_package_id(): address {
    type_name::original_id<PackageMarker>()
}

fun btc(): String {
    b"BTC".to_string()
}
