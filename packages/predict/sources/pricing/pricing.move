// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module reads canonical Propbook Pyth and Block Scholes feeds and computes
/// SVI-adjusted digital probabilities. Live reads require fresh, pricing-safe Block
/// Scholes spot, forward, and SVI observations. The latest forward is paired with an exact
/// source-timestamp spot from Propbook's bounded recent history. The live forward comes from one of
/// two admin-selected sources (`PricingConfig.use_pyth_spot_for_forward`): a fresh
/// positive Pyth spot carrying the Block Scholes basis, or the Block Scholes forward
/// directly. A load falls back to the Block Scholes forward when the selected Pyth
/// spot is stale or unavailable; valuation prices on that fallback, while every
/// live trade (mints, mint quotes, and live redeems) refuses it through
/// `assert_pyth_spot_fresh`. Exact-history reads do not apply live freshness policy.
///
/// Delayed execution splits that read in two. `load_vol` validates the same live
/// inputs when an order is admitted and returns the raw Block Scholes basis and SVI its receipt
/// stores; `pricer_at` later rebuilds a `Pricer` from them at the order's committed Pyth tick.
/// The `try_*` reads price exactly as `up_price` and `range_price` do, and return `none` where
/// those abort, so an order-flow fill never aborts on a surface.
module deepbook_predict::pricing;

use deepbook_predict::{pricing_config::PricingConfig, range_codec::Strike};
use fixed_math::{i64::{Self, I64}, math};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore, SVIParams},
    pyth_feed::PythFeed,
    registry::{BlockScholesStorePair, OracleRegistry}
};
use sui::clock::Clock;

