// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Block Scholes inputs decoded from verified `bs_oracle` updates, for Predict's
/// commit, flush, and settlement fallback.
///
/// A `ValueUpdate` or `SviUpdate` comes only from `bs_oracle::verify`, which checks
/// Block Scholes' signature over the whole batch, and a caller gets them from the
/// verified batch with `into_value_updates` and `into_svi_updates`. A `BsVol` and a
/// `BsSpot` are built only here, from those updates, so holding one proves the
/// signed values behind it. Like `LazerPrice`, both have `copy` and `drop` but not
/// `store`, so they live within one transaction. Each records the base asset, SVI
/// model, SVI decimals, and expiry it was decoded for, and the consumer checks
/// those against its own oracle binding.
///
/// Every value is matched by its series id and its own source timestamp, not the
/// batch's. The series ids are the ones Propbook's stores accepted: spot and
/// forward at 1e9, and SVI under the given model at the given decimals, all with
/// millisecond timestamps.
module deepbook_predict_math::block_scholes;

use bs_oracle::verify::{PackageMarker, SviUpdate, ValueUpdate};
use bs_sid::sid;
use fixed_math::i64::{Self, I64};
use std::{string::String, type_name};

/// One market's Block Scholes inputs: a spot and forward stamped at one source
/// time, and an SVI tuple stamped at another.
public struct BsVol has copy, drop {
    base_asset: String,
    svi_model: String,
    /// The decimals the SVI tuple was signed at: `9` or `18`.
    svi_decimals: u8,
    expiry_ms: u64,
    /// Source time of `spot` and `forward`, in ms.
    value_ms: u64,
    /// Spot and forward(expiry), at 1e9.
    spot: u64,
    forward: u64,
    /// Source time of the SVI tuple, in ms.
    svi_ms: u64,
    /// SVI `a` magnitude and `b` at 1e18, exactly as signed.
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    /// SVI `rho`, `m`, and `sigma` at 1e9, rounded half up from 18 decimals.
    rho: I64,
    m: I64,
    sigma: u64,
}

/// A Block Scholes spot at one source time, for settlement.
public struct BsSpot has copy, drop {
    base_asset: String,
    /// Source time, in ms.
    source_ms: u64,
    /// At 1e9.
    spot: u64,
}

macro fun value_decimals(): u8 { 9 }

macro fun precise_decimals(): u8 { 18 }

macro fun spot_asset_class(): String { b"spot".to_string() }

macro fun forward_asset_class(): String { b"future".to_string() }

macro fun forward_exchange(): String { b"composite".to_string() }

macro fun svi_asset_class(): String { b"option".to_string() }

macro fun timestamp_precision(): String { b"ms".to_string() }

// === Public Functions ===

/// Every `BsVol` the updates hold for each of `expiries_ms`: one for each pair of
/// a spot and a forward stamped at the same source time and an SVI tuple, under
/// `base_asset` and, for SVI, `svi_model` at `svi_decimals`. Updates for other
/// series are ignored, so one batch can serve several markets. A combination is
/// left out when a spot or forward is zero or wider than `u64`, or an SVI
/// parameter does not fit Predict's widths, and every combination is left out
/// when `svi_decimals` is neither `9` nor `18`. Nothing here checks Predict's
/// pricing envelope or the source times: the consumer does.
public fun vols(
    values: &vector<ValueUpdate>,
    svis: &vector<SviUpdate>,
    base_asset: String,
    svi_model: String,
    svi_decimals: u8,
    expiries_ms: vector<u64>,
): vector<BsVol> {
    let mut found = vector[];
    if (svi_decimals != value_decimals!() && svi_decimals != precise_decimals!()) return found;
    let spot_id = spot_sid(&base_asset);
    expiries_ms.do!(|expiry_ms| {
        let forward_id = forward_sid(&base_asset, expiry_ms);
        let svi_id = svi_sid(&base_asset, &svi_model, svi_decimals, expiry_ms);
        values.do_ref!(|spot| {
            if (spot.value_sid() == spot_id) {
                values.do_ref!(|forward| {
                    if (
                        forward.value_sid() == forward_id
                            && forward.value_timestamp() == spot.value_timestamp()
                    ) {
                        svis.do_ref!(|svi| {
                            if (svi.svi_sid() == svi_id) {
                                let vol = new_vol(
                                    spot,
                                    forward,
                                    svi,
                                    base_asset,
                                    svi_model,
                                    svi_decimals,
                                    expiry_ms,
                                );
                                vol.do!(|vol| found.push_back(vol));
                            };
                        });
                    };
                });
            };
        });
    });
    found
}

