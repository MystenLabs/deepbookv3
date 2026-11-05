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
///
/// A Propbook SVI store signs its parameters at the decimals the admin set on it, `9` or `18`. Every
/// load prices `a` and `b` at 1e18 either way, exactly when the store is at 18. A receipt's
/// snapshot keeps them at 1e9, so an admission at 18 also records the full-precision tuple in its
/// market's SVI cache, a dynamic field this module keeps on the market's UID (`SviKey`), and
/// the fill prices from that entry when it still holds it.
module deepbook_predict::pricing;

use deepbook_predict::{pricing_config::PricingConfig, range_codec::Strike};
use deepbook_predict_math::math as pmath;
use fixed_math::{i64::{Self, I64}, math};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::{BlockScholesStorePair, OracleRegistry}
};
use sui::{clock::Clock, dynamic_field as df, vec_map::{Self, VecMap}};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;

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

/// Block Scholes SVI parameters at Predict's own widths, before roll-down. No longer built: the
/// live read narrows straight into the `VolSnapshot`, which holds the same five fields. Kept
/// because a published struct cannot be removed.
public struct RawSVI has copy, drop {
    a: I64,
    b: u64,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// SVI parameters with `a` and `b` at 1e18: on a `Pricer`, after Predict's remaining-time
/// roll-down; in a market's SVI cache and on the way into `roll_svi`, the raw tuple before it.
///
/// `a` and `b` are carried at **1e18**, not 1e9. The roll-down multiplies both by
/// `remaining_ms / anchor_tte_ms`, and flooring that product at 1e9 discards up to
/// a full raw unit — which a short-dated surface cannot afford, because its whole
/// total variance is only about ten raw units at 1e9. Keeping the rolled values at
/// 1e18 hands `total_var` the same domain it already computes in. A Propbook store at
/// 18 decimals signs the raw `a` and `b` at 1e18 too, so they reach the roll exactly.
public struct PricingSVI has copy, drop, store {
    /// SVI `a`, magnitude at 1e18, sign in `a_is_negative`.
    a_magnitude: u128,
    a_is_negative: bool,
    /// SVI `b`, at 1e18.
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
}

/// Dynamic-field key of a market's SVI cache under the market's UID: a `VecMap` from SVI source time
/// to the full-precision tuple an admission read from a Propbook store at 18 decimals, or a poisoned
/// entry when two different tuples share a time (`keep_svi`). Created by the first such admission,
/// so that trader pays its storage, and capped at `svi_cache_capacity`.
public struct SviKey() has copy, drop, store;

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

// The digital's undefined points. `deepbook_predict_math::math::digital` reports
// these codes and `up_price` / `range_price` abort with them here.
#[test_only]
const EZeroForward: u64 = 0;
#[test_only, allow(unused_const)]
const ECannotBeNegative: u64 = 1;
#[test_only]
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
#[test_only]
const EPythSpotUnavailable: u64 = 17;
/// As `EPythSpotUnavailable`, but the feed held a usable spot older than
/// `pyth_spot_freshness_ms`.
#[test_only]
const EPythSpotStale: u64 = 18;
/// A volatility snapshot requires `use_pyth_spot_for_forward`: resolve re-anchors
/// the snapshotted Block Scholes basis on the committed Pyth price.
const EPythForwardRequired: u64 = 19;

/// Predict's private pricing envelope for raw propbook BS inputs. These are not
/// oracle-source validity rules; they only bound the forward/basis and SVI inputs
/// tightly enough that Predict's fixed-point pricing math remains live and
/// meaningful. The SVI bounds live with the math in
/// `deepbook_predict_math::math::inputs_ok`, which mirrors these two.
macro fun max_pricing_basis_factor(): u64 { 100 }

// Co-designed with the basis factor: forward <= factor * spot (envelope) and
// spot <= u64::max / factor, so the re-anchored forward spot * bs_forward /
// bs_spot <= factor * spot can't overflow u64.
macro fun max_pricing_spot(): u64 { std::u64::max_value!() / max_pricing_basis_factor!() }

/// Largest rise in UP price across ascending strikes that the NAV walk treats as
/// fixed-point dust rather than an inverted surface. `pmath::digital` floors
/// `N(d2)` and the skew correction independently, so where `N(d2)` sits on a tail
/// plateau the difference steps up by one raw unit on a valid, butterfly-free
/// surface. On real and healthy surfaces that one unit is the largest rise measured
/// (the pricer's other rounding is larger per strike, but the true slope outruns
/// it); rises above one appeared only on surfaces near the butterfly-arbitrage
/// boundary, and there they range from 2 to thousands (RP-15's evidence). The bound
/// is the measured unit plus one of headroom: an absorbed rise lowers NAV by at
/// most 2e-9 per unit of the quantity ending at that boundary, plus one raw unit of
/// rounding, and a larger rise fails closed. Re-measure when pricing or the SVI
/// envelope changes.
public(package) macro fun price_monotonicity_tolerance(): u64 { 2 }

/// The higher-precision Propbook SVI decimals: `a` and `b` arrive at the 1e18 they are priced at.
/// Any other value than this and `9` aborts the load.
macro fun precise_svi_decimals(): u8 { 18 }

/// Recent full-precision tuples a market keeps for its fills. An admission reads the latest
/// publication, so the first admission on one inserts its entry and every later insertion is a newer
/// publication. The companion fills or refunds an order by its deadline, at most its delay plus stall
/// timeout after placement (about 15 s at their caps), and the provider publishes about once a
/// second, so about 16 entries arrive between an admission and its fill, a quarter of the capacity.
/// An entry evicted before its fill (publications faster than about four a second) or poisoned by a
/// second tuple (`keep_svi`) prices the order from its 1e9 snapshot, which the load gate checked
/// prices unrolled (`chk_inputs`). The rolled snapshot can still lose an order, by crossing its limit
/// or, on a surface whose minimum variance is a few 1e-18 units, by flooring to zero at the tick.
macro fun svi_cache_capacity(): u64 { 64 }

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
    let (_, pricer, _, _) = resolve_live(
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
/// the raw volatility inputs a queued order stores. Returns the snapshot, the
/// t₀ `Pricer` the enqueue dry run prices with. From a store at 18 decimals it also
/// records the full-precision tuple in the SVI cache on `market_uid` for the order's fill.
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
    market_uid: &mut UID,
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
    assert!(config.pyth_fwd(), EPythForwardRequired);
    let (snapshot, pricer, svi, precise) = resolve_live(
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
    if (precise) keep_svi(market_uid, &snapshot, svi);
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
/// Block Scholes and SVI timestamps are the snapshot's. The fill prices the snapshot's
/// full-precision tuple from the SVI cache on `market_uid` when it still holds one, and
/// otherwise the snapshot's own `a` and `b` scaled to 1e18.
///
/// Never aborts. `none` when `tick_ms >= expiry`, when the forward is zero (or
/// leaves `u64`, which a spot inside the pricing-safe ceiling cannot reach), or
/// when the rolled surface's minimum total variance is not positive. A tick may
/// precede the SVI source time by less than one Pyth tick when the policy delay
/// is shorter than the tick; the roll-down then scales `a` and `b` up by that
/// sliver, as the same linear model gives.
public(package) fun pricer_at(
    snapshot: &VolSnapshot,
    market_uid: &UID,
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
        &svi_for(market_uid, snapshot),
        expiry_market_id,
        expiry,
        forward,
        generation_ms,
        tick_ms,
    );
    if (!var_ok(&pricer.svi)) return option::none();
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
public(package) fun try_range(pricer: &Pricer, lower: Strike, higher: Strike): Option<RangePrice> {
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
    if (!config.pyth_fwd()) return;
    assert!(pricer.pyth_spot_source_timestamp_ms > 0, EPythSpotUnavailable);
    assert!(
        is_fresh(
            pricer.pyth_spot_source_timestamp_ms,
            config.pyth_age(),
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

fun chk_pyth(propbook_registry: &OracleRegistry, propbook_underlying_id: u32, pyth: &PythFeed) {
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
): (VolSnapshot, Pricer, PricingSVI, bool) {
    let (snapshot, svi, precise) = read_inputs(config, pyth, bs_values, bs_svi, expiry, clock, ctx);

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
        config.pyth_fwd()
            && pyth_spot.is_some()
            && is_fresh(
                pyth_spot_source_timestamp_ms,
                config.pyth_age(),
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
        &svi,
        expiry_market_id,
        expiry,
        forward,
        pyth_spot_source_timestamp_ms,
        clock.timestamp_ms(),
    );
    (snapshot, pricer, svi, precise)
}

/// Read and validate the live volatility inputs for `expiry`: the latest Block
/// Scholes forward, the spot at that forward's exact source timestamp, and the SVI
/// tuple. Each read must not have been written in this transaction (RP-24) and must
/// pass its freshness window, and the narrowed set must fit the pricing-safe
/// envelope. The live pricer and the queue's snapshot both validate through here.
/// Also returns the raw tuple with `a` and `b` at 1e18, and whether the store signed
/// them there (18 decimals) rather than at 1e9.
fun read_inputs(
    config: &PricingConfig,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    expiry: u64,
    clock: &Clock,
    ctx: &TxContext,
): (VolSnapshot, PricingSVI, bool) {
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
            config.bs_age(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_spot = narrow_input(bs_spot_read.read_value(), false);

    let block_scholes_forward_source_timestamp_ms = bs_forward_read.read_source_timestamp_ms();
    assert!(
        is_fresh(
            block_scholes_forward_source_timestamp_ms,
            config.bs_age(),
            clock,
        ),
        EBlockScholesPriceStale,
    );
    let bs_forward = narrow_input(bs_forward_read.read_value(), false);

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
            config.svi_age(),
            clock,
        ),
        EBlockScholesSVIStale,
    );
    let decimals = bs_svi.svi_decimals();
    assert!(decimals == 9 || decimals == precise_svi_decimals!(), EBlockScholesInputsInvalid);
    let precise = decimals != 9;
    let params = svi_read.read_value();
    // The provider carries every parameter at 128 bits; Predict prices them at 64, so the
    // narrowing happens once here and every bound reads these widths. A value too large for them
    // aborts `EBlockScholesInputTooWide` before the cast, and `chk_inputs` then checks `b`, `rho`,
    // `m`, and `sigma` against limits far tighter than the widths, and `a` only through the
    // minimum total variance it leaves. An 18-decimal tuple rounds every parameter half up to
    // 1e9: `rho`, `m`, and `sigma` keep enough digits there (a `sigma` at the 1e-7 floor still has
    // a hundred raw units), and `a` and `b` are taken at 1e18 below, because on a final-seconds
    // slice they are only a raw unit or two at 1e9.
    let snapshot = VolSnapshot {
        // `chk_oracles` bound `pyth` as the underlying's canonical feed, so
        // its source is the registry binding's.
        pyth_source_id: pyth.pyth_source_id(),
        bs_spot,
        bs_forward,
        svi_a: i64::from_parts(
            narrow_input(params.svi_a_magnitude(), precise),
            params.svi_a_is_negative(),
        ),
        svi_b: narrow_input(params.svi_b(), precise),
        svi_rho: i64::from_parts(
            narrow_input(params.svi_rho_magnitude(), precise),
            params.svi_rho_is_negative(),
        ),
        svi_m: i64::from_parts(
            narrow_input(params.svi_m_magnitude(), precise),
            params.svi_m_is_negative(),
        ),
        svi_sigma: narrow_input(params.svi_sigma(), precise),
        bs_spot_source_timestamp_ms: block_scholes_spot_source_timestamp_ms,
        bs_forward_source_timestamp_ms: block_scholes_forward_source_timestamp_ms,
        svi_source_timestamp_ms: block_scholes_svi_source_timestamp_ms,
    };
    let own = own_svi(&snapshot);
    let mut svi = own;
    if (precise) {
        svi.a_magnitude = params.svi_a_magnitude();
        svi.a_is_negative = params.svi_a_is_negative();
        svi.b = params.svi_b();
    };
    chk_inputs(&snapshot, &own, &svi, precise);
    (snapshot, svi, precise)
}

fun chk_not_tx(writer_digest: &vector<u8>, ctx: &TxContext) {
    assert!(writer_digest != ctx.digest(), EOracleWrittenInThisTransaction);
}

/// A snapshot's tuple with its own `a` and `b` at 1e18, exactly.
fun own_svi(snapshot: &VolSnapshot): PricingSVI {
    let scale = math::float_scaling!() as u128;
    PricingSVI {
        a_magnitude: (snapshot.svi_a.magnitude() as u128) * scale,
        a_is_negative: snapshot.svi_a.is_negative(),
        b: (snapshot.svi_b as u128) * scale,
        rho: snapshot.svi_rho,
        m: snapshot.svi_m,
        sigma: snapshot.svi_sigma,
    }
}

/// The tuple a fill prices `snapshot` with: its market's cached full-precision tuple for the
/// snapshot's SVI source time when that tuple is the snapshot's whole calibration, its `a` and `b`
/// rounding to the snapshot's and its `rho`, `m`, and `sigma` equal to them, and otherwise the
/// snapshot's own. The rounded `a` takes its sign through `i64::from_parts` exactly as the
/// snapshot's did, so a slightly negative `a` that rounds to zero still matches. A cached tuple
/// narrowed at its admission, so the rounding cannot abort, and it passed the load gate, so a match
/// prices wherever the snapshot does.
fun svi_for(market_uid: &UID, snapshot: &VolSnapshot): PricingSVI {
    let own = own_svi(snapshot);
    if (!market_uid.exists_(SviKey())) return own;
    let cache: &VecMap<u64, PricingSVI> = market_uid.borrow(SviKey());
    let cached = cache.try_get(&snapshot.svi_source_timestamp_ms);
    if (cached.is_some()) {
        let full = cached.destroy_some();
        let scale = math::float_scaling!() as u128;
        let a = i64::from_parts(narrow_input(full.a_magnitude, true), full.a_is_negative);
        let mut rounded = full;
        rounded.a_magnitude = (a.magnitude() as u128) * scale;
        rounded.a_is_negative = a.is_negative();
        rounded.b = (narrow_input(full.b, true) as u128) * scale;
        if (rounded == own) return full;
    };
    own
}

/// Record the full-precision tuple an admission read for `snapshot` under its SVI source time,
/// creating the market's SVI cache on first use and evicting the oldest past capacity. A source
/// time that arrives with a second, different tuple (an SVI model switch can bring two calibrations
/// published at one time) is held by neither: its entry's `sigma` goes to zero, below the envelope's
/// floor, so it matches no snapshot and every order on that time prices from its own 1e9 values.
fun keep_svi(market_uid: &mut UID, snapshot: &VolSnapshot, svi: PricingSVI) {
    if (!market_uid.exists_(SviKey())) {
        market_uid.add(SviKey(), vec_map::empty<u64, PricingSVI>());
    };
    let cache: &mut VecMap<u64, PricingSVI> = market_uid.borrow_mut(SviKey());
    let source_ms = snapshot.svi_source_timestamp_ms;
    let held = cache.try_get(&source_ms);
    if (held.is_some()) {
        if (held.destroy_some() != svi) cache.get_mut(&source_ms).sigma = 0;
        return
    };
    cache.insert(source_ms, svi);
    if (cache.length() > svi_cache_capacity!()) {
        cache.remove_entry_by_idx(0);
    };
}

/// One Block Scholes input narrowed to Predict's pricing width with the provider-width error shared
/// by every Block Scholes input: as stored, or for a `precise` (18-decimal) input divided by 1e9 and
/// rounded half up. The rounding is quotient plus carry, so no addition can leave `u128`.
fun narrow_input(value: u128, precise: bool): u64 {
    let scale = if (precise) math::float_scaling!() as u128 else 1;
    let value = value / scale + if (value % scale > (scale - 1) / 2) 1 else 0;
    assert!(value <= (std::u64::max_value!() as u128), EBlockScholesInputTooWide);
    value as u64
}

/// Build a `Pricer` on `forward` from validated inputs, with the SVI rolled down to
/// `priced_at_ms`. The live load prices at the clock and `pricer_at` at a committed
/// tick, so both marks come from one assembly.
fun pricer_of(
    snapshot: &VolSnapshot,
    svi: &PricingSVI,
    expiry_market_id: ID,
    expiry: u64,
    forward: u64,
    pyth_spot_source_timestamp_ms: u64,
    priced_at_ms: u64,
): Pricer {
    Pricer {
        expiry_market_id,
        forward,
        svi: roll_svi(svi, expiry, priced_at_ms, snapshot.svi_source_timestamp_ms),
        pyth_spot_source_timestamp_ms,
        block_scholes_spot_source_timestamp_ms: snapshot.bs_spot_source_timestamp_ms,
        block_scholes_forward_source_timestamp_ms: snapshot.bs_forward_source_timestamp_ms,
        block_scholes_svi_source_timestamp_ms: snapshot.svi_source_timestamp_ms,
    }
}

/// Scale the raw tuple's 1e18 `a` and `b` by `(expiry - priced_at) / (expiry - svi
/// source)`, the remaining fraction of the time the SVI tuple was calibrated for.
/// `rho`, `m`, and `sigma` are not rolled. On a snapshot's own `a` and `b` this is
/// `pmath::roll_down` exactly, the same product over the same divisor, so a 9-decimal
/// store prices as it always has. A narrowed tuple keeps `a` and `b` below `2^64 * 1e9`,
/// so the result fits `u128` even when a tick sits a sliver before the source time.
fun roll_svi(svi: &PricingSVI, expiry_ms: u64, priced_at_ms: u64, source_ms: u64): PricingSVI {
    let remaining = (expiry_ms - priced_at_ms) as u256;
    let anchor = (expiry_ms - source_ms) as u256;
    let mut rolled = *svi;
    rolled.a_magnitude = ((svi.a_magnitude as u256) * remaining / anchor) as u128;
    rolled.b = ((svi.b as u256) * remaining / anchor) as u128;
    rolled
}

fun is_fresh(source_timestamp_ms: u64, max_age_ms: u64, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    source_timestamp_ms > 0 && source_timestamp_ms <= now && now - source_timestamp_ms <= max_age_ms
}

/// Abort unless a snapshot's narrowed Block Scholes inputs fit Predict's pricing-safe
/// envelope (`EBlockScholesInputsInvalid`) and the raw SVI tuple's minimum total
/// variance is positive (`EBlockScholesMinVarianceInvalid`). A 9-decimal tuple's
/// minimum is checked at 1e9 with its floors, as it always was. A `precise` one's is
/// checked at 1e18, where the increment `b·sigma·sqrt(1 − rho²)` is not floored to a
/// raw unit, so a final-seconds slice whose `a` rounds to zero still shows its positive
/// minimum, and on both forms: `svi`, the stored `a` and `b` every live price uses, and
/// `own`, the snapshot's rounded ones, so an admitted snapshot also prices without its
/// full-precision tuple, before roll-down, for a fill that no longer finds that tuple
/// in the market's SVI cache.
fun chk_inputs(snapshot: &VolSnapshot, own: &PricingSVI, svi: &PricingSVI, precise: bool) {
    assert!(
        pmath::inputs_ok(
            snapshot.bs_spot,
            snapshot.bs_forward,
            snapshot.svi_b,
            snapshot.svi_rho,
            snapshot.svi_m,
            snapshot.svi_sigma,
        ),
        EBlockScholesInputsInvalid,
    );
    assert!(
        if (precise) var_ok(own) && var_ok(svi)
        else
            pmath::raw_var_ok(snapshot.svi_a, snapshot.svi_b, snapshot.svi_rho, snapshot.svi_sigma),
        EBlockScholesMinVarianceInvalid,
    );
}

/// Whether a tuple's minimum total variance over all strikes is positive at the 1e18 its `a` and
/// `b` are carried in.
fun var_ok(svi: &PricingSVI): bool {
    pmath::var_positive(svi.a_magnitude, svi.a_is_negative, svi.b, svi.rho, svi.sigma)
}

/// Evaluate `range_price` without aborting: the boundary prices, or `none` with the
/// abort code `range_price` raises for the first failed precondition. The code is
/// meaningless alongside a price.
fun eval_range(pricer: &Pricer, lower: Strike, higher: Strike): (Option<RangePrice>, u64) {
    if (lower.value() >= higher.value()) return (option::none(), EInvalidRange);
    let mut lower_up = option::none();
    if (!lower.is_ninf()) {
        let (price, abort_code) = eval_up(&pricer.svi, pricer.forward, lower);
        if (price.is_none()) return (option::none(), abort_code);
        lower_up = price;
    };
    let mut higher_up = option::none();
    if (!higher.is_pinf()) {
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
    if (strike.is_ninf()) return (option::some(math::float_scaling!()), 0);
    if (strike.is_pinf()) return (option::some(0), 0);
    pmath::digital(
        svi.a_magnitude,
        svi.a_is_negative,
        svi.b,
        svi.rho,
        svi.m,
        svi.sigma,
        forward,
        strike.value(),
    )
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
    let total_var = pmath::total_var_for_testing(a_magnitude, a_is_negative, b, inner);
    assert!(total_var.is_some(), ENonPositiveVariance);
    pmath::sqrt_var_d2_for_testing(total_var.destroy_some(), k)
}

/// The library roll-down, for the unit tests that pin it.
#[test_only]
public(package) fun roll_down(value: u64, remaining_ms: u64, anchor_tte_ms: u64): u128 {
    pmath::roll_down(value, remaining_ms, anchor_tte_ms)
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

#[test_only]
public(package) fun keep_svi_for_testing(
    market_uid: &mut UID,
    snapshot: &VolSnapshot,
    svi: PricingSVI,
) {
    keep_svi(market_uid, snapshot, svi)
}

#[test_only]
public(package) fun svi_for_testing(market_uid: &UID, snapshot: &VolSnapshot): PricingSVI {
    svi_for(market_uid, snapshot)
}

#[test_only]
public(package) fun svi_cache_length_for_testing(market_uid: &UID): u64 {
    let cache: &VecMap<u64, PricingSVI> = market_uid.borrow(SviKey());
    cache.length()
}

#[test_only]
public fun new_pricing_svi_for_testing(
    a_magnitude: u128,
    a_is_negative: bool,
    b: u128,
    rho: I64,
    m: I64,
    sigma: u64,
): PricingSVI {
    PricingSVI { a_magnitude, a_is_negative, b, rho, m, sigma }
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
