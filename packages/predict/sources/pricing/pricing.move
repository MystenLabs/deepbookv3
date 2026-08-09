// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module reads canonical Propbook Pyth and Block Scholes feeds and computes
/// SVI-adjusted digital probabilities. Live reads require fresh, pricing-safe Block
/// Scholes spot, forward, and SVI observations. The live forward comes from one of
/// two admin-selected sources (`PricingConfig.use_pyth_spot_for_forward`): a fresh
/// positive Pyth spot carrying the Block Scholes basis, or the Block Scholes forward
/// directly. Exact-history reads do not apply live freshness policy.
module deepbook_predict::pricing;

use deepbook_predict::{constants, pricing_config::PricingConfig, range_codec::{Self, Strike}};
use fixed_math::{i64::{Self, I64}, math};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore, SVIParams},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use sui::clock::Clock;

/// Validated live oracle inputs bound to one expiry market. `Pricer` has no
/// `store` ability and must be created again in each transaction that prices.
public struct Pricer has copy, drop {
    /// Expiry market this snapshot was loaded for.
    expiry_market_id: ID,
    forward: u64,
    svi: PricingSVI,
    /// Source timestamps of the oracle observations present when this snapshot
    /// was loaded. Pyth is `0` only when no usable normalized observation exists.
    /// The Block Scholes ones are the provider's model times — when each series' data is "as of",
    /// held fixed across retransmissions of an unchanged value. They are provenance for trade
    /// events; freshness and the SVI roll-down anchor instead read each observation's batch
    /// envelope time (`published_at_ms`), which is consumed during the load and not retained here.
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Block Scholes SVI parameters at Predict's own widths, before roll-down.
///
/// The provider carries every parameter at 128 bits; Predict prices `rho`, `m`, and `sigma` at 64,
/// so the narrowing happens once where the `Pricer` is built and every bound below reads these
/// widths. A provider value too large for them aborts with `EBlockScholesInputTooWide` before the
/// cast, and everything representable is then bounded semantically by `assert_inputs_pricing_safe`,
/// whose limits are far tighter than the widths.
public struct RawSVI has copy, drop {
    a: I64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Transaction-local SVI parameters after applying Predict's remaining-time roll-down.
///
/// `a` and `b` are carried at **1e18**, not 1e9. The roll-down multiplies both by
/// `remaining_ms / anchor_tte_ms`, and flooring that product at 1e9 discards up to
/// a full raw unit — which a short-dated surface cannot afford, because its whole
/// total variance is only about ten raw units at 1e9. Keeping the rolled values at
/// 1e18 hands `variance_sqrt_and_d2` the same domain it already computes in.
public struct PricingSVI has copy, drop {
    /// Rolled-down SVI `a`, magnitude at 1e18, sign in `a_is_negative`.
    a_magnitude: u128,
    a_is_negative: bool,
    /// Rolled-down SVI `b`, at 1e18.
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Canonical normalized Pyth spot read at one exact source timestamp.
/// Constructed only by `load_exact_spot_read`; consumers decide whether an
/// absent exact-history row is a no-op or an abort.
public struct ExactSpotRead has drop {
    spot: Option<u64>,
}

/// Per-flush cache of `up_price` results keyed by finite boundary tick, ascending
/// and non-increasing in price.
///
/// The NAV linear walk (`strike_payout_tree::walk_linear`) fills it once per node
/// as it prices the payout tree in-order; the correction walk
/// (`liquidation_book::correction_value`) then reads each leveraged order's boundary
/// prices back by binary search instead of re-pricing every order. Every active
/// leveraged order's finite boundary ticks are payout-tree nodes, so every finite
/// lookup MUST hit: a miss is a broken exposure index, not a cache fallback, and
/// `cached_range_price` aborts `ETickNotInPriceMemo` rather than silently repricing.
/// The same cache rejects non-monotone UP prices during NAV valuation, because
/// `walk_linear` tree-wide netting is exact only on a monotone active surface.
public struct PriceMemo has drop {
    /// Finite boundary ticks in ascending order (the in-order walk appends them).
    ticks: vector<u64>,
    /// `up_price(ticks[i] * tick_size)`, parallel to `ticks`.
    prices: vector<u64>,
}

const EZeroForward: u64 = 0;
const ECannotBeNegative: u64 = 1;
const ENonPositiveVariance: u64 = 2;
const EInvalidRange: u64 = 3;
const EBlockScholesPriceStale: u64 = 4;
const EBlockScholesInputsInvalid: u64 = 5;
const EPythSpotInvalid: u64 = 6;
const EWrongPythFeed: u64 = 7;
const EWrongBlockScholesValueStore: u64 = 8;
const ELivePricingExpired: u64 = 9;
const EBlockScholesSVIStale: u64 = 10;
const EWrongBlockScholesSVIStore: u64 = 11;
const ETickNotInPriceMemo: u64 = 12;
const EBlockScholesPriceUnavailable: u64 = 13;
const EBlockScholesSVIUnavailable: u64 = 14;
const EBlockScholesMinVarianceInvalid: u64 = 15;
const ENonMonotonePriceMemo: u64 = 16;
/// A live pricer may not be built from an oracle observation written in this
/// transaction. Named for the observation's provenance (`writer_digest` vs
/// `tx_context::digest()`), not sender identity — not every read of a same-tx
/// write is prohibited (Pyth is checked only on the re-anchor branch).
const EOracleWrittenInThisTransaction: u64 = 17;
const EBlockScholesInputTooWide: u64 = 18;

/// Predict's private pricing envelope for raw propbook BS inputs. These are not
/// oracle-source validity rules; they only bound the forward/basis and SVI inputs
/// tightly enough that Predict's fixed-point pricing math remains live and
/// meaningful.
macro fun max_pricing_basis_factor(): u64 { 100 }

// Co-designed with the basis factor: forward <= factor * spot (envelope) and
// spot <= u64::max / factor, so the re-anchored forward spot * bs_forward /
// bs_spot <= factor * spot can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / max_pricing_basis_factor!() }

macro fun min_svi_sigma(): u64 { 1_000_000 }

macro fun max_svi_input(): u64 { 100 * math::float_scaling!() }

// === Public Functions ===

/// Return the current UP digital probability for a typed strike. Public PTB and
/// devInspect reads can compose it with a transaction-local `Pricer`.
public fun up_price(pricer: &Pricer, strike: Strike): u64 {
    compute_up_price(&pricer.svi, pricer.forward, strike)
}

/// Return the current probability for `(lower, higher]`, floored at zero if the
/// two approximated boundary probabilities invert.
public fun range_price(pricer: &Pricer, lower: Strike, higher: Strike): u64 {
    compute_range_price(&pricer.svi, pricer.forward, lower, higher)
}

// === Public-Package Functions ===

/// Return the expiry market this pricer was loaded for.
public(package) fun expiry_market_id(pricer: &Pricer): ID {
    pricer.expiry_market_id
}

public(package) fun pyth_spot_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.pyth_spot_source_timestamp_ms
}

public(package) fun block_scholes_spot_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_spot_source_timestamp_ms
}

public(package) fun block_scholes_forward_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_forward_source_timestamp_ms
}

