// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns the canonical Block Scholes feed shapes accepted by Propbook stores.
/// The upstream `bs_sid` package owns descriptor encoding and hashing; this
/// module only fixes Propbook's chosen spot, forward, SVI, scaling, and timestamp spellings.
module propbook::block_scholes_sid;

use bs_oracle::verify::PackageMarker;
use bs_sid::sid;
use propbook::constants;
use std::{string::String, type_name};

macro fun spot_asset_class(): String { b"spot".to_string() }

macro fun forward_asset_class(): String { b"future".to_string() }

macro fun forward_exchange(): String { b"composite".to_string() }

macro fun svi_asset_class(): String { b"option".to_string() }

macro fun svi_model(): String { b"SVI".to_string() }

macro fun timestamp_precision(): String { b"ms".to_string() }

public(package) fun spot(block_scholes_base_asset: &String): u256 {
    sid::index_px(
        oracle_package_id(),
        spot_asset_class!(),
        *block_scholes_base_asset,
        option::none(),
        constants::float_scaling_decimals!() as u8,
        timestamp_precision!(),
    )
}

public(package) fun forward(block_scholes_base_asset: &String, expiry_ms: u64): u256 {
    sid::mark_px(
        oracle_package_id(),
        forward_asset_class!(),
        forward_exchange!(),
        *block_scholes_base_asset,
        option::some(sid::expiry_at(expiry_ms)),
        constants::float_scaling_decimals!() as u8,
        timestamp_precision!(),
    )
}

public(package) fun svi(block_scholes_base_asset: &String, expiry_ms: u64): u256 {
    sid::model_params(
        oracle_package_id(),
        svi_asset_class!(),
        *block_scholes_base_asset,
        svi_model!(),
        sid::expiry_at(expiry_ms),
        constants::float_scaling_decimals!() as u8,
        timestamp_precision!(),
    )
}

fun oracle_package_id(): address {
    type_name::original_id<PackageMarker>()
}
