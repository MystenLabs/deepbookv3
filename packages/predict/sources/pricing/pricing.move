// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing, fees, quotes, and valuation curves for Predict markets.
///
/// This module is the app-facing read layer for oracle data. It resolves
/// market oracle and Pyth source state on demand, computes SVI prices, applies
/// fees, and builds valuation curves. It does not mutate oracle, vault, or
/// position state.
module deepbook_predict::pricing;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    i64,
    market_oracle::{Self, MarketOracle, SVIParams},
    math as predict_math,
    pyth_source::PythSource,
    range_key::RangeKey,
    tuning_constants
};
use sui::{clock::Clock, event};

const EInvalidFee: u64 = 0;
const EInvalidAskBound: u64 = 1;
const EAskPriceOverflow: u64 = 3;
const EAskPriceOutOfBounds: u64 = 4;
const EZeroForward: u64 = 5;
const ECannotBeNegative: u64 = 6;
const EZeroVariance: u64 = 7;
const EInvalidRange: u64 = 8;
const ERangePriceUnderflow: u64 = 9;
const ESVISqrtInputOverflow: u64 = 10;
const ETotalVarianceOverflow: u64 = 11;
const EInvalidLiveFairPrice: u64 = 12;
const EFeeOverflow: u64 = 13;
const EInvalidCurveRange: u64 = 14;
const EBlockScholesPriceStale: u64 = 15;
const EBlockScholesSVIStale: u64 = 16;
const EMarketNotActive: u64 = 17;
const EOracleNotSettled: u64 = 18;
const EInvalidSettlementTimestamp: u64 = 19;
const EInvalidUtilizationMultiplier: u64 = 20;
const EInvalidFreshnessThreshold: u64 = 21;

/// Fee and ask-bound parameters used when quoting Predict markets.
/// The quoted fee is a per-unit absolute price increment, not a bps rate.
public struct PricingConfig has store {
    /// Base fee multiplier for Bernoulli scaling.
    /// Effective fee rate = base_fee * sqrt(price * (1 - price)).
    base_fee: u64,
    /// Minimum per-unit fee floor; live quotes never go below this value.
    min_fee: u64,
    /// Utilization multiplier in FLOAT_SCALING (e.g., 2_000_000_000 = 2x).
    /// Controls how aggressively fees increase as vault approaches capacity.
    utilization_multiplier: u64,
    /// Global minimum allowed all-in mint price after adding the fee.
    min_ask_price: u64,
    /// Global maximum allowed all-in mint price after adding the fee.
    max_ask_price: u64,
    /// Maximum age for Pyth spot to be used as canonical live spot.
    pyth_spot_freshness_ms: u64,
    /// Maximum age for Block Scholes spot/forward to be used in live pricing.
    block_scholes_prices_freshness_ms: u64,
    /// Maximum age for Block Scholes SVI params to be used in live pricing.
    block_scholes_svi_freshness_ms: u64,
}

/// Emitted when pricing configuration changes.
public struct PricingConfigUpdated has copy, drop, store {
    predict_id: ID,
    base_fee: u64,
    min_fee: u64,
    utilization_multiplier: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
}

/// Curve sample point with strike and one-sided UP price.
public struct CurvePoint has copy, drop, store {
    strike: u64,
    up_price: u64,
}

// === Public Functions ===

/// Return terminal settlement price, aborting if the market is unsettled.
public fun settlement_price(market: &MarketOracle): u64 {
    resolved_settlement_price(market)
}

// === Public-Package Functions ===

/// Return the base fee multiplier.
public(package) fun base_fee(config: &PricingConfig): u64 {
    config.base_fee
}

/// Return the minimum per-unit fee floor.
public(package) fun min_fee(config: &PricingConfig): u64 {
    config.min_fee
}

/// Return the utilization multiplier.
public(package) fun utilization_multiplier(config: &PricingConfig): u64 {
    config.utilization_multiplier
}

/// Return the global minimum allowed all-in mint price.
public(package) fun min_ask_price(config: &PricingConfig): u64 {
    config.min_ask_price
}

/// Return the global maximum allowed all-in mint price.
public(package) fun max_ask_price(config: &PricingConfig): u64 {
    config.max_ask_price
}

/// Return the strike stored in a curve point.
public(package) fun strike(point: &CurvePoint): u64 {
    point.strike
}