public(package) fun block_scholes_svi_source_timestamp_ms(pricer: &Pricer): u64 {
    pricer.block_scholes_svi_source_timestamp_ms
}

/// Scale one 1e9-scaled SVI magnitude down by the fraction of anchored time
/// remaining, returning it at 1e18.
///
/// The roll-down result is kept at 1e18 because the fraction is applied to values
/// that are themselves tiny on short-dated surfaces: a 1e9 floor here costs up to
/// a whole raw unit of `a`, and a short-dated `a` is only about ten raw units, so
/// the truncation alone moves the digital by percent-scale amounts. At 1e18 the
/// same floor is a billionth of that.
///
/// The `u256` intermediate keeps the product exact for any `expiry_ms` rather than
/// relying on a bound on the anchored horizon. The result is at most
/// `value * 1e9 <= max_svi_input * 1e9`, so narrowing to `u128` never truncates.
public(package) fun roll_down_to_1e18(value: u64, remaining_ms: u64, anchor_tte_ms: u64): u128 {
    let scaled =
        (value as u256) * (math::float_scaling!() as u256) * (remaining_ms as u256)
        / (anchor_tte_ms as u256);
    scaled as u128
}

public(package) fun into_spot(read: ExactSpotRead): Option<u64> {
    let ExactSpotRead { spot } = read;
    spot
}

