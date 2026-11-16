// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The signed observations keepers decode and pass to Predict's `_v2` entry
/// points, built for tests. Predict reads no Propbook object since version 6, so
/// the test Propbook feeds serve only as data stores: these helpers take the rows
/// a test seeded and re-sign them, through `bs_oracle`'s update constructors and
/// `lazer_price::new_for_testing`, at the exact timestamps the entry points
/// require, under the test oracle binding (`test_helpers::set_oracle_binding`).
/// Block Scholes values go through `block_scholes`' real decode.
#[test_only]
module deepbook_predict::signed_data;

use bs_oracle::verify;
use deepbook_predict::{block_scholes_feed::BlockScholesFeed, test_constants, test_helpers};
use deepbook_predict_math::{block_scholes::{Self, BsSpot, BsVol}, lazer_price::{Self, LazerPrice}};
use propbook::{block_scholes_store::BlockScholesValueStore, pyth_feed::PythFeed};

const US_PER_MS: u64 = 1_000;

/// The binding's Lazer price at `spot`, with its envelope and generation time
/// both at `envelope_ms`.
public fun lazer_at(envelope_ms: u64, spot: u64): LazerPrice {
    lazer_price::new_for_testing(
        test_constants::pyth_feed_id(),
        test_helpers::binding_channel(),
        envelope_ms * US_PER_MS,
        envelope_ms * US_PER_MS,
        spot,
    )
}

/// The Pyth row the feed holds at exactly `source_ms`, as the binding's Lazer
/// price stamped there, or `none` when it holds none.
public fun exact_pyth(pyth: &PythFeed, source_ms: u64): Option<LazerPrice> {
    pyth.normalized_spot_at(source_ms).map!(|read| lazer_at(source_ms, read.read_value()))
}

/// The feed's latest Pyth spot as the binding's Lazer price stamped `envelope_ms`,
/// or `none` when it holds none.
public fun latest_pyth_at(pyth: &PythFeed, envelope_ms: u64): Option<LazerPrice> {
    pyth.normalized_spot().map!(|read| lazer_at(envelope_ms, read.read_value()))
}

/// The Block Scholes spot the store holds at exactly `source_ms`, decoded as a
/// keeper decodes it, or `none`.
public fun exact_bs_spot(values: &BlockScholesValueStore, source_ms: u64): Option<BsSpot> {
    let read = values.spot_at(source_ms);
    if (read.is_none()) return option::none();
    let updates = vector[
        verify::new_value_update_for_testing(
            values.spot_sid(),
            source_ms,
            read.destroy_some().read_value(),
        ),
    ];
    block_scholes::spot_at(&updates, test_constants::block_scholes_base_asset(), source_ms)
}

/// The feed's latest spot, forward for `expiry`, and SVI, re-signed with spot and
/// forward at `value_ms` and SVI at `svi_ms`, and decoded under the binding's base
/// asset and model at the SVI store's decimals. `none` when the feed lacks one of
/// them or a value does not decode.
public fun latest_vol_at(
    bs: &BlockScholesFeed,
    expiry: u64,
    value_ms: u64,
    svi_ms: u64,
): Option<BsVol> {
    let latest = bs.values().spot();
    if (latest.is_none()) return option::none();
    latest_vol_with(bs, expiry, value_ms, svi_ms, latest.destroy_some().read_source_timestamp_ms())
}

/// `latest_vol_at` with the spot the store recorded at `spot_source_ms`.
fun latest_vol_with(
    bs: &BlockScholesFeed,
    expiry: u64,
    value_ms: u64,
    svi_ms: u64,
    spot_source_ms: u64,
): Option<BsVol> {
    let spot = bs.values().recent_spot_at(spot_source_ms);
    let forward = bs.values().forward(expiry);
    let svi = bs.svi().svi(expiry);
    if (spot.is_none() || forward.is_none() || svi.is_none()) return option::none();
    let base = test_constants::block_scholes_base_asset();
    let model = test_helpers::binding_svi_model();
    let decimals = bs.svi().svi_decimals();
    let values = vector[
        verify::new_value_update_for_testing(
            block_scholes::spot_sid(&base),
            value_ms,
            spot.destroy_some().read_value(),
        ),
        verify::new_value_update_for_testing(
            block_scholes::forward_sid(&base, expiry),
            value_ms,
            forward.destroy_some().read_value(),
        ),
    ];
    let params = svi.destroy_some().read_value();
    let svis = vector[
        verify::new_svi_for_testing(
            block_scholes::svi_sid(&base, &model, decimals, expiry),
            svi_ms,
            params.svi_a_magnitude(),
            params.svi_a_is_negative(),
            params.svi_b(),
            params.svi_sigma(),
            params.svi_rho_magnitude(),
            params.svi_rho_is_negative(),
            params.svi_m_magnitude(),
            params.svi_m_is_negative(),
        ),
    ];
    block_scholes::vol_at(&values, &svis, base, model, decimals, expiry, value_ms, svi_ms)
}

/// The feed's latest forward for `expiry`, the spot stamped at the forward's own
/// source time, and the latest SVI, re-signed at their own source times: the inputs
/// a version 5 admission snapshotted, as a `BsVol`. `none` when one is missing.
public fun stored_vol(bs: &BlockScholesFeed, expiry: u64): Option<BsVol> {
    let forward = bs.values().forward(expiry);
    let svi = bs.svi().svi(expiry);
    if (forward.is_none() || svi.is_none()) return option::none();
    let value_ms = forward.borrow().read_source_timestamp_ms();
    if (bs.values().recent_spot_at(value_ms).is_none()) return option::none();
    let svi_ms = svi.borrow().read_source_timestamp_ms();
    latest_vol_with(bs, expiry, value_ms, svi_ms, value_ms)
}