/// The `BsVol` for `expiry_ms` whose spot and forward are stamped `value_ms` and
/// whose SVI is stamped `svi_ms`, or `none`. The first match `vols` finds.
public fun vol_at(
    values: &vector<ValueUpdate>,
    svis: &vector<SviUpdate>,
    base_asset: String,
    svi_model: String,
    svi_decimals: u8,
    expiry_ms: u64,
    value_ms: u64,
    svi_ms: u64,
): Option<BsVol> {
    let found = vols(values, svis, base_asset, svi_model, svi_decimals, vector[expiry_ms]);
    let index = found.find_index!(|vol| vol.value_ms == value_ms && vol.svi_ms == svi_ms);
    index.map!(|index| found[index])
}

/// The spot of `base_asset` stamped `source_ms`, or `none` when the updates hold
/// none, or it is zero or wider than `u64`. The first match.
public fun spot_at(
    values: &vector<ValueUpdate>,
    base_asset: String,
    source_ms: u64,
): Option<BsSpot> {
    let spot_id = spot_sid(&base_asset);
    let index = values.find_index!(|update| {
        update.value_sid() == spot_id && update.value_timestamp() == source_ms
    });
    if (index.is_none()) return option::none();
    price(values[index.destroy_some()].value_v()).map!(
        |spot| BsSpot { base_asset, source_ms, spot },
    )
}

/// The series id of `base_asset`'s spot at 1e9. For PTB construction and keepers
/// that pick a batch's updates.
public fun spot_sid(base_asset: &String): u256 {
    sid::index_px(
        oracle_package_id(),
        spot_asset_class!(),
        *base_asset,
        option::none(),
        value_decimals!(),
        timestamp_precision!(),
    )
}

/// The series id of `base_asset`'s composite forward for `expiry_ms`, at 1e9.
public fun forward_sid(base_asset: &String, expiry_ms: u64): u256 {
    sid::mark_px(
        oracle_package_id(),
        forward_asset_class!(),
        forward_exchange!(),
        *base_asset,
        option::some(sid::expiry_at(expiry_ms)),
        value_decimals!(),
        timestamp_precision!(),
    )
}

/// The series id of `base_asset`'s SVI tuple for `expiry_ms` under `svi_model`.
/// The id hashes one decimals value for all five parameters.
public fun svi_sid(
    base_asset: &String,
    svi_model: &String,
    svi_decimals: u8,
    expiry_ms: u64,
): u256 {
    sid::model_params(
        oracle_package_id(),
        svi_asset_class!(),
        *base_asset,
        *svi_model,
        sid::expiry_at(expiry_ms),
        svi_decimals,
        timestamp_precision!(),
    )
}

// === BsVol Getters ===

public fun base_asset(vol: &BsVol): String { vol.base_asset }

public fun svi_model(vol: &BsVol): String { vol.svi_model }

public fun svi_decimals(vol: &BsVol): u8 { vol.svi_decimals }

public fun expiry_ms(vol: &BsVol): u64 { vol.expiry_ms }

public fun value_ms(vol: &BsVol): u64 { vol.value_ms }

public fun spot(vol: &BsVol): u64 { vol.spot }

public fun forward(vol: &BsVol): u64 { vol.forward }

public fun svi_ms(vol: &BsVol): u64 { vol.svi_ms }