/// Validate the current live pricing boundary and snapshot oracle inputs for
/// one market's repeated quote calculations.
///
/// The supplied feeds must be the current Propbook bindings for the underlying,
/// and the market must be pre-expiry. Block Scholes spot, forward, and SVI inputs
/// must normalize, pass their fixed wall-clock freshness thresholds, and fit the
/// pricing-safe envelope. SVI `a` and `b` are then rolled down from the tuple's
/// batch publish timestamp to the current remaining time. Under
/// `use_pyth_spot_for_forward` a fresh positive normalized Pyth spot reanchors the
/// Block Scholes forward basis, and a missing, non-normalizable, or stale Pyth spot
/// is ignored; with it off the Block Scholes forward is always used directly.
public(package) fun load_live_pricer(
    config: &PricingConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    clock: &Clock,
    ctx: &TxContext,
): Pricer {
    assert_current_oracles(
        propbook_registry,
        propbook_underlying_id,
        pyth,
        bs_values,
        bs_svi,
    );
    assert!(clock.timestamp_ms() < expiry, ELivePricingExpired);
    resolve_live_pricer(
        config,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
        expiry,
        clock,
        ctx,
    )
}

/// Validate the canonical Pyth binding and read its normalized spot at exactly
/// `source_timestamp_ms`. The product preserves absence so the reference-tick
/// and settlement flows can retain their distinct missing-data policies.
public(package) fun load_exact_spot_read(
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
): ExactSpotRead {
    assert_current_pyth(propbook_registry, propbook_underlying_id, pyth);
    let read = pyth.normalized_spot_at(source_timestamp_ms);
    let spot = if (read.is_some()) {
        option::some(read.destroy_some().read_value())
    } else {
        option::none()
    };
    ExactSpotRead { spot }
}

/// Create an empty per-flush price cache (see `PriceMemo`).
public(package) fun new_price_memo(): PriceMemo {
    PriceMemo { ticks: vector[], prices: vector[] }
}

/// Read the cached range price `up_price(lower) - up_price(higher)` for one order's
/// tick range, mirroring `range_price`'s infinity sentinels and saturating floor.
/// Both finite boundaries must have been cached by the linear walk; a finite miss
/// aborts (the order's tick is not a payout-tree node — a broken index, not dust).
public(package) fun cached_range_price(memo: &PriceMemo, lower_tick: u64, higher_tick: u64): u64 {
    memo.cached_up_price(lower_tick).saturating_sub(memo.cached_up_price(higher_tick))
}

/// Price `tick` through `pricer` and append it to the cache. Called once per node by
/// the in-order linear walk, so `ticks` stays ascending for `cached_up_price`'s
/// binary search. Only finite ticks are stored (the tree never holds inf boundaries).
public(package) fun price_and_cache(
    memo: &mut PriceMemo,
    pricer: &Pricer,
    tick: u64,
    tick_size: u64,
): u64 {
    let price = pricer.up_price(range_codec::strike_from_tick(tick, tick_size));
    if (!memo.prices.is_empty()) {
        let previous = memo.prices[memo.prices.length() - 1];
        // Higher strikes should not have higher UP prices. NAV's linear tree walk
        // relies on that order; an inverted surface can overstate pool value.
        assert!(price <= previous, ENonMonotonePriceMemo);
    };
    memo.ticks.push_back(tick);
    memo.prices.push_back(price);
    price
}

// === Private Functions ===

/// Look up a boundary tick's cached UP price. Infinity boundaries are never tree
/// nodes, so they short-circuit to `compute_up_price`'s sentinels (`P(-inf) = 1`,
/// `P(+inf) = 0`); every finite tick must be present or the exposure index is broken.
fun cached_up_price(memo: &PriceMemo, tick: u64): u64 {
    if (tick == 0) return math::float_scaling!(); // tick 0 is the neg-inf sentinel
    if (tick == constants::pos_inf_tick!()) return 0;

    let ticks = &memo.ticks;
    let mut lo = 0;
    let mut hi = ticks.length();
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        let mid_tick = ticks[mid];
        if (mid_tick == tick) return memo.prices[mid];
        if (mid_tick < tick) lo = mid + 1 else hi = mid;
    };
    abort ETickNotInPriceMemo
}

