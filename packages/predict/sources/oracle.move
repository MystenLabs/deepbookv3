// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Oracle module for the Predict protocol.
///
/// Manages external price data from Block Scholes:
/// - `Oracle<Asset>` shared object (one per underlying + expiry)
/// - `OracleCap` capability for Block Scholes to create oracles and push updates
///
/// Key responsibilities:
/// - Receive and store volatility updates (~1 update/second)
/// - Provide spot price and implied volatility for pricing calculations
/// - Staleness checks (data older than 30s is considered stale)
/// - Freeze settlement price on first update after expiry
///
/// Strikes are defined at oracle creation and must be updated in the same order.
module deepbook_predict::oracle;

use deepbook_predict::{constants, registry::AdminCap};
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};

// === Errors ===
const EInvalidOracleCap: u64 = 0;
const EOracleStale: u64 = 1;
const EStrikeNotFound: u64 = 2;
const EStrikesMismatch: u64 = 3;
const ETooManyStrikes: u64 = 4;
const EEmptyStrikes: u64 = 5;
const EOracleNotActive: u64 = 6;
const EOracleAlreadyActive: u64 = 7;
const EOracleExpired: u64 = 8;

// === Structs ===

/// Shared object storing price data for one underlying + expiry combination.
/// Created by Block Scholes using OracleCap.
public struct Oracle<phantom Asset> has key {
    id: UID,
    /// ID of the OracleCap that created this oracle
    oracle_cap_id: ID,
    /// Expiration timestamp in milliseconds
    expiry: u64,
    /// Whether the oracle is active (false on creation, true after activate(), false after expiry)
    active: bool,
    // === Live Data (updated by Block Scholes) ===
    /// Current spot price of the underlying asset
    spot_price: u64,
    /// Strike -> Implied volatility mapping (keys are fixed at creation)
    implied_vols: VecMap<u64, u64>,
    /// Risk-free rate for Black-Scholes calculation
    risk_free_rate: u64,
    /// Timestamp of last update in milliseconds
    timestamp: u64,
    // === Settlement ===
    /// Frozen on first update where timestamp > expiry
    settlement_price: Option<u64>,
}

/// Capability for Block Scholes to create oracles and push updates.
/// Created by admin, transferred to Block Scholes operator.
public struct OracleCap has key, store {
    id: UID,
}

// === Events ===

/// Emitted when a new oracle is created.
public struct OracleCreated<phantom Asset> has copy, drop {
    oracle_id: ID,
    oracle_cap_id: ID,
    expiry: u64,
    strikes: vector<u64>,
    created_at: u64,
}

/// Emitted on each oracle update.
public struct OracleUpdated<phantom Asset> has copy, drop {
    oracle_id: ID,
    spot_price: u64,
    implied_vols: VecMap<u64, u64>,
    risk_free_rate: u64,
    timestamp: u64,
    settled: bool,
}

// === Public Functions ===

/// Create a new OracleCap. Called by admin, transferred to Block Scholes.
public fun create_oracle_cap(_admin_cap: &AdminCap, ctx: &mut TxContext): OracleCap {
    OracleCap { id: object::new(ctx) }
}

/// Create a new Oracle for an underlying asset and expiry.
/// Called by Block Scholes using their OracleCap.
/// Strikes are fixed at creation.
public fun create_oracle<Asset>(
    cap: &OracleCap,
    expiry: u64,
    strikes: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let num_strikes = strikes.length();
    assert!(num_strikes > 0, EEmptyStrikes);
    assert!(num_strikes <= constants::max_strikes_quantity(), ETooManyStrikes);

    let oracle_id = object::new(ctx);
    let oracle_id_inner = oracle_id.to_inner();

    // Initialize implied_vols VecMap with zeros for each strike
    let mut implied_vols = vec_map::empty();
    strikes.do_ref!(|strike| {
        implied_vols.insert(*strike, 0);
    });

    let oracle = Oracle<Asset> {
        id: oracle_id,
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        active: false,
        spot_price: 0,
        implied_vols,
        risk_free_rate: 0,
        timestamp: 0,
        settlement_price: option::none(),
    };
    transfer::share_object(oracle);

    event::emit(OracleCreated<Asset> {
        oracle_id: oracle_id_inner,
        oracle_cap_id: cap.id.to_inner(),
        expiry,
        strikes,
        created_at: clock.timestamp_ms(),
    });
}

/// Activate the oracle. Can only be called by the OracleCap owner.
/// Must be called before the oracle can be used for pricing.
public fun activate<Asset>(oracle: &mut Oracle<Asset>, cap: &OracleCap, clock: &Clock) {
    assert!(clock.timestamp_ms() < oracle.expiry, EOracleExpired);
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
    assert!(!oracle.active, EOracleAlreadyActive);
    oracle.active = true;
}

