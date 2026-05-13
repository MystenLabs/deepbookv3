// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike matrix, fee reserve, and settlement
/// compaction marker. Pool-wide PLP accounting and capital allocation remain
/// outside this module.
module deepbook_predict::expiry_market;

use deepbook_predict::{
    fee_reserve::{Self, FeeReserve},
    market_oracle::MarketOracle,
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    range_key::{Self, RangeKey},
    strike_matrix::{Self, StrikeMatrix}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock};

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    allocated_capital: Balance<DUSDC>,
    strike_matrix: StrikeMatrix,
    fee_reserve: FeeReserve,
    compacted_settlement: Option<u64>,
}

// === Public Functions ===

/// Return the expiry market object ID.
public fun id(market: &ExpiryMarket): ID {
    object::id(market)
}

/// Return the market oracle this expiry market is paired with.
public fun market_oracle_id(market: &ExpiryMarket): ID {
    market.market_oracle_id
}

/// Return the Pyth Lazer feed id snapshotted at market creation.
public fun pyth_lazer_feed_id(market: &ExpiryMarket): u32 {
    market.pyth_lazer_feed_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return the DUSDC capital currently allocated to this expiry.
public fun allocated_capital(market: &ExpiryMarket): u64 {
    market.allocated_capital.value()
}

/// Return the expiry-local worst-case payout.
public fun max_payout(market: &ExpiryMarket): u64 {
    market.strike_matrix.max_payout()
}

/// Return allocated capital not needed for worst-case payout backing.
public fun free_capital(market: &ExpiryMarket): u64 {
    let allocated_capital = market.allocated_capital();
    let max_payout = market.max_payout();
    if (allocated_capital > max_payout) {
        allocated_capital - max_payout
    } else {
        0
    }
}

/// Return true once the dense strike matrix has been compacted after settlement.
public fun is_compacted(market: &ExpiryMarket): bool {
    market.compacted_settlement.is_some()
}

/// Construct a range key for this expiry market.
public fun range_key(market: &ExpiryMarket, lower_strike: u64, higher_strike: u64): RangeKey {
    range_key::new(market.market_oracle_id, lower_strike, higher_strike)
}

/// Mint a position interval against this expiry market.
public fun mint(
    _market: &mut ExpiryMarket,
    _config: &ProtocolConfig,
    _manager: &mut PredictManager,
    _market_oracle: &MarketOracle,
    _pyth: &PythSource,
    _key: RangeKey,
    _quantity: u64,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {}

/// Redeem a position interval against this expiry market.
public fun redeem(
    _market: &mut ExpiryMarket,
    _config: &ProtocolConfig,
    _manager: &mut PredictManager,
    _market_oracle: &MarketOracle,
    _pyth: &PythSource,
    _key: RangeKey,
    _quantity: u64,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {}

/// Redeem a settled position interval permissionlessly into the manager.
public fun redeem_permissionless(
    _market: &mut ExpiryMarket,
    _config: &ProtocolConfig,
    _manager: &mut PredictManager,
    _market_oracle: &MarketOracle,
    _key: RangeKey,
    _quantity: u64,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {}

/// Redeem a compacted settled position without passing the terminal oracle.
public fun redeem_compacted_permissionless(
    _market: &mut ExpiryMarket,
    _config: &ProtocolConfig,
    _manager: &mut PredictManager,
    _key: RangeKey,
    _quantity: u64,
    _ctx: &mut TxContext,
) {}

// === Public-Package Functions ===

/// Create and share an unfunded expiry market for one market oracle.
public(package) fun create_and_share(
    market_oracle_id: ID,
    pyth: &PythSource,
    config: &ProtocolConfig,
    expiry: u64,
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    let market = ExpiryMarket {
        id: object::new(ctx),
        market_oracle_id,
        pyth_lazer_feed_id: pyth.feed_id(),
        expiry,
        allocated_capital: balance::zero(),
        strike_matrix: strike_matrix::new(ctx, tick_size, min_strike, max_strike),
        fee_reserve: fee_reserve::new(config.fee_config()),
        compacted_settlement: option::none(),
    };
    let id = object::id(&market);
    transfer::share_object(market);
    id
}