/// Validate all supplied feed objects against Propbook's canonical bindings.
fun assert_current_oracles(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
) {
    assert_current_pyth(propbook_registry, propbook_underlying_id, pyth);
    let block_scholes_binding = propbook_registry.propbook_block_scholes_store_pair_for_underlying(
        propbook_underlying_id,
    );
    assert!(block_scholes_binding.is_some(), EWrongBlockScholesValueStore);
    let block_scholes_binding = block_scholes_binding.destroy_some();
    assert!(
        block_scholes_binding.block_scholes_value_store_id() == bs_values.value_store_id(),
        EWrongBlockScholesValueStore,
    );
    assert!(
        block_scholes_binding.block_scholes_svi_store_id() == bs_svi.svi_store_id(),
        EWrongBlockScholesSVIStore,
    );
}

fun assert_current_pyth(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
) {
    assert!(
        propbook_registry
            .propbook_pyth_id_for_underlying(propbook_underlying_id)
            .contains(&pyth.id()),
        EWrongPythFeed,
    );
}

/// Resolve live forward and SVI inputs and retain every feed's source timestamp.
/// Under `use_pyth_spot_for_forward` a fresh positive normalized Pyth spot
/// re-anchors the Block Scholes forward basis; otherwise the Block Scholes
/// forward is used directly.
///
/// Aborts if any observation that feeds the returned price was written in this
/// transaction. Pyth is checked only on the re-anchor branch: when the flag is
/// off or the read is stale, the observation is provenance-only and must not
/// trip the guard.
fun resolve_live_pricer(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry_market_id: ID,
    expiry: u64,
    clock: &Clock,
    ctx: &TxContext,
): Pricer {
    let bs_spot_read = bs_values.spot();
    assert!(bs_spot_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_spot_read = bs_spot_read.destroy_some();
    assert_oracle_not_written_this_tx(&bs_spot_read.read_writer_digest(), ctx);
    // Freshness reads each observation's batch envelope time, not its model time: per the
    // provider contract, every publish carries values valid as-of that publish (an unchanged
    // model time means the same calibration republished, for SVI already rolled down to the new
    // publish — never duplicate data). Pricing therefore halts only when envelopes stop arriving
    // within the window (transport stopped), never merely because the calibration clock is quiet.
    // The store admits an observation only when `model <= published <= recorded`.
    // The model times are still snapshotted below as trade-event provenance.
    assert!(
        timestamp_is_fresh(
            bs_spot_read.read_published_at_ms(),
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let block_scholes_spot_source_timestamp_ms = bs_spot_read.read_model_timestamp_ms();
    let bs_spot = narrow_price(bs_spot_read.read_value());

    let bs_forward_read = bs_values.forward(expiry);
    assert!(bs_forward_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_forward_read = bs_forward_read.destroy_some();
    assert_oracle_not_written_this_tx(&bs_forward_read.read_writer_digest(), ctx);
    assert!(
        timestamp_is_fresh(
            bs_forward_read.read_published_at_ms(),
            config.block_scholes_price_freshness_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let block_scholes_forward_source_timestamp_ms = bs_forward_read.read_model_timestamp_ms();
    let bs_forward = narrow_price(bs_forward_read.read_value());

    let svi_read = bs_svi.svi(expiry);
    assert!(svi_read.is_some(), EBlockScholesSVIUnavailable);
    let svi_read = svi_read.destroy_some();
    assert_oracle_not_written_this_tx(&svi_read.read_writer_digest(), ctx);
    // One clock serves both jobs: the envelope time the freshness gate just accepted is also the
    // roll-down anchor, so the parameters and their anchor always come from the same read. The
    // gate's `published_at <= now` bound plus the pre-expiry check keep the anchor strictly
    // before expiry, so the roll-down's `expiry - anchor` never underflows.
    let block_scholes_svi_published_at_ms = svi_read.read_published_at_ms();
    assert!(
        timestamp_is_fresh(
            block_scholes_svi_published_at_ms,
            config.block_scholes_svi_freshness_ms(),
            clock,
        ),
        EBlockScholesSVIStale,
    );
    let block_scholes_svi_source_timestamp_ms = svi_read.read_model_timestamp_ms();
    let raw_svi = narrow_svi(&svi_read.read_value());
    assert_inputs_pricing_safe(bs_spot, bs_forward, &raw_svi);
    let svi = roll_down_svi(
        &raw_svi,
        block_scholes_svi_published_at_ms,
        expiry,
        clock,
    );

    // Read whatever the config does with it: the Pyth observation is retained on
    // every `Pricer` for trade-event provenance, including while
    // `use_pyth_spot_for_forward` keeps it out of the forward.
    let pyth_spot = pyth.normalized_spot();
    let pyth_spot_source_timestamp_ms = if (pyth_spot.is_some()) {
        pyth_spot.borrow().read_source_timestamp_ms()
    } else {
        0
    };
    let mut forward = bs_forward;
    if (
        config.use_pyth_spot_for_forward()
            && pyth_spot.is_some()
            && timestamp_is_fresh(
                pyth_spot_source_timestamp_ms,
                config.pyth_spot_freshness_ms(),
                clock,
            )
    ) {
        let pyth_spot = pyth_spot.destroy_some();
        assert_oracle_not_written_this_tx(&pyth_spot.read_writer_digest(), ctx);
        let spot = pyth_spot.read_value();
        assert!(spot <= max_pricing_spot!(), EPythSpotInvalid);
        // The re-anchored forward may exceed the input spot ceiling. The basis and
        // spot bounds still guarantee this multiplication and result fit in u64.
        forward = math::mul_div_down(spot, bs_forward, bs_spot);
    };

    Pricer {
        expiry_market_id,
        forward,
        svi,
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms,
    }
}

fun assert_oracle_not_written_this_tx(writer_digest: &vector<u8>, ctx: &TxContext) {
    assert!(writer_digest != ctx.digest(), EOracleWrittenInThisTransaction);
}

/// Narrow one Block Scholes price to Predict's pricing width with the provider-width error shared
/// by every Block Scholes input.
fun narrow_price(value: u128): u64 {
    narrow_input(value)
}

/// Narrow a stored Block Scholes tuple to Predict's pricing widths, keeping the provider's
/// magnitude-and-sign form for the signed parameters.
fun narrow_svi(svi: &SVIParams): RawSVI {
    RawSVI {
        a: i64::from_parts(narrow_input(svi.svi_a_magnitude()), svi.svi_a_is_negative()),
        b: narrow_input(svi.svi_b()),
        rho: i64::from_parts(narrow_input(svi.svi_rho_magnitude()), svi.svi_rho_is_negative()),
        m: i64::from_parts(narrow_input(svi.svi_m_magnitude()), svi.svi_m_is_negative()),
        sigma: narrow_input(svi.svi_sigma()),
    }
}

fun narrow_input(value: u128): u64 {
    assert!(value <= (std::u64::max_value!() as u128), EBlockScholesInputTooWide);
    value as u64
}

fun a(svi: &RawSVI): I64 {
    svi.a
}

fun b(svi: &RawSVI): u64 {
    svi.b
}

fun rho(svi: &RawSVI): I64 {
    svi.rho
}

fun m(svi: &RawSVI): I64 {
    svi.m
}

fun sigma(svi: &RawSVI): u64 {
    svi.sigma
}

fun roll_down_svi(svi: &RawSVI, published_at_ms: u64, expiry_ms: u64, clock: &Clock): PricingSVI {
    let remaining_ms = expiry_ms - clock.timestamp_ms();
    let anchor_tte_ms = expiry_ms - published_at_ms;
    let a = svi.a();
    PricingSVI {
        a_magnitude: roll_down_to_1e18(a.magnitude(), remaining_ms, anchor_tte_ms),
        a_is_negative: a.is_negative(),
        b: roll_down_to_1e18(svi.b(), remaining_ms, anchor_tte_ms),
        rho: svi.rho(),
        m: svi.m(),
        sigma: svi.sigma(),
    }
}

fun timestamp_is_fresh(source_timestamp_ms: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    source_timestamp_ms > 0 && source_timestamp_ms <= now && now - source_timestamp_ms <= max_age_ms
}

fun assert_inputs_pricing_safe(spot: u64, forward: u64, svi: &RawSVI) {
    assert!(spot > 0 && forward > 0, EBlockScholesInputsInvalid);
    assert!(forward <= max_pricing_spot!(), EBlockScholesInputsInvalid);
    // `ceil(forward / factor) <= spot` enforces `forward <= factor * spot`
    // without an overflowing multiplication.
    assert!(forward.div_ceil(max_pricing_basis_factor!()) <= spot, EBlockScholesInputsInvalid);
    assert!(svi.a().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.b() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EBlockScholesInputsInvalid);
    assert!(svi.m().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(
        svi.sigma() >= min_svi_sigma!() && svi.sigma() <= max_svi_input!(),
        EBlockScholesInputsInvalid,
    );
    assert_min_total_variance_positive(svi);
}

fun assert_min_total_variance_positive(svi: &RawSVI) {
    let min_variance_increment = min_svi_variance_increment(svi);
    let a = svi.a();
    let min_total_var = i64::from_u64(min_variance_increment).add(&a);
    assert!(is_positive(&min_total_var), EBlockScholesMinVarianceInvalid);
}

// SVI total variance is `a + b * (rho*x + sqrt(x^2 + sigma^2))`, where
// `x = k - m`. This returns the smallest possible non-`a` part over all strikes:
// `b * sigma * sqrt(1 - rho^2)`, or 0 at the `|rho| == 1` boundary.
fun min_svi_variance_increment(svi: &RawSVI): u64 {
    let rho_mag = svi.rho().magnitude();
    if (rho_mag == math::float_scaling!()) return 0;

    let one_minus_rho_squared = math::float_scaling!() - math::mul_down(rho_mag, rho_mag);
    let sqrt_one_minus_rho_squared = math::sqrt_down(one_minus_rho_squared);
    math::mul_down(svi.b(), math::mul_down(svi.sigma(), sqrt_one_minus_rho_squared))
}

/// Compute the approximated probability for `(lower, higher]`.
fun compute_range_price(svi: &PricingSVI, forward: u64, lower: Strike, higher: Strike): u64 {
    assert!(lower.value() < higher.value(), EInvalidRange);

    let lower_up_price = compute_up_price(svi, forward, lower);
    let higher_up_price = compute_up_price(svi, forward, higher);
    // Fixed-point approximation or a non-monotone SVI surface can invert the
    // boundary prices; the range probability is floored at zero.
    lower_up_price.saturating_sub(higher_up_price)
}

/// Compute the adjusted UP digital probability for `strike`.
fun compute_up_price(svi: &PricingSVI, forward: u64, strike: Strike): u64 {
    if (strike.is_neg_inf()) {
        return math::float_scaling!()
    };
    if (strike.is_pos_inf()) {
        return 0
    };

    compute_nd2(svi, forward, strike.value())
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
fun compute_nd2(svi_params: &PricingSVI, forward: u64, strike: u64): u64 {
    assert!(forward > 0, EZeroForward);

    // Log-moneyness as a DIFFERENCE of logarithms, never as `ln` of a fixed-point
    // ratio. Forming `strike * 1e9 / forward` first destroys exactly the tails it
    // is asked about: the quotient floors to zero once `strike` is a billionth of
    // `forward` and leaves `u64` once it is 1.8e10 times it, and just inside those
    // limits it survives as a handful of raw units carrying tens of percent of
    // truncation error. That is why this used to short-circuit to the digital
    // limits 1 and 0 there — a saturation that is only true when total variance is
    // small, and silently wrong when it is not, on a value the mint's entry
    // probability, the liquidation threshold and the NAV mark all consume.
    //
    // `ln` is defined across the whole positive `u64` domain, so the difference is
    // well-conditioned over every representable pair: `|k| <= 44.4` against the
    // 20.7 the ratio form could reach, at a relative error of 1e-7 per term rather
    // than a relative error that grows without bound as the tail deepens. No
    // strike needs a special case, and no surface has to be restricted to keep a
    // shortcut honest.
    let k = math::ln(strike).sub(&math::ln(forward));
    let m = svi_params.m;
    let k_minus_m = k.sub(&m);
    let k_minus_m_squared = k_minus_m.square_scaled();
    let sigma = svi_params.sigma;
    let sigma_squared = math::mul_down(sigma, sigma);
    let sqrt_input = k_minus_m_squared + sigma_squared;
    let sq = math::sqrt_down(sqrt_input);
    let sq_i64 = i64::from_u64(sq);

    let rho = svi_params.rho;
    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    // This term is non-negative for |rho| <= 1; abort if fixed-point evaluation
    // violates that invariant at the envelope boundary.
    assert!(!inner.is_negative(), ECannotBeNegative);

    let b = svi_params.b;
    let (sqrt_var, d2) = variance_sqrt_and_d2(
        svi_params.a_magnitude,
        svi_params.a_is_negative,
        b,
        inner.magnitude(),
        &k,
    );

    let slope_ratio = k_minus_m.div_scaled(&sq_i64);
    let slope = rho.add(&slope_ratio);
    // `b` is at 1e18 and `slope` at 1e9, so the product comes back down by 1e18
    // to leave `w'` at 1e9. `b <= max_svi_input * 1e9` and `|slope| <= 2e9`
    // (`|rho| <= 1e9` and `|k - m| <= sq`), so the u128 product and the u64
    // narrowing both fit.
    let scale = math::float_scaling!() as u128;
    let w_prime_magnitude = (b * (slope.magnitude() as u128) / (scale * scale)) as u64;
    let nd2 = math::normal_cdf(&d2);
    if (w_prime_magnitude == 0) return nd2;

    let correction_magnitude = math::mul_div_down(
        math::normal_pdf(&d2),
        w_prime_magnitude,
        2 * sqrt_var,
    );
    let correction = i64::from_parts(correction_magnitude, slope.is_negative());
    let adjusted = i64::from_u64(nd2).sub(&correction);
    if (adjusted.is_negative()) return 0;
    if (adjusted.magnitude() > math::float_scaling!()) return math::float_scaling!();
    adjusted.magnitude()
}

/// Total variance `w`, its square root, and `d2`, carried at `u128` / 1e18.
///
/// `a_magnitude` and `b` arrive already rolled down and already at 1e18, so the
/// whole variance assembly stays in that domain: narrowing either back to 1e9
/// discards the entire low-variance signal, because a five-minute surface has
/// `w ~ 1e-8` — about ten raw units at 1e9. `inner` is 1e9-scaled, so `b * inner`
/// comes back down by 1e9 to land at 1e18. `sqrt_u128_down` of a 1e18 value is
/// its 1e9-scaled root, so `sqrt(w)` returns at the scale the rest of the
/// formula reads. Returns `(sqrt(w), d2)`; aborts `ENonPositiveVariance` when
/// `w <= 0`, which pricing requires because it divides by `sqrt(w)`.
fun variance_sqrt_and_d2(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    inner: u64,
    k: &I64,
): (u64, I64) {
    let scale = math::float_scaling!() as u128;
    let increment = b * (inner as u128) / scale;
    let total_var = if (a_is_negative) {
        assert!(increment > a_magnitude, ENonPositiveVariance);
        increment - a_magnitude
    } else {
        assert!(increment + a_magnitude > 0, ENonPositiveVariance);
        increment + a_magnitude
    };
    let sqrt_var = math::sqrt_u128_down(total_var) as u64;

    // d2 = -(k + w/2) / sqrt(w). The numerator stays at 1e18 and the divisor is
    // the 1e9-scaled root, so the quotient lands at 1e9 with its sign tracked by
    // hand — I64 cannot hold either operand at 1e18.
    let k_scaled = (k.magnitude() as u128) * scale;
    let half_var = total_var / 2;
    let (numerator, numerator_negative) = if (!k.is_negative()) {
        (k_scaled + half_var, false)
    } else if (half_var >= k_scaled) {
        (half_var - k_scaled, false)
    } else {
        (k_scaled - half_var, true)
    };
    // `normal_cdf` / `normal_pdf` saturate beyond |x| > 8, so cap the magnitude
    // there: the quotient grows without bound as w -> 0 and would otherwise
    // overflow the u64 cast.
    let saturation = 8 * scale + 1;
    let d2_magnitude = numerator / (sqrt_var as u128);
    let d2_magnitude = if (d2_magnitude > saturation) saturation else d2_magnitude;

    (sqrt_var, i64::from_parts(d2_magnitude as u64, !numerator_negative))
}

fun is_positive(value: &I64): bool {
    !value.is_negative() && !value.is_zero()
}

/// Scalar-input view of `variance_sqrt_and_d2` for the unit tests. The d2
/// saturation guards a `u128 -> u64` cast that no admissible SVI surface has been
/// shown to reach — the pricer-load minimum-variance gate keeps `sqrt(w)` large
/// enough that the quotient stays far inside `u64` — so the guard is exercised at
/// its own inputs rather than through a contrived surface (unit-tests rule 4).
#[test_only]
public(package) fun variance_sqrt_and_d2_for_testing(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    inner: u64,
    k: &I64,
): (u64, I64) {
    variance_sqrt_and_d2(a_magnitude, a_is_negative, b, inner, k)
}
