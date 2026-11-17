// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Builds a `VolSnapshot` the way a commit builds one (`pricing::snap_v2`) from the
/// `oracle_fixture` feeds' rows re-signed at their own source times, bound to the
/// fixture's market and expiry.
#[test_only]
module deepbook_predict::vol_snapshot_test_helpers;

use deepbook_predict::{
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, Pricer, VolSnapshot},
    signed_data,
    test_constants
};

/// The snapshot of the bundled feeds' Block Scholes inputs, and the pricer built
/// from it at the fixture clock with the feed's Pyth spot (`signed_data::pricer`).
public fun load_snapshot(fx: &mut OracleFixture, oracle: &OracleBundle): (VolSnapshot, Pricer) {
    let expiry = fx.expiry();
    let vol = signed_data::stored_vol(oracle_fixture::bs(oracle), expiry).destroy_some();
    let mut market_uid = object::new(fx.scenario_mut().ctx());
    let snapshot = pricing::snap_v2(&vol, test_constants::pyth_feed_id(), &mut market_uid);
    market_uid.delete();
    let pricer = fx.load_pricer_bundle(oracle);
    (snapshot, pricer)
}