/// Validated live oracle inputs bound to one expiry market.
///
/// `Pricer` has NO `store` ability, by design: a non-`store` value cannot enter
/// an object or a dynamic field, so it cannot survive the transaction that
/// loaded it. `load_live_pricer` is the only constructor whose result a trade path
/// accepts from a caller (package-only `thaw` rebuilds one solely inside the flush's
/// `snapshot_nav`, and the queue's `load_vol` and `pricer_at` build ones no
/// public function returns) and validates oracle freshness, the same-transaction-digest
/// guard, and `clock < expiry` at load; the live trade paths then gate a supplied `&Pricer`
/// on market-id (`chk_pricer`) and on the Pyth spot this snapshot
/// recorded (`assert_pyth_spot_fresh`), never on a second oracle read. The
/// non-`store` ability is therefore the structural
/// guarantee that every fund-moving trade prices against a mark loaded in its
/// OWN transaction — a persisted, stale-favorable mark can never reach a trade.
/// The full-pool flush, which must carry one mark per market across
/// transactions, uses the separate `FrozenPricer` below (which no trade
/// entrypoint accepts). See RP-32.
public struct Pricer has copy, drop {
    /// Expiry market this snapshot was loaded for.
    expiry_market_id: ID,
    forward: u64,
    svi: PricingSVI,
    /// Timestamps of the oracle observations this snapshot validated, as trade events report
    /// them — each observation's own economic clock. Pyth carries its source timestamp (`0` only
    /// when no usable normalized observation exists; a `pricer_at` Pricer carries the committed
    /// update's generation time); Block Scholes spot and forward carry the
    /// provider `value_timestamp`, and SVI carries the provider `svi_timestamp`. Those timestamps
    /// are the clocks freshness gates and SVI roll-down use. The Pyth timestamp, including its `0`
    /// sentinel, is also what `assert_pyth_spot_fresh` gates live trades on, so it must stay the
    /// value the load's forward selection read.
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Boundary probabilities from one pricing snapshot. Absent boundaries are the
/// negative/positive infinity sentinels, not finite strikes priced at zero or one.
public struct RangePrice has copy, drop {
    lower_up: Option<u64>,
    higher_up: Option<u64>,
}

/// The flush's storable form of a `Pricer`. `seal_valuation_snapshot` freezes one
/// per market inside `plp::PoolValuation` so every market is marked at one instant
/// even though valuation spans transactions; `snapshot_nav` thaws it back to a
/// transient `Pricer` for the frozen walk. It is a DELIBERATELY stale mark and is
/// never accepted by any live trade entrypoint — only a fresh `Pricer` is — which
/// is what keeps a persisted mark from ever pricing a fund-moving trade (RP-32).
/// Construction (`into_frozen`) and consumption (`thaw`) are package-internal, so
/// no external caller can mint or unwrap one.
public struct FrozenPricer has copy, drop, store {
    expiry_market_id: ID,
    forward: u64,
    svi: PricingSVI,
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

/// Block Scholes SVI parameters at Predict's own widths, before roll-down.
///
/// The provider carries every parameter at 128 bits; Predict prices `rho`, `m`, and `sigma` at 64,
/// so the narrowing happens once where the live inputs are read and every bound below reads these
/// widths. A provider value too large for them aborts with `EBlockScholesInputTooWide` before the
/// cast, and everything representable is then checked by `chk_inputs`: `b`, `rho`,
/// `m`, and `sigma` against limits far tighter than the widths, and `a` only through the minimum
/// total variance it leaves.
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
/// 1e18 hands `total_var` the same domain it already computes in.
public struct PricingSVI has copy, drop, store {
    /// Rolled-down SVI `a`, magnitude at 1e18, sign in `a_is_negative`.
    a_magnitude: u128,
    a_is_negative: bool,
    /// Rolled-down SVI `b`, at 1e18.
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// The raw volatility inputs an order-flow admission read, stored in the order's
/// receipt so its fill can rebuild a `Pricer` at the committed Pyth tick (RP-32:
/// the rebuilt `Pricer` never leaves a package function). Captured by
/// `load_vol` in the trader's transaction and never written by a keeper.
/// Read through BCS; Predict exposes no field getters.
public struct VolSnapshot has copy, drop, store {
    /// Canonical Propbook Pyth source for the market's underlying; commit finds
    /// this feed in each Lazer update.
    pyth_source_id: u32,
    /// The matched Block Scholes spot and forward, narrowed to Predict's width.
    bs_spot: u64,
    bs_forward: u64,
    /// Raw SVI parameters before roll-down, at 1e9.
    svi_a: I64,
    svi_b: u64,
    svi_rho: I64,
    svi_m: I64,
    svi_sigma: u64,
    /// Provider source timestamps of the three reads. The SVI one is also the
    /// roll-down anchor.
    bs_spot_source_timestamp_ms: u64,
    bs_forward_source_timestamp_ms: u64,
    svi_source_timestamp_ms: u64,
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
const EBlockScholesPriceUnavailable: u64 = 12;
const EBlockScholesSVIUnavailable: u64 = 13;
const EBlockScholesMinVarianceInvalid: u64 = 14;
/// A live pricer may not be built from an oracle observation written in this
/// transaction. Named for the observation's provenance (`writer_digest` vs
/// `tx_context::digest()`), not sender identity — not every read of a same-tx
/// write is prohibited (Pyth is checked only on the re-anchor branch).
const EOracleWrittenInThisTransaction: u64 = 15;
const EBlockScholesInputTooWide: u64 = 16;
/// The config selects Pyth for the live forward, but this pricer fell back to the
/// Block Scholes forward because the feed held no usable spot: no observation yet,
/// or one that does not normalize to a positive value. Raised only by the live
/// trades that refuse the fallback (mints, mint quotes, and live redeems); the load
/// itself never aborts on it, so valuation keeps pricing.
#[allow(unused_const)]
const EPythSpotUnavailable: u64 = 17;
/// As `EPythSpotUnavailable`, but the feed held a usable spot older than
/// `pyth_spot_freshness_ms`.
#[allow(unused_const)]
const EPythSpotStale: u64 = 18;
/// A volatility snapshot requires `use_pyth_spot_for_forward`: resolve re-anchors
/// the snapshotted Block Scholes basis on the committed Pyth price.
const EPythForwardRequired: u64 = 19;

/// Predict's private pricing envelope for raw propbook BS inputs. These are not
/// oracle-source validity rules; they only bound the forward/basis and SVI inputs
/// tightly enough that Predict's fixed-point pricing math remains live and
/// meaningful.
macro fun max_pricing_basis_factor(): u64 { 100 }

// Co-designed with the basis factor: forward <= factor * spot (envelope) and
// spot <= u64::max / factor, so the re-anchored forward spot * bs_forward /
// bs_spot <= factor * spot can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / max_pricing_basis_factor!() }

// 1e-5, the floor Block Scholes recommends: SSVI surfaces narrow `sigma` toward
// expiry, so one-minute slices commonly sit below 1e-3. Any positive floor keeps
// the smile root `sqrt((k - m)^2 + sigma^2)` nonzero, so the skew slope's
// `(k - m) / root` division is safe at the smile vertex.
macro fun min_svi_sigma(): u64 { 10_000 }

macro fun max_svi_input(): u64 { 100 * math::float_scaling!() }

// === Public Functions ===

/// Return the current UP digital probability for a typed strike. Public PTB and
/// devInspect reads can compose it with a transaction-local `Pricer`.
public fun up_price(pricer: &Pricer, strike: Strike): u64 {
    let (price, abort_code) = eval_up(&pricer.svi, pricer.forward, strike);
    assert!(price.is_some(), abort_code);
    price.destroy_some()
}

/// Return both boundary probabilities for `(lower, higher]`. Use `probability()`
/// for the combined range probability; absent boundaries are infinite sentinels.
public fun range_price(pricer: &Pricer, lower: Strike, higher: Strike): RangePrice {
    let (price, abort_code) = eval_range(pricer, lower, higher);
    assert!(price.is_some(), abort_code);
    price.destroy_some()
}

// === Getters ===

public fun lower_up(price: &RangePrice): Option<u64> {
    price.lower_up
}

public fun higher_up(price: &RangePrice): Option<u64> {
    price.higher_up
}

/// Return the combined probability, floored at zero if approximated boundary prices invert.
public fun probability(price: &RangePrice): u64 {
    let lower = price.lower_up.get_with_default(math::float_scaling!());
    let higher = price.higher_up.get_with_default(0);
    lower.saturating_sub(higher)
}

// === Public-Package Functions ===

/// Return the expiry market this pricer was loaded for.
public(package) fun expiry_market_id(pricer: &Pricer): ID {
    pricer.expiry_market_id
}

public(package) fun pyth_ts(pricer: &Pricer): u64 {
    pricer.pyth_spot_source_timestamp_ms
}

public(package) fun bs_spot_ts(pricer: &Pricer): u64 {
    pricer.block_scholes_spot_source_timestamp_ms
}

public(package) fun bs_fwd_ts(pricer: &Pricer): u64 {
    pricer.block_scholes_forward_source_timestamp_ms
}

public(package) fun bs_svi_ts(pricer: &Pricer): u64 {
    pricer.block_scholes_svi_source_timestamp_ms
}

/// Freeze a `Pricer` into the flush's storable form — the only `FrozenPricer`
/// constructor, called once per market at the snapshot stage.
public(package) fun into_frozen(pricer: Pricer): FrozenPricer {
    let Pricer {
        expiry_market_id,
        forward,
        svi,
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms,
    } = pricer;
    FrozenPricer {
        expiry_market_id,
        forward,
        svi,
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms,
    }
}

/// Thaw a frozen mark back to a transient `Pricer` for the flush's frozen walk.
/// The result is non-`store`, so it cannot outlive this transaction.
public(package) fun thaw(frozen: &FrozenPricer): Pricer {
    Pricer {
        expiry_market_id: frozen.expiry_market_id,
        forward: frozen.forward,
        svi: frozen.svi,
        pyth_spot_source_timestamp_ms: frozen.pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms: frozen.block_scholes_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms: frozen.block_scholes_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms: frozen.block_scholes_svi_source_timestamp_ms,
    }
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
/// `value * 1e9 < 2^64 * 1e9`, so narrowing to `u128` never truncates.
public(package) fun roll_down(value: u64, remaining_ms: u64, anchor_tte_ms: u64): u128 {
    let scaled =
        (value as u256) * (math::float_scaling!() as u256) * (remaining_ms as u256)
        / (anchor_tte_ms as u256);
    scaled as u128
}

/// Validate the current live pricing boundary and snapshot oracle inputs for
/// one market's repeated quote calculations.
///
/// The supplied feeds must be the current Propbook bindings for the underlying,
/// and the market must be pre-expiry. Block Scholes spot, forward, and SVI inputs
/// must normalize, pass their fixed wall-clock freshness thresholds, and fit the
/// pricing-safe envelope. SVI `a` and `b` are then rolled down from the tuple's provider source
/// timestamp to the current remaining time. Under
/// `use_pyth_spot_for_forward` a fresh positive normalized Pyth spot reanchors the
/// Block Scholes forward basis, and a missing, non-normalizable, or stale Pyth spot
/// is ignored; with it off the Block Scholes forward is always used directly.
/// Valuation accepts a pricer that ignored Pyth that way; live trades do not
/// (`assert_pyth_spot_fresh`).
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
    chk_oracles(
        propbook_registry,
        propbook_underlying_id,
        pyth,
        bs_values,
        bs_svi,
    );
    assert!(clock.timestamp_ms() < expiry, ELivePricingExpired);
    let (_, pricer) = resolve_live(
        config,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
        expiry,
        clock,
        ctx,
    );
    pricer
}

/// Validate the live pricing boundary as `load_live_pricer` does, and also capture
/// the raw volatility inputs a queued order stores. Returns the snapshot and the
/// t₀ `Pricer` the enqueue dry run prices with.
///
/// On top of `load_live_pricer`'s checks it requires the SVI to be at most
/// `svi_max_age_ms` old with a source time before expiry, and requires
/// `use_pyth_spot_for_forward` (`EPythForwardRequired`). The on-chain Pyth spot
/// need not be fresh: a stale or missing one makes the t₀ `Pricer` fall back to
/// the Block Scholes forward.
public(package) fun load_vol(
    config: &PricingConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    svi_max_age_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): (VolSnapshot, Pricer) {
    chk_oracles(
        propbook_registry,
        propbook_underlying_id,
        pyth,
        bs_values,
        bs_svi,
    );
    assert!(clock.timestamp_ms() < expiry, ELivePricingExpired);
    assert!(config.pyth_forward(), EPythForwardRequired);
    let (snapshot, pricer) = resolve_live(
        config,
        pyth,
        bs_values,
        bs_svi,
        expiry_market_id,
        expiry,
        clock,
        ctx,
    );
    // The policy's SVI age bound, on top of the live SVI window. The live window already
    // proved the source is at or before now, and now is before expiry, so the stored
    // roll-down anchor is before expiry without a separate check.
    assert!(
        is_fresh(snapshot.svi_source_timestamp_ms, svi_max_age_ms, clock),
        EBlockScholesSVIStale,
    );
    (snapshot, pricer)
}

/// The Propbook Pyth source a volatility snapshot was captured against, so the
/// order-flow companion reads the matching feed from each Lazer update.
public(package) fun pyth_source_id(snapshot: &VolSnapshot): u32 {
    snapshot.pyth_source_id
}

/// Whether a committed Pyth `spot` is pricing-safe: positive and at most
/// Predict's ceiling, which keeps `pricer_at`'s re-anchored forward inside `u64`.
public(package) fun safe_spot(spot: u64): bool {
    spot > 0 && spot <= max_pricing_spot!()
}

/// Rebuild a `Pricer` from a queued order's snapshot at a committed Pyth tick:
/// the snapshotted Block Scholes basis re-anchored on `spot`, and the raw SVI
/// rolled down to `tick_ms`. The Pyth source timestamp is `generation_ms`; the
/// Block Scholes and SVI timestamps are the snapshot's.
///
/// Never aborts. `none` when `tick_ms >= expiry`, when the forward is zero (or
/// leaves `u64`, which a spot inside the pricing-safe ceiling cannot reach), or
/// when the rolled surface's minimum total variance is not positive. A tick may
/// precede the SVI source time by less than one Pyth tick when the policy delay
/// is shorter than the tick; the roll-down then scales `a` and `b` up by that
/// sliver, as the same linear model gives.
public(package) fun pricer_at(
    snapshot: &VolSnapshot,
    spot: u64,
    generation_ms: u64,
    tick_ms: u64,
    expiry_market_id: ID,
    expiry: u64,
): Option<Pricer> {
    if (tick_ms >= expiry) return option::none();
    // The re-anchoring `resolve_live` applies to a fresh Pyth spot.
    let forward = math::try_mul_div_down(
        spot,
        snapshot.bs_forward,
        snapshot.bs_spot,
    ).destroy_with_default(0);
    if (forward == 0) return option::none();
    let pricer = pricer_of(
        snapshot,
        expiry_market_id,
        expiry,
        forward,
        generation_ms,
        tick_ms,
    );
    if (!has_min_var(&pricer.svi)) return option::none();
    option::some(pricer)
}

/// Non-aborting `up_price`: `none` wherever the digital would abort on a zero
/// forward, a negative SVI inner term, or a non-positive variance; the same bits
/// as `up_price` everywhere else.
#[test_only]
public(package) fun try_up_price(pricer: &Pricer, strike: Strike): Option<u64> {
    let (price, _) = eval_up(&pricer.svi, pricer.forward, strike);
    price
}

/// Non-aborting `range_price`, under the same rule as `try_up_price`. An empty
/// range (`lower >= higher`) is `none` too.
public(package) fun try_range(
    pricer: &Pricer,
    lower: Strike,
    higher: Strike,
): Option<RangePrice> {
    let (price, _) = eval_range(pricer, lower, higher);
    price
}

/// Abort unless the selected Pyth spot was usable and fresh when this pricer was
/// loaded.
///
/// `load_live_pricer` treats a missing, non-normalizable, or stale Pyth spot as a
/// fallback to the Block Scholes forward, which keeps valuation reads
/// (`current_nav`, `live_order_value`, and the flush snapshot) priced through a
/// gap in Pyth updates. Every live trade (mint, mint quote, and live redeem)
/// calls this to refuse the fallback instead: a mint or close moves pool cash at
/// the pricer's mark (a quote refuses what its mint would), and the fallback
/// moves that mark onto the lower-frequency Block Scholes forward. It
/// re-evaluates the load's own selection predicate: the pricer's snapshotted Pyth
/// source timestamp (`0` when no usable observation exists) against the same
/// window and the same transaction clock. While `use_pyth_spot_for_forward` is
/// set, and unless an admin changes `PricingConfig` between the load and this
/// call in one transaction, it passes exactly when the load re-anchored the
/// forward on Pyth. With `use_pyth_spot_for_forward` off no Pyth spot feeds the
/// forward, so there is nothing to reject and it always passes.
#[test_only]
public(package) fun assert_pyth_spot_fresh(pricer: &Pricer, config: &PricingConfig, clock: &Clock) {
    if (!config.pyth_forward()) return;
    assert!(pricer.pyth_spot_source_timestamp_ms > 0, EPythSpotUnavailable);
    assert!(
        is_fresh(
            pricer.pyth_spot_source_timestamp_ms,
            config.pyth_age_ms(),
            clock,
        ),
        EPythSpotStale,
    );
}

/// Validate the canonical Pyth binding and read its normalized spot at exactly
/// `source_timestamp_ms`. The returned option preserves absence so the
/// reference-tick and settlement flows can retain distinct missing-data policies.
public(package) fun exact_spot(
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
): Option<u64> {
    chk_pyth(propbook_registry, propbook_underlying_id, pyth);
    let read = pyth.normalized_spot_at(source_timestamp_ms);
    if (read.is_some()) {
        option::some(read.destroy_some().read_value())
    } else {
        option::none()
    }
}

/// Validate the canonical Block Scholes value-store binding and read its exact spot at
/// `source_timestamp_ms`. Missing, zero, and values outside Predict's settlement width remain
/// unavailable so the permissionless settlement flow can retry without aborting.
public(package) fun bs_spot_at(
    propbook_registry: &OracleRegistry,
    bs_values: &BlockScholesValueStore,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
): Option<u64> {
    let binding = bs_binding(propbook_registry, propbook_underlying_id);
    assert!(
        binding.block_scholes_value_store_id() == bs_values.value_store_id(),
        EWrongBlockScholesValueStore,
    );
    let read = bs_values.spot_at(source_timestamp_ms);
    if (read.is_none()) return option::none();

    let value = read.destroy_some().read_value();
    if (value == 0 || value > (std::u64::max_value!() as u128)) return option::none();
    option::some(value as u64)
}

// === Private Functions ===

/// Validate all supplied feed objects against Propbook's canonical bindings.
fun chk_oracles(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
) {
    chk_pyth(propbook_registry, propbook_underlying_id, pyth);
    let block_scholes_binding = bs_binding(
        propbook_registry,
        propbook_underlying_id,
    );
    assert!(
        block_scholes_binding.block_scholes_value_store_id() == bs_values.value_store_id(),
        EWrongBlockScholesValueStore,
    );
    assert!(
        block_scholes_binding.block_scholes_svi_store_id() == bs_svi.svi_store_id(),
        EWrongBlockScholesSVIStore,
    );
}

fun bs_binding(
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
): BlockScholesStorePair {
    let binding = propbook_registry.propbook_block_scholes_store_pair_for_underlying(
        propbook_underlying_id,
    );
    // Unreachable for a market: creation requires the binding and Propbook never removes it. The
    // unwrap still needs a code, so it shares the value-store mismatch used by both callers.
    assert!(binding.is_some(), EWrongBlockScholesValueStore);
    binding.destroy_some()
}

fun chk_pyth(
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
/// forward is used directly. Returns the validated inputs as a `VolSnapshot`
/// beside the `Pricer` built from them, so a queued order stores exactly what
/// its enqueue dry run priced.
///
/// Aborts if any observation that feeds the returned price was written in this
/// transaction. Pyth is checked only on the re-anchor branch: when the flag is
/// off or the read is stale, the observation is provenance-only and must not
/// trip the guard.
fun resolve_live(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry_market_id: ID,
    expiry: u64,
    clock: &Clock,
    ctx: &TxContext,
): (VolSnapshot, Pricer) {
    let snapshot = read_inputs(config, pyth, bs_values, bs_svi, expiry, clock, ctx);

    // Read whatever the config does with it: the Pyth observation is retained on
    // every `Pricer` for trade-event provenance, including while
    // `use_pyth_spot_for_forward` keeps it out of the forward, and for the
    // live-trade gate (`assert_pyth_spot_fresh`), which reads this timestamp and
    // its `0`.
    let pyth_spot = pyth.normalized_spot();
    let pyth_spot_source_timestamp_ms = if (pyth_spot.is_some()) {
        pyth_spot.borrow().read_source_timestamp_ms()
    } else {
        0
    };
    let mut forward = snapshot.bs_forward;
    if (
        config.pyth_forward()
            && pyth_spot.is_some()
            && is_fresh(
                pyth_spot_source_timestamp_ms,
                config.pyth_age_ms(),
                clock,
            )
    ) {
        let pyth_spot = pyth_spot.destroy_some();
        chk_not_tx(&pyth_spot.read_writer_digest(), ctx);
        let spot = pyth_spot.read_value();
        assert!(spot <= max_pricing_spot!(), EPythSpotInvalid);
        // The re-anchored forward may exceed the input spot ceiling. The basis and
        // spot bounds still guarantee this multiplication and result fit in u64.
        forward = math::mul_div_down(spot, snapshot.bs_forward, snapshot.bs_spot);
    };

    let pricer = pricer_of(
        &snapshot,
        expiry_market_id,
        expiry,
        forward,
        pyth_spot_source_timestamp_ms,
        clock.timestamp_ms(),
    );
    (snapshot, pricer)
}

/// Read and validate the live volatility inputs for `expiry`: the latest Block
/// Scholes forward, the spot at that forward's exact source timestamp, and the SVI
/// tuple. Each read must not have been written in this transaction (RP-24) and must
/// pass its freshness window, and the narrowed set must fit the pricing-safe
/// envelope. The live pricer and the queue's snapshot both validate through here.
fun read_inputs(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry: u64,
    clock: &Clock,
    ctx: &TxContext,
): VolSnapshot {
    let bs_forward_read = bs_values.forward(expiry);
    assert!(bs_forward_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_forward_read = bs_forward_read.destroy_some();
    chk_not_tx(&bs_forward_read.read_writer_digest(), ctx);
    let bs_spot_read = bs_values.recent_spot_at(bs_forward_read.read_source_timestamp_ms());
    assert!(bs_spot_read.is_some(), EBlockScholesPriceUnavailable);
    let bs_spot_read = bs_spot_read.destroy_some();
    chk_not_tx(&bs_spot_read.read_writer_digest(), ctx);
    // Freshness reads the provider's per-update source timestamp: `value_timestamp` for spot and
    // forward, and `svi_timestamp` for SVI. A newer batch carrying an unchanged update cannot
    // refresh pricing. The same source timestamp is snapshotted below, so trade events report the
    // clock pricing validated.
    let block_scholes_spot_source_timestamp_ms = bs_spot_read.read_source_timestamp_ms();
    assert!(
        is_fresh(
            block_scholes_spot_source_timestamp_ms,
            config.bs_age_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_spot = narrow_price(bs_spot_read.read_value());

    let block_scholes_forward_source_timestamp_ms = bs_forward_read.read_source_timestamp_ms();
    assert!(
        is_fresh(
            block_scholes_forward_source_timestamp_ms,
            config.bs_age_ms(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_forward = narrow_price(bs_forward_read.read_value());

    let svi_read = bs_svi.svi(expiry);
    assert!(svi_read.is_some(), EBlockScholesSVIUnavailable);
    let svi_read = svi_read.destroy_some();
    chk_not_tx(&svi_read.read_writer_digest(), ctx);
    // One clock serves every job: the SVI source timestamp the freshness gate accepts is also the
    // roll-down anchor and the snapshot trade events emit, so the parameters, their anchor, and
    // the reported clock always come from the same read. The gate's `source_timestamp <= now` bound
    // plus the pre-expiry check keep the anchor strictly before expiry, so the roll-down's
    // `expiry - anchor` never underflows.
    let block_scholes_svi_source_timestamp_ms = svi_read.read_source_timestamp_ms();
    assert!(
        is_fresh(
            block_scholes_svi_source_timestamp_ms,
            config.svi_age_ms(),
            clock,
        ),
        EBlockScholesSVIStale,
    );
    let raw_svi = narrow_svi(&svi_read.read_value());
    chk_inputs(bs_spot, bs_forward, &raw_svi);

    VolSnapshot {
        // `chk_oracles` bound `pyth` as the underlying's canonical feed, so
        // its source is the registry binding's.
        pyth_source_id: pyth.pyth_source_id(),
        bs_spot,
        bs_forward,
        svi_a: raw_svi.a,
        svi_b: raw_svi.b,
        svi_rho: raw_svi.rho,
        svi_m: raw_svi.m,
        svi_sigma: raw_svi.sigma,
        bs_spot_source_timestamp_ms: block_scholes_spot_source_timestamp_ms,
        bs_forward_source_timestamp_ms: block_scholes_forward_source_timestamp_ms,
        svi_source_timestamp_ms: block_scholes_svi_source_timestamp_ms,
    }
}

fun chk_not_tx(writer_digest: &vector<u8>, ctx: &TxContext) {
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

/// Build a `Pricer` on `forward` from validated inputs, with the SVI rolled down to
/// `priced_at_ms`. The live load prices at the clock and `pricer_at` at a committed
/// tick, so both marks come from one assembly.
fun pricer_of(
    snapshot: &VolSnapshot,
    expiry_market_id: ID,
    expiry: u64,
    forward: u64,
    pyth_spot_source_timestamp_ms: u64,
    priced_at_ms: u64,
): Pricer {
    Pricer {
        expiry_market_id,
        forward,
        svi: roll_svi(snapshot, expiry, priced_at_ms),
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms: snapshot.bs_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms: snapshot.bs_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms: snapshot.svi_source_timestamp_ms,
    }
}

/// Scale the snapshot's raw `a` and `b` by `(expiry - priced_at) / (expiry - svi
/// source)`, the remaining fraction of the time the SVI tuple was calibrated for.
/// `rho`, `m`, and `sigma` are not rolled.
fun roll_svi(snapshot: &VolSnapshot, expiry_ms: u64, priced_at_ms: u64): PricingSVI {
    let remaining_ms = expiry_ms - priced_at_ms;
    let anchor_tte_ms = expiry_ms - snapshot.svi_source_timestamp_ms;
    let a = snapshot.svi_a;
    PricingSVI {
        a_magnitude: roll_down(a.magnitude(), remaining_ms, anchor_tte_ms),
        a_is_negative: a.is_negative(),
        b: roll_down(snapshot.svi_b, remaining_ms, anchor_tte_ms),
        rho: snapshot.svi_rho,
        m: snapshot.svi_m,
        sigma: snapshot.svi_sigma,
    }
}

fun is_fresh(source_timestamp_ms: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    source_timestamp_ms > 0 && source_timestamp_ms <= now && now - source_timestamp_ms <= max_age_ms
}

fun chk_inputs(spot: u64, forward: u64, svi: &RawSVI) {
    assert!(spot > 0 && forward > 0, EBlockScholesInputsInvalid);
    assert!(forward <= max_pricing_spot!(), EBlockScholesInputsInvalid);
    // `ceil(forward / factor) <= spot` enforces `forward <= factor * spot`
    // without an overflowing multiplication.
    assert!(forward.div_ceil(max_pricing_basis_factor!()) <= spot, EBlockScholesInputsInvalid);
    // `a` carries no bound of its own: only total variance has to be positive,
    // which the minimum-variance check below owns, and every downstream use of
    // `a` fits its provider width (`roll_down`, `total_var`).
    assert!(svi.b() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(svi.rho().magnitude() <= math::float_scaling!(), EBlockScholesInputsInvalid);
    assert!(svi.m().magnitude() <= max_svi_input!(), EBlockScholesInputsInvalid);
    assert!(
        svi.sigma() >= min_svi_sigma!() && svi.sigma() <= max_svi_input!(),
        EBlockScholesInputsInvalid,
    );
    chk_min_var(svi);
}

fun chk_min_var(svi: &RawSVI) {
    let min_variance_increment = min_var_inc(svi);
    let a = svi.a();
    // `a + min_variance_increment > 0`, compared rather than summed: `a` reaches
    // `u64::MAX`, where the sum would leave `u64`.
    let min_total_var_positive = if (a.is_negative()) {
        min_variance_increment > a.magnitude()
    } else {
        a.magnitude() > 0 || min_variance_increment > 0
    };
    assert!(min_total_var_positive, EBlockScholesMinVarianceInvalid);
}

// SVI total variance is `a + b * (rho*x + sqrt(x^2 + sigma^2))`, where
// `x = k - m`. This returns the smallest possible non-`a` part over all strikes:
// `b * sigma * sqrt(1 - rho^2)`, or 0 at the `|rho| == 1` boundary.
fun min_var_inc(svi: &RawSVI): u64 {
    math::mul_down(svi.b(), smile_inner(svi.rho(), svi.sigma()))
}

/// Whether a rolled surface's minimum total variance over all strikes is positive,
/// at the 1e18 the rolled `a` and `b` are carried in. The load gate proves this for
/// the raw tuple; `pricer_at` re-proves it after rolling to a tick.
fun has_min_var(svi: &PricingSVI): bool {
    total_var(
        svi.a_magnitude,
        svi.a_is_negative,
        svi.b,
        smile_inner(svi.rho, svi.sigma),
    ).is_some()
}

/// The smallest SVI inner term `rho*x + sqrt(x^2 + sigma^2)` over all `x`:
/// `sigma * sqrt(1 - rho^2)` at 1e9, or 0 at the `|rho| == 1` boundary.
fun smile_inner(rho: I64, sigma: u64): u64 {
    let rho_mag = rho.magnitude();
    if (rho_mag == math::float_scaling!()) return 0;

    let one_minus_rho_squared = math::float_scaling!() - math::mul_down(rho_mag, rho_mag);
    math::mul_down(sigma, math::sqrt_down(one_minus_rho_squared))
}

/// Evaluate `range_price` without aborting: the boundary prices, or `none` with the
/// abort code `range_price` raises for the first failed precondition. The code is
/// meaningless alongside a price.
fun eval_range(
    pricer: &Pricer,
    lower: Strike,
    higher: Strike,
): (Option<RangePrice>, u64) {
    if (lower.value() >= higher.value()) return (option::none(), EInvalidRange);
    let mut lower_up = option::none();
    if (!lower.is_neg_inf()) {
        let (price, abort_code) = eval_up(&pricer.svi, pricer.forward, lower);
        if (price.is_none()) return (option::none(), abort_code);
        lower_up = price;
    };
    let mut higher_up = option::none();
    if (!higher.is_pos_inf()) {
        let (price, abort_code) = eval_up(&pricer.svi, pricer.forward, higher);
        if (price.is_none()) return (option::none(), abort_code);
        higher_up = price;
    };
    (option::some(RangePrice { lower_up, higher_up }), 0)
}

/// Evaluate the adjusted UP digital for `strike` without aborting: the price, or
/// `none` with the abort code `up_price` raises. The code is meaningless alongside
/// a price. The infinite sentinels price before any surface check.
fun eval_up(svi: &PricingSVI, forward: u64, strike: Strike): (Option<u64>, u64) {
    if (strike.is_neg_inf()) return (option::some(math::float_scaling!()), 0);
    if (strike.is_pos_inf()) return (option::some(0), 0);
    evaluate_nd2(svi, forward, strike.value())
}

/// Binary pricing from SVI total variance:
/// - k = ln(strike / forward)
/// - w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))
/// - d2 = -((k + w(k) / 2) / sqrt(w(k)))
/// - price = N(d2) - phi(d2) * w'(k) / (2 * sqrt(w(k)))
///
/// Returns `none` with `EZeroForward`, `ECannotBeNegative`, or `ENonPositiveVariance`
/// where the formula is undefined, so the aborting and non-aborting reads share one
/// evaluation and their bits cannot drift.
fun evaluate_nd2(svi_params: &PricingSVI, forward: u64, strike: u64): (Option<u64>, u64) {
    if (forward == 0) return (option::none(), EZeroForward);

    // Log-moneyness as a DIFFERENCE of logarithms, never as `ln` of a fixed-point
    // ratio. Forming `strike * 1e9 / forward` first destroys exactly the tails it
    // is asked about: the quotient floors to zero once `strike` is a billionth of
    // `forward` and leaves `u64` once it is 1.8e10 times it, and just inside those
    // limits it survives as a handful of raw units carrying tens of percent of
    // truncation error. That is why this used to short-circuit to the digital
    // limits 1 and 0 there — a saturation that is only true when total variance is
    // small, and silently wrong when it is not, on a value the mint's entry
    // probability and the NAV mark both consume.
    //
    // `ln` is defined across the whole positive `u64` domain, so the difference is
    // well-conditioned over every representable pair: `|k| <= 44.4` against the
    // `[-20.72, +23.64]` the ratio form could reach, at a relative error of 1e-7 per
    // term rather than a relative error that grows without bound as the tail
    // deepens. No strike needs a special case, and no surface has to be restricted
    // to keep a shortcut honest.
    let k = math::ln(strike).sub(&math::ln(forward));
    let m = svi_params.m;
    let k_minus_m = k.sub(&m);
    // The smile root `sqrt((k - m)^2 + sigma^2)` is taken from a 1e18 input: both
    // squares are exact `u128` products of 1e9 values, and `sqrt_u128_down` returns
    // the 1e9-scaled root. Squaring at 1e9 instead floors each square to a whole raw
    // unit, which erases `sigma^2` once `sigma` is below ~3.2e-5 and leaves a
    // short-dated smile's vertex with percent-scale error in `w` and `w'`.
    // `|k - m| <= 44.4 + 100` and `sigma <= 100`, so the input stays under 3.1e22
    // and the root fits `u64`.
    let k_minus_m_magnitude = k_minus_m.magnitude() as u128;
    let sigma = svi_params.sigma as u128;
    let sq = math::sqrt_u128_down(k_minus_m_magnitude * k_minus_m_magnitude + sigma * sigma) as u64;
    let sq_i64 = i64::from_u64(sq);

    let rho = svi_params.rho;
    let rho_km = rho.mul_scaled(&k_minus_m);
    let inner = rho_km.add(&sq_i64);
    // Non-negative for |rho| <= 1, and exactly so in fixed point: the floored root
    // is at least `|k - m|`, and the floored `rho * (k - m)` is at most that in
    // magnitude. The check is a backstop.
    if (inner.is_negative()) return (option::none(), ECannotBeNegative);

    let b = svi_params.b;
    let total_var = total_var(
        svi_params.a_magnitude,
        svi_params.a_is_negative,
        b,
        inner.magnitude(),
    );
    if (total_var.is_none()) return (option::none(), ENonPositiveVariance);
    let (sqrt_var, d2) = sqrt_var_d2(total_var.destroy_some(), &k);

    let slope_ratio = k_minus_m.div_scaled(&sq_i64);
    let slope = rho.add(&slope_ratio);
    // `b` is at 1e18 and `slope` at 1e9, so the product comes back down by 1e18
    // to leave `w'` at 1e9. `b <= max_svi_input * 1e9` and `|slope| <= 2e9`
    // (`|rho| <= 1e9` and `|k - m| <= sq`), so the u128 product and the u64
    // narrowing both fit.
    let scale = math::float_scaling!() as u128;
    let w_prime_magnitude = (b * (slope.magnitude() as u128) / (scale * scale)) as u64;
    let nd2 = math::normal_cdf(&d2);
    if (w_prime_magnitude == 0) return (option::some(nd2), 0);

    let correction_magnitude = math::mul_div_down(
        math::normal_pdf(&d2),
        w_prime_magnitude,
        2 * sqrt_var,
    );
    let correction = i64::from_parts(correction_magnitude, slope.is_negative());
    let adjusted = i64::from_u64(nd2).sub(&correction);
    let price = if (adjusted.is_negative()) {
        0
    } else if (adjusted.magnitude() > math::float_scaling!()) {
        math::float_scaling!()
    } else {
        adjusted.magnitude()
    };
    (option::some(price), 0)
}

/// Total variance `w = a + b * inner`, carried at `u128` / 1e18, or `none` when
/// `w <= 0`, which pricing cannot price because it divides by `sqrt(w)`.
///
/// `a_magnitude` and `b` arrive already rolled down and already at 1e18, so the
/// whole variance assembly stays in that domain: narrowing either back to 1e9
/// discards the entire low-variance signal, because a five-minute surface has
/// `w ~ 1e-8` — about ten raw units at 1e9. `inner` is 1e9-scaled, so `b * inner`
/// comes back down by 1e9 to land at 1e18.
fun total_var(a_magnitude: u128, a_is_negative: bool, b: u128, inner: u64): Option<u128> {
    let increment = b * (inner as u128) / (math::float_scaling!() as u128);
    if (a_is_negative) {
        if (increment > a_magnitude) option::some(increment - a_magnitude) else option::none()
    } else if (increment + a_magnitude > 0) {
        option::some(increment + a_magnitude)
    } else {
        option::none()
    }
}

/// `sqrt(w)` and `d2` for a positive total variance `w` at 1e18. `sqrt_u128_down`
/// of a 1e18 value is its 1e9-scaled root, so `sqrt(w)` returns at the scale the
/// rest of the formula reads. Returns `(sqrt(w), d2)`.
fun sqrt_var_d2(total_var: u128, k: &I64): (u64, I64) {
    let scale = math::float_scaling!() as u128;
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

/// Scalar-input view of `total_var` and `sqrt_var_d2` for the unit
/// tests, aborting `ENonPositiveVariance` as a quote does. The d2
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
    let total_var = total_var(a_magnitude, a_is_negative, b, inner);
    assert!(total_var.is_some(), ENonPositiveVariance);
    sqrt_var_d2(total_var.destroy_some(), k)
}

// Field reads for tests; production reads a snapshot through BCS.

#[test_only]
public(package) fun bs_spot(snapshot: &VolSnapshot): u64 { snapshot.bs_spot }

#[test_only]
public(package) fun bs_forward(snapshot: &VolSnapshot): u64 { snapshot.bs_forward }

#[test_only]
public(package) fun svi_a(snapshot: &VolSnapshot): I64 { snapshot.svi_a }

#[test_only]
public(package) fun svi_b(snapshot: &VolSnapshot): u64 { snapshot.svi_b }

#[test_only]
public(package) fun svi_rho(snapshot: &VolSnapshot): I64 { snapshot.svi_rho }

#[test_only]
public(package) fun svi_m(snapshot: &VolSnapshot): I64 { snapshot.svi_m }

#[test_only]
public(package) fun svi_sigma(snapshot: &VolSnapshot): u64 { snapshot.svi_sigma }

#[test_only]
public(package) fun bs_spot_source_timestamp_ms(snapshot: &VolSnapshot): u64 {
    snapshot.bs_spot_source_timestamp_ms
}

#[test_only]
public(package) fun bs_forward_source_timestamp_ms(snapshot: &VolSnapshot): u64 {
    snapshot.bs_forward_source_timestamp_ms
}

#[test_only]
public(package) fun svi_source_timestamp_ms(snapshot: &VolSnapshot): u64 {
    snapshot.svi_source_timestamp_ms
}

/// Build a `VolSnapshot` from its raw fields, in struct order, so unit tests can
/// drive `pricer_at` and the resolve paths without a full oracle setup.
#[test_only]
public fun new_vol_snapshot_for_testing(
    pyth_source_id: u32,
    bs_spot: u64,
    bs_forward: u64,
    svi_a: I64,
    svi_b: u64,
    svi_rho: I64,
    svi_m: I64,
    svi_sigma: u64,
    bs_spot_source_timestamp_ms: u64,
    bs_forward_source_timestamp_ms: u64,
    svi_source_timestamp_ms: u64,
): VolSnapshot {
    VolSnapshot {
        pyth_source_id,
        bs_spot,
        bs_forward,
        svi_a,
        svi_b,
        svi_rho,
        svi_m,
        svi_sigma,
        bs_spot_source_timestamp_ms,
        bs_forward_source_timestamp_ms,
        svi_source_timestamp_ms,
    }
}
