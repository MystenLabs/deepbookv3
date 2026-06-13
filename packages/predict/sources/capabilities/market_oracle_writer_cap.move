// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle writer capability. Authorizes Block Scholes price and SVI writes on
/// `MarketOracle` objects that have registered this cap; the per-oracle
/// authorization set and its admin register/unregister entrypoints stay in
/// `market_oracle`.
module deepbook_predict::market_oracle_writer_cap;

use deepbook_predict::admin::AdminCap;

/// Capability authorized to write Block Scholes data.
public struct MarketOracleWriterCap has key, store {
    id: UID,
}

/// Create a new oracle writer capability.
public fun create(_admin_cap: &AdminCap, ctx: &mut TxContext): MarketOracleWriterCap {
    MarketOracleWriterCap { id: object::new(ctx) }
}

/// Return the writer cap object ID.
public fun id(cap: &MarketOracleWriterCap): ID {
    cap.id.to_inner()
}

/// Destroy a `MarketOracleWriterCap` the holder no longer needs.
public fun destroy(cap: MarketOracleWriterCap) {
    let MarketOracleWriterCap { id } = cap;
    id.delete();
}