/// Return the UP price stored in a curve point.
public(package) fun up_price(point: &CurvePoint): u64 {
    point.up_price
}

/// Create pricing config seeded from protocol defaults.
public(package) fun new(): PricingConfig {
    PricingConfig {
        base_fee: constants::default_base_fee!(),
        min_fee: constants::default_min_fee!(),
        utilization_multiplier: constants::default_utilization_multiplier!(),
        min_ask_price: constants::default_min_ask_price!(),
        max_ask_price: constants::default_max_ask_price!(),
        pyth_spot_freshness_ms: tuning_constants::default_pyth_spot_freshness_ms!(),
        block_scholes_prices_freshness_ms: tuning_constants::default_block_scholes_prices_freshness_ms!(),
        block_scholes_svi_freshness_ms: tuning_constants::default_block_scholes_svi_freshness_ms!(),
    }
}

/// Set the base fee multiplier.
public(package) fun set_base_fee(config: &mut PricingConfig, predict_id: ID, fee: u64) {
    assert!(fee > 0 && fee <= constants::float_scaling!(), EInvalidFee);
    config.base_fee = fee;
    emit_config_updated(config, predict_id);
}

/// Set the minimum fee floor.
public(package) fun set_min_fee(config: &mut PricingConfig, predict_id: ID, fee: u64) {
    assert!(fee <= constants::float_scaling!(), EInvalidFee);
    config.min_fee = fee;
    emit_config_updated(config, predict_id);
}

/// Set the utilization multiplier.
public(package) fun set_utilization_multiplier(
    config: &mut PricingConfig,
    predict_id: ID,
    multiplier: u64,
) {
    assert!(multiplier <= constants::max_utilization_multiplier!(), EInvalidUtilizationMultiplier);
    config.utilization_multiplier = multiplier;
    emit_config_updated(config, predict_id);
}

/// Set the global minimum allowed mint price.
public(package) fun set_min_ask_price(config: &mut PricingConfig, predict_id: ID, value: u64) {
    assert!(value < config.max_ask_price, EInvalidAskBound);
    config.min_ask_price = value;
    emit_config_updated(config, predict_id);
}

/// Set the global maximum allowed mint price.
public(package) fun set_max_ask_price(config: &mut PricingConfig, predict_id: ID, value: u64) {
    assert!(value > config.min_ask_price, EInvalidAskBound);
    assert!(value < constants::float_scaling!(), EInvalidAskBound);
    config.max_ask_price = value;
    emit_config_updated(config, predict_id);
}

