// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pricing for Predict markets.
///
/// This module computes SVI-adjusted digital probabilities from Block Scholes
/// inputs and a Pyth spot that arrive inline, signed, in the transaction that
/// needs them. `snap_v2` turns a `block_scholes::BsVol` into the `VolSnapshot` a
/// receipt or the flush stores, and `pricer_at` builds a `Pricer` from a snapshot
/// at a committed Pyth tick: the Block Scholes basis re-anchored on the Pyth spot,
/// and the SVI rolled down to the tick. It returns `none` where the inputs leave
/// Predict's pricing envelope. The `try_*` reads price exactly as `up_price` and
/// `range_price` do, and return `none` where those abort, so an order-flow fill
/// never aborts on a surface.
///
/// Block Scholes signs SVI at `9` or `18` decimals. Pricing carries `a` and `b`
/// at 1e18 either way, exactly when they were signed at 18. A snapshot keeps
/// them at 1e9, so a snapshot from 18 decimals also records the full-precision
/// tuple in its market's SVI cache, a dynamic field this module keeps on the
/// market's UID (`SviKey`), and pricing reads that entry when it still holds it.
///
/// Earlier package versions read Propbook's stores here. Version 6 removed those
/// readers.
module deepbook_predict::pricing;

use deepbook_predict::range_codec::Strike;
use deepbook_predict_math::{block_scholes::BsVol, math as pmath};
use fixed_math::{i64::{Self, I64}, math};
use sui::{dynamic_field as df, vec_map::{Self, VecMap}};

#[test_only]
use deepbook_predict::pricing_config::PricingConfig;
#[test_only]
use sui::clock::Clock;

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists as UID.exists_;

/// Validated live oracle inputs bound to one expiry market.
///
/// `Pricer` has NO `store` ability, by design: a non-`store` value cannot enter
/// an object or a dynamic field, so it cannot survive the transaction that
/// built it. Only `pricer_at` builds one, inside a fill or the flush's snapshot
/// stage, and package-only `thaw` rebuilds one solely inside the flush's
/// `snapshot_nav`, and no public function returns one. The non-`store` ability is
/// therefore the structural guarantee that every fund-moving trade prices against
/// a mark built in its OWN transaction — a persisted, stale-favorable mark can
/// never reach a trade. The full-pool flush, which must carry one mark per market
/// across transactions, uses the separate `FrozenPricer` below (which no trade
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
/// to the full-precision tuple of an 18-decimal snapshot (`snap_v2`), or a poisoned entry when two
/// different tuples share a time (`keep_svi`). Created by the first such snapshot and capped at
/// `svi_cache_capacity`.
public struct SviKey() has copy, drop, store;

/// The raw volatility inputs an order prices from, stored in its receipt so its
/// fill can rebuild a `Pricer` at the committed Pyth tick (RP-32: the rebuilt
/// `Pricer` never leaves a package function). Admission records only the Pyth
/// feed, and `commit_v2` writes the Block Scholes inputs for the order's τ. Orders
/// admitted by package versions before 6 captured them at placement instead.
/// Read through BCS; Predict exposes no field getters.
public struct VolSnapshot has copy, drop, store {
    /// The market's Pyth Lazer feed, from its oracle binding at admission. Commit
    /// finds this feed in each Lazer update.
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

/// The Pyth Lazer feed a volatility snapshot names, so the order-flow companion
/// reads the matching feed from each Lazer update.
public(package) fun pyth_source_id(snapshot: &VolSnapshot): u32 {
    snapshot.pyth_source_id
}

/// The receipt snapshot of an admission: only the Pyth feed, with no Block
/// Scholes inputs until `commit_v2` writes them.
public(package) fun feed_snap(pyth_source_id: u32): VolSnapshot {
    let zero = i64::zero();
    VolSnapshot {
        pyth_source_id,
        bs_spot: 0,
        bs_forward: 0,
        svi_a: zero,
        svi_b: 0,
        svi_rho: zero,
        svi_m: zero,
        svi_sigma: 0,
        bs_spot_source_timestamp_ms: 0,
        bs_forward_source_timestamp_ms: 0,
        svi_source_timestamp_ms: 0,
    }
}

/// The `VolSnapshot` a committed order or a flush mark prices from: `vol`'s spot,
/// forward, and SVI, with `a` and `b` rounded half up to 1e9, and the Pyth feed
/// `pyth_source_id`. A tuple signed at 18 decimals is also kept at full precision
/// in the SVI cache on `market_uid` (`keep_svi`), which `pricer_at` prices from.
public(package) fun snap_v2(vol: &BsVol, pyth_source_id: u32, market_uid: &mut UID): VolSnapshot {
    let snapshot = VolSnapshot {
        pyth_source_id,
        bs_spot: vol.spot(),
        bs_forward: vol.forward(),
        svi_a: i64::from_parts(narrow_input(vol.a_magnitude(), true), vol.a_is_negative()),
        svi_b: narrow_input(vol.b(), true),
        svi_rho: vol.rho(),
        svi_m: vol.m(),
        svi_sigma: vol.sigma(),
        bs_spot_source_timestamp_ms: vol.value_ms(),
        bs_forward_source_timestamp_ms: vol.value_ms(),
        svi_source_timestamp_ms: vol.svi_ms(),
    };
    if (vol.svi_decimals() == 18) {
        keep_svi(
            market_uid,
            &snapshot,
            PricingSVI {
                a_magnitude: vol.a_magnitude(),
                a_is_negative: vol.a_is_negative(),
                b: vol.b(),
                rho: vol.rho(),
                m: vol.m(),
                sigma: vol.sigma(),
            },
        );
    };
    snapshot
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
/// Never aborts. `none` when `tick_ms >= expiry`, when the snapshot's inputs
/// leave Predict's pricing-safe envelope (`pmath::inputs_ok`: a positive spot and
/// forward, the basis and SVI bounds), when the forward is zero (or leaves `u64`,
/// which a spot inside the pricing-safe ceiling cannot reach), or when the rolled
/// surface's minimum total variance is not positive. A snapshot with no Block
/// Scholes inputs has a zero spot, so it never prices. A tick may precede the SVI
/// source time by less than one Pyth tick only on a snapshot admitted before
/// version 6. The roll-down then scales `a` and `b` up by that sliver, as the same
/// linear model gives.
public(package) fun pricer_at(
    snapshot: &VolSnapshot,
    market_uid: &UID,
    spot: u64,
    generation_ms: u64,
    tick_ms: u64,
    expiry_market_id: ID,
    expiry: u64,
): Option<Pricer> {
    if (
        tick_ms >= expiry
            || !pmath::inputs_ok(
                snapshot.bs_spot,
                snapshot.bs_forward,
                snapshot.svi_b,
                snapshot.svi_rho,
                snapshot.svi_m,
                snapshot.svi_sigma,
            )
    ) return option::none();
    // The Block Scholes basis, re-anchored on the committed Pyth spot.
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
/// The live pricer of earlier versions treated a missing, non-normalizable, or
/// stale Pyth spot as a fallback to the Block Scholes forward. Every live trade (mint, mint quote, and live redeem)
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
    let source_ms = pricer.pyth_spot_source_timestamp_ms;
    let now = clock.timestamp_ms();
    assert!(source_ms <= now && now - source_ms <= config.pyth_age(), EPythSpotStale);
}

// === Private Functions ===

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