public fun a_magnitude(vol: &BsVol): u128 { vol.a_magnitude }

public fun a_is_negative(vol: &BsVol): bool { vol.a_is_negative }

public fun b(vol: &BsVol): u128 { vol.b }

public fun rho(vol: &BsVol): I64 { vol.rho }

public fun m(vol: &BsVol): I64 { vol.m }

public fun sigma(vol: &BsVol): u64 { vol.sigma }

// === BsSpot Getters ===

public fun spot_base_asset(spot: &BsSpot): String { spot.base_asset }

public fun source_ms(spot: &BsSpot): u64 { spot.source_ms }

public fun spot_price(spot: &BsSpot): u64 { spot.spot }

// === Private Functions ===

/// One combination's `BsVol`, or `none` when a value does not fit.
fun new_vol(
    spot: &ValueUpdate,
    forward: &ValueUpdate,
    svi: &SviUpdate,
    base_asset: String,
    svi_model: String,
    svi_decimals: u8,
    expiry_ms: u64,
): Option<BsVol> {
    let spot_value = price(spot.value_v());
    let forward_value = price(forward.value_v());
    let (a, a_is_negative, b, sigma, rho, rho_is_negative, m, m_is_negative) = svi.svi_fields();
    let rho = narrow(rho, svi_decimals);
    let m = narrow(m, svi_decimals);
    let sigma = narrow(sigma, svi_decimals);
    if (
        spot_value.is_none() || forward_value.is_none() || rho.is_none() || m.is_none()
            || sigma.is_none()
            // `a` and `b` stay at 1e18 for pricing, and Predict also keeps them at 1e9.
            || narrow(a, svi_decimals).is_none() || narrow(b, svi_decimals).is_none()
    ) return option::none();
    let scale = if (svi_decimals == value_decimals!()) 1_000_000_000 else 1;
    option::some(BsVol {
        base_asset,
        svi_model,
        svi_decimals,
        expiry_ms,
        value_ms: spot.value_timestamp(),
        spot: spot_value.destroy_some(),
        forward: forward_value.destroy_some(),
        svi_ms: svi.svi_timestamp(),
        a_magnitude: a * scale,
        a_is_negative,
        b: b * scale,
        rho: i64::from_parts(rho.destroy_some(), rho_is_negative),
        m: i64::from_parts(m.destroy_some(), m_is_negative),
        sigma: sigma.destroy_some(),
    })
}

/// A spot or forward at 1e9, or `none` when it is zero or wider than `u64`.
fun price(value: u128): Option<u64> {
    if (value == 0) option::none() else narrow(value, value_decimals!())
}

/// A signed value at 1e9: as signed at 9 decimals, or rounded half up from 18,
/// the rounding Predict applied to an 18-decimal Propbook row. `none` when it is
/// wider than `u64`.
fun narrow(value: u128, decimals: u8): Option<u64> {
    let scale = if (decimals == precise_decimals!()) 1_000_000_000 else 1;
    let rounded = value / scale + if (value % scale > (scale - 1) / 2) 1 else 0;
    if (rounded > (std::u64::max_value!() as u128)) option::none() else option::some(rounded as u64)
}

fun oracle_package_id(): address {
    type_name::original_id<PackageMarker>()
}

// === Test-Only Functions ===

#[test_only]
public fun new_vol_for_testing(
    base_asset: String,
    svi_model: String,
    svi_decimals: u8,
    expiry_ms: u64,
    value_ms: u64,
    spot: u64,
    forward: u64,
    svi_ms: u64,
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
): BsVol {
    BsVol {
        base_asset,
        svi_model,
        svi_decimals,
        expiry_ms,
        value_ms,
        spot,
        forward,
        svi_ms,
        a_magnitude,
        a_is_negative,
        b,
        rho,
        m,
        sigma,
    }
}

#[test_only]
public fun new_spot_for_testing(base_asset: String, source_ms: u64, spot: u64): BsSpot {
    BsSpot { base_asset, source_ms, spot }
}