/// Push new price and volatility data to an oracle.
/// Called by Block Scholes (~1 update/second).
/// implied_vols keys must exactly match the oracle's strikes.
/// If timestamp > expiry and settlement_price is None, freezes settlement price and deactivates.
public fun update<Asset>(
    oracle: &mut Oracle<Asset>,
    cap: &OracleCap,
    spot_price: u64,
    implied_vols: VecMap<u64, u64>,
    risk_free_rate: u64,
    clock: &Clock,
) {
    assert!(oracle.oracle_cap_id == cap.id.to_inner(), EInvalidOracleCap);
    assert_keys_match(&oracle.implied_vols, &implied_vols);

    let now = clock.timestamp_ms();
    let mut settled = false;

    // If past expiry and not yet settled, freeze settlement price and deactivate
    if (now > oracle.expiry && oracle.settlement_price.is_none()) {
        oracle.settlement_price = option::some(spot_price);
        oracle.active = false;
        settled = true;
    };

    // Update live data (even after settlement, for reference)
    oracle.spot_price = spot_price;
    oracle.implied_vols = implied_vols;
    oracle.risk_free_rate = risk_free_rate;
    oracle.timestamp = now;

    event::emit(OracleUpdated<Asset> {
        oracle_id: oracle.id.to_inner(),
        spot_price,
        implied_vols,
        risk_free_rate,
        timestamp: now,
        settled,
    });
}

// === Public View Functions ===

/// Get the oracle ID.
public fun id<Asset>(oracle: &Oracle<Asset>): ID {
    oracle.id.to_inner()
}

/// Get the current spot price.
public fun spot_price<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.spot_price
}

/// Get the expiry timestamp.
public fun expiry<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.expiry
}

/// Get the strikes for this oracle.
public fun strikes<Asset>(oracle: &Oracle<Asset>): vector<u64> {
    oracle.implied_vols.keys()
}

/// Get the number of strikes.
public fun num_strikes<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.implied_vols.length()
}

/// Get the risk-free rate.
public fun risk_free_rate<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.risk_free_rate
}

/// Get the last update timestamp.
public fun timestamp<Asset>(oracle: &Oracle<Asset>): u64 {
    oracle.timestamp
}

/// Get the settlement price (only valid after settlement).
public fun settlement_price<Asset>(oracle: &Oracle<Asset>): Option<u64> {
    oracle.settlement_price
}

/// Check if the oracle data is stale (> 30s since last update).
public fun is_stale<Asset>(oracle: &Oracle<Asset>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    let staleness_threshold = constants::default_oracle_staleness_ms();

    now > oracle.timestamp + staleness_threshold
}

/// Check if the oracle has been settled (settlement price frozen).
public fun is_settled<Asset>(oracle: &Oracle<Asset>): bool {
    oracle.settlement_price.is_some()
}

/// Check if the oracle is active.
public fun is_active<Asset>(oracle: &Oracle<Asset>): bool {
    oracle.active
}

// === Public-Package Functions ===

/// Get implied volatility for a specific strike.
/// Aborts if strike is not found in the oracle's strikes.
public(package) fun get_iv<Asset>(oracle: &Oracle<Asset>, strike: u64): u64 {
    assert!(oracle.implied_vols.contains(&strike), EStrikeNotFound);
    
    *oracle.implied_vols.get(&strike)
}

/// Check if a strike exists in this oracle.
public(package) fun has_strike<Asset>(oracle: &Oracle<Asset>, strike: u64): bool {
    oracle.implied_vols.contains(&strike)
}

/// Assert that the oracle is not stale. Aborts if stale.
public(package) fun assert_not_stale<Asset>(oracle: &Oracle<Asset>, clock: &Clock) {
    assert!(!is_stale(oracle, clock), EOracleStale);
}

/// Assert that the oracle is active. Aborts if not active.
public(package) fun assert_active<Asset>(oracle: &Oracle<Asset>) {
    assert!(oracle.active, EOracleNotActive);
}

/// Get all pricing data in one call for efficiency.
/// Returns (spot_price, implied_volatility, risk_free_rate, time_to_expiry_ms).
/// Aborts if strike is not found.
public(package) fun get_pricing_data<Asset>(
    oracle: &Oracle<Asset>,
    strike: u64,
    clock: &Clock,
): (u64, u64, u64, u64) {
    let now = clock.timestamp_ms();
    let time_to_expiry = if (oracle.expiry > now) {
        oracle.expiry - now
    } else {
        0
    };

    (oracle.spot_price, get_iv(oracle, strike), oracle.risk_free_rate, time_to_expiry)
}

// === Private Functions ===

/// Assert that two VecMaps have exactly the same keys.
fun assert_keys_match(a: &VecMap<u64, u64>, b: &VecMap<u64, u64>) {
    assert!(a.length() == b.length(), EStrikesMismatch);
    a.keys().do!(|key| {
        assert!(b.contains(&key), EStrikesMismatch);
    });
}