/// Set the live Pyth spot freshness threshold.
public(package) fun set_pyth_spot_freshness_ms(
    config: &mut PricingConfig,
    predict_id: ID,
    value: u64,
) {
    validate_freshness_ms(value);
    config.pyth_spot_freshness_ms = value;
    emit_config_updated(config, predict_id);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public(package) fun set_block_scholes_prices_freshness_ms(
    config: &mut PricingConfig,
    predict_id: ID,
    value: u64,
) {
    validate_freshness_ms(value);
    config.block_scholes_prices_freshness_ms = value;
    emit_config_updated(config, predict_id);
}

/// Set the live Block Scholes SVI freshness threshold.
public(package) fun set_block_scholes_svi_freshness_ms(
    config: &mut PricingConfig,
    predict_id: ID,
    value: u64,
) {
    validate_freshness_ms(value);
    config.block_scholes_svi_freshness_ms = value;
    emit_config_updated(config, predict_id);
}

/// Build an adaptive piecewise-linear UP-price curve over a configured grid range.
public(package) fun build_live_curve(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    min_strike: u64,
    max_strike: u64,
): vector<CurvePoint> {
    let (forward, svi) = resolve_live_inputs(config, market, pyth, clock);
    build_curve(forward, &svi, grid_min, grid_tick, grid_max, min_strike, max_strike)
}

/// Quote a range from current oracle state and vault utilization.
public(package) fun quote_range(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    key: &RangeKey,
    liability: u64,
    balance: u64,
): (u64, u64) {
    if (market.is_settled()) {
        let fair_price = compute_settled_range_price(
            resolved_settlement_price(market),
            key.lower_strike(),
            key.higher_strike(),
        );
        (fair_price, 0)
    } else {
        quote_live_range(config, market, pyth, clock, key, liability, balance)
    }
}

/// Quote a live range from current oracle state and vault utilization.
public(package) fun quote_live_range(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    key: &RangeKey,
    liability: u64,
    balance: u64,
): (u64, u64) {
    let (forward, svi) = resolve_live_inputs(config, market, pyth, clock);
    let fair_price = compute_range_price(
        forward,
        &svi,
        key.lower_strike(),
        key.higher_strike(),
    );
    (fair_price, quote_fee_rate(config, fair_price, liability, balance))
}

/// Quote a live mint range and abort unless the all-in mint price is allowed.
public(package) fun quote_mint_live_range(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    key: &RangeKey,
    liability: u64,
    balance: u64,
): (u64, u64) {
    let (fair_price, fee_rate) = quote_live_range(
        config,
        market,
        pyth,
        clock,
        key,
        liability,
        balance,
    );
    assert_mint_quote_allowed(config, fair_price, fee_rate);
    (fair_price, fee_rate)
}

/// Return settled payout for a range position at a terminal settlement price.
public(package) fun settled_range_payout(settlement: u64, key: &RangeKey, quantity: u64): u64 {
    math::mul(
        compute_settled_range_price(settlement, key.lower_strike(), key.higher_strike()),
        quantity,
    )
}

/// Abort unless the all-in mint price is inside the global ask bounds.
fun assert_mint_quote_allowed(config: &PricingConfig, fair_price: u64, fee_rate: u64) {
    assert!(fair_price <= max_u64() - fee_rate, EAskPriceOverflow);
    let ask_price = fair_price + fee_rate;
    assert!(
        ask_price >= config.min_ask_price && ask_price <= config.max_ask_price,
        EAskPriceOutOfBounds,
    );
}

// === Private Functions ===

fun emit_config_updated(config: &PricingConfig, predict_id: ID) {
    event::emit(PricingConfigUpdated {
        predict_id,
        base_fee: config.base_fee,
        min_fee: config.min_fee,
        utilization_multiplier: config.utilization_multiplier,
        min_ask_price: config.min_ask_price,
        max_ask_price: config.max_ask_price,
        pyth_spot_freshness_ms: config.pyth_spot_freshness_ms,
        block_scholes_prices_freshness_ms: config.block_scholes_prices_freshness_ms,
        block_scholes_svi_freshness_ms: config.block_scholes_svi_freshness_ms,
    });
}

/// Resolve the live forward/SVI tuple used by all live pricing paths.
///
/// Fresh Pyth spot is canonical for spot; forward is then derived from the
/// latest Block Scholes basis. If Pyth is stale, pricing falls back to the
/// fresh Block Scholes forward. SVI must be fresh either way.
fun resolve_live_inputs(
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, SVIParams) {
    market_oracle::assert_pyth_source_id(market, pyth.id());
    assert!(!market.is_settled() && clock.timestamp_ms() < market.expiry(), EMarketNotActive);
    assert!(block_scholes_price_is_fresh(config, market, clock), EBlockScholesPriceStale);
    assert!(block_scholes_svi_is_fresh(config, market, clock), EBlockScholesSVIStale);

    let forward = if (pyth_spot_is_fresh(config, pyth, clock)) {
        math::mul(pyth.spot(), market.block_scholes_basis())
    } else {
        market.block_scholes_forward()
    };

    (forward, market.block_scholes_svi())
}

fun resolved_settlement_price(market: &MarketOracle): u64 {
    assert!(market.is_settled(), EOracleNotSettled);
    let (settlement_price, source_timestamp_ms) = market.settlement_price_and_source_timestamp_ms();
    assert!(source_timestamp_ms > market.expiry(), EInvalidSettlementTimestamp);
    settlement_price
}

/// Compute the settled price for the range `(lower, higher]`.
fun compute_settled_range_price(settlement: u64, lower: u64, higher: u64): u64 {
    assert!(lower < higher, EInvalidRange);
    if (settlement > lower && settlement <= higher) constants::float_scaling!() else 0
}

fun block_scholes_price_is_fresh(
    config: &PricingConfig,
    market: &MarketOracle,
    clock: &Clock,
): bool {
    let now = clock.timestamp_ms();
    let timestamp = market.block_scholes_price_freshness_timestamp_ms();
    timestamp > 0 && timestamp <= now && now - timestamp <= config.block_scholes_prices_freshness_ms
}

fun block_scholes_svi_is_fresh(config: &PricingConfig, market: &MarketOracle, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    let timestamp = market.block_scholes_svi_freshness_timestamp_ms();
    timestamp > 0 && timestamp <= now && now - timestamp <= config.block_scholes_svi_freshness_ms
}

fun pyth_spot_is_fresh(config: &PricingConfig, pyth: &PythSource, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    let timestamp = pyth.source_timestamp_ms().min(pyth.update_timestamp_ms());
    timestamp > 0 && timestamp <= now && now - timestamp <= config.pyth_spot_freshness_ms
}

fun validate_freshness_ms(value: u64) {
    assert!(
        value > 0 && value <= tuning_constants::max_freshness_threshold_ms!(),
        EInvalidFreshnessThreshold,
    );
}

fun build_curve(
    forward: u64,
    svi: &SVIParams,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    min_strike: u64,
    max_strike: u64,
): vector<CurvePoint> {
    assert_curve_range(grid_min, grid_tick, grid_max, min_strike, max_strike);

    if (min_strike == max_strike) {
        let price = compute_up_price(forward, svi, min_strike);
        return vector[
            CurvePoint {
                strike: min_strike,
                up_price: price,
            },
        ]
    };

    let price_lo = compute_up_price(forward, svi, min_strike);
    let price_hi = compute_up_price(forward, svi, max_strike);
    let mut points = vector[
        CurvePoint {
            strike: min_strike,
            up_price: price_lo,
        },
        CurvePoint {
            strike: max_strike,
            up_price: price_hi,
        },
    ];

    let curve_samples = constants::default_curve_samples!();
    let mut cur_samples = 2;
    while (cur_samples < curve_samples) {
        let (found, idx) = find_gap(&points, grid_tick);
        if (!found) break;

        let strike_lo = points[idx].strike;
        let strike_hi = points[idx + 1].strike;
        let mid_strike = snap_to_tick((strike_lo + strike_hi) / 2, grid_min, grid_tick);
        let price = compute_up_price(forward, svi, mid_strike);
        insert_asc(
            &mut points,
            CurvePoint {
                strike: mid_strike,
                up_price: price,
            },
        );
        cur_samples = cur_samples + 1;
    };

    points
}

/// Compute the fair UP tail price for `strike`.
fun compute_up_price(forward: u64, svi: &SVIParams, strike: u64): u64 {
    if (strike == constants::neg_inf!()) {
        return constants::float_scaling!()
    };
    if (strike == constants::pos_inf!()) {
        return 0
    };

    compute_nd2(forward, svi, strike)
}

/// Compute the fair price for the range `(lower, higher]`.
fun compute_range_price(forward: u64, svi: &SVIParams, lower: u64, higher: u64): u64 {
    assert!(lower < higher, EInvalidRange);

    let lower_up_price = compute_up_price(forward, svi, lower);
    let higher_up_price = compute_up_price(forward, svi, higher);
    assert!(lower_up_price >= higher_up_price, ERangePriceUnderflow);

    lower_up_price - higher_up_price
}

fun quote_fee_rate(config: &PricingConfig, fair_price: u64, liability: u64, balance: u64): u64 {
    let price_fee = price_fee_rate(config, fair_price);
    let utilization_fee = utilization_fee_rate(config, liability, balance);
    assert!(price_fee <= max_u64() - utilization_fee, EFeeOverflow);

    price_fee + utilization_fee
}

fun price_fee_rate(config: &PricingConfig, fair_price: u64): u64 {
    let raw_fee = raw_bernoulli_fee_rate(config, fair_price);
    let min_fee = config.min_fee;
    if (raw_fee > min_fee) raw_fee else min_fee
}

fun raw_bernoulli_fee_rate(config: &PricingConfig, fair_price: u64): u64 {
    assert!(fair_price <= constants::float_scaling!(), EInvalidLiveFairPrice);
    if (fair_price == 0 || fair_price == constants::float_scaling!()) return 0;

    let complement = constants::float_scaling!() - fair_price;
    let variance = math::mul(fair_price, complement);
    let bernoulli_factor = predict_math::sqrt(variance, constants::float_scaling!());
    math::mul(config.base_fee, bernoulli_factor)
}

fun utilization_fee_rate(config: &PricingConfig, liability: u64, balance: u64): u64 {
    if (balance == 0 || liability == 0) return 0;

    let util = if (liability >= balance) {
        constants::float_scaling!()
    } else {
        math::div(liability, balance)
    };
    let util_sq = math::mul(util, util);
    math::mul(
        config.base_fee,
        math::mul(config.utilization_multiplier, util_sq),
    )
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
fun compute_nd2(forward: u64, svi: &SVIParams, strike: u64): u64 {
    assert!(forward > 0, EZeroForward);

    let k = predict_math::ln(math::div(strike, forward));
    let m = market_oracle::svi_m(svi);
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = market_oracle::svi_sigma(svi);
    let sigma_squared = math::mul(sigma, sigma);
    assert!(k_minus_m_squared <= max_u64() - sigma_squared, ESVISqrtInputOverflow);
    let sqrt_input = k_minus_m_squared + sigma_squared;
    let sq = predict_math::sqrt(sqrt_input, constants::float_scaling!());
    let sq_i64 = i64::from_u64(sq);

    let rho = market_oracle::svi_rho(svi);
    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    assert!(!inner.is_negative(), ECannotBeNegative);

    let a = market_oracle::svi_a(svi);
    let b = market_oracle::svi_b(svi);
    let wing_var = math::mul(b, inner.magnitude());
    assert!(a <= max_u64() - wing_var, ETotalVarianceOverflow);
    let total_var = a + wing_var;
    assert!(total_var > 0, EZeroVariance);

    let sqrt_var = predict_math::sqrt(total_var, constants::float_scaling!());
    let sqrt_var_i64 = i64::from_u64(sqrt_var);
    let half_var_i64 = i64::from_u64(total_var / 2);
    let d2_numerator = k.add(&half_var_i64);
    let d2 = d2_numerator.div_scaled(&sqrt_var_i64);
    let d2 = d2.neg();

    predict_math::normal_cdf(&d2)
}

fun assert_curve_range(
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    min_strike: u64,
    max_strike: u64,
) {
    assert!(min_strike <= max_strike, EInvalidCurveRange);
    assert!(min_strike >= grid_min && min_strike <= grid_max, EInvalidCurveRange);
    assert!(max_strike >= grid_min && max_strike <= grid_max, EInvalidCurveRange);
    assert!((min_strike - grid_min) % grid_tick == 0, EInvalidCurveRange);
    assert!((max_strike - grid_min) % grid_tick == 0, EInvalidCurveRange);
}

/// Insert a new curve point while preserving ascending strike order.
fun insert_asc(points: &mut vector<CurvePoint>, new_point: CurvePoint) {
    points.push_back(new_point);
    let mut i = points.length() - 1;
    while (i > 0) {
        if (points[i - 1].strike <= points[i].strike) break;
        points.swap(i - 1, i);
        i = i - 1;
    };
}

/// Pick the next adjacent gap to bisect based on endpoint UP-price difference.
fun find_gap(points: &vector<CurvePoint>, grid_tick: u64): (bool, u64) {
    let len = points.length();
    let mut best_idx = len;
    let mut best_price_diff = 0;

    let mut i = 0;
    while (i + 1 < len) {
        let lo = &points[i];
        let hi = &points[i + 1];

        if (hi.strike - lo.strike <= grid_tick) {
            i = i + 1;
            continue
        };

        // `points` is strike-sorted, and UP price is monotone non-increasing in strike.
        let price_diff = lo.up_price - hi.up_price;
        if (price_diff > best_price_diff) {
            best_idx = i;
            best_price_diff = price_diff;
        };

        i = i + 1;
    };

    (best_idx != len, best_idx)
}

/// Round a strike down to the nearest tick boundary.
fun snap_to_tick(strike: u64, grid_min: u64, grid_tick: u64): u64 {
    grid_min + (strike - grid_min) / grid_tick * grid_tick
}

// === Test-Only Functions ===

#[test_only]
public fun destroy_for_testing(config: PricingConfig) {
    let PricingConfig {
        base_fee: _,
        min_fee: _,
        utilization_multiplier: _,
        min_ask_price: _,
        max_ask_price: _,
        pyth_spot_freshness_ms: _,
        block_scholes_prices_freshness_ms: _,
        block_scholes_svi_freshness_ms: _,
    } = config;
}
