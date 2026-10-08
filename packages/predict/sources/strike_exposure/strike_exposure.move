// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local exposure book for one expiry market.
///
/// This module interprets `Order` terms against the expiry's `tick_size`,
/// recovering raw strikes from order ticks only at the pricing/settlement boundary.
/// It owns the payout-liability view of the active contracts used for cash backing.
/// Order accounting is static and needs no clock: a winning order pays its full
/// quantity. Expiry-market cash custody, account positions, and payout movement
/// stay outside this module.
module deepbook_predict::strike_exposure;

use deepbook_predict::{
    constants,
    order::{Self, Order},
    pricing::{Pricer, RangePrice},
    range_codec,
    strike_exposure_config::StrikeExposureConfig,
    strike_payout_tree::{Self, StrikePayoutTree}
};
use deepbook_predict_math::math as pmath;
use fixed_math::math;
use sui::vec_map::VecMap;

#[allow(unused_const)]
const EInvalidCloseQuantity: u64 = 0;
#[allow(unused_const)]
const EInvalidAdmissionTick: u64 = 1;
const EInvalidReferenceTick: u64 = 2;
const EReferenceTickAlreadySet: u64 = 3;
const ETermsExposureMismatch: u64 = 4;
#[allow(unused_const)]
const EMintQuantityBelowMin: u64 = 5;
const EInvalidInventoryImpactScale: u64 = 6;

/// Exposure lifecycle state for one expiry market.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Raw-price-per-tick conversion factor; `raw_strike = tick * tick_size`.
    tick_size: u64,
    /// Coarser raw-price step that new finite mint boundaries must align to.
    admission_tick_size: u64,
    /// Exact Propbook Pyth source timestamp used to derive the reference tick.
    reference_tick_source_timestamp_ms: u64,
    /// Reference fine-grid tick that may bypass the coarser admission grid once set.
    reference_tick: Option<u64>,
    /// Snapshotted exposure and fee policy for this expiry.
    config: StrikeExposureConfig,
    /// Immutable USDC scale for the inventory-impact curve. This is the
    /// expiry's snapshotted maximum pool allocation: a risk-capacity parameter,
    /// not live pool equity, so LP flows cannot reprice an existing book.
    inventory_impact_scale: u64,
    next_order_sequence: u64,
    /// Terminal settlement price once the exposure has entered its settled phase.
    settlement_price: Option<u64>,
    /// Remaining payout liability in the settled phase.
    settled_payout_liability: u64,
    /// Sparse payout tree for live cash backing and settled liability.
    payout: StrikePayoutTree,
}

/// One prospective mint range, priced and policy-checked once, with the pre-mint
/// payout-tree reads its inventory-impact charge is evaluated against. Built only
/// by `quote_mint_range` and consumed by value in `mint_terms`, so a quantity
/// search evaluates every candidate against one price and one tree read, and the
/// terms it admits carry exactly that range and price. The book reads are taken
/// only when inventory impact is enabled; a disabled market leaves them zero.
public struct MintRange has drop {
    expiry_market_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    price: RangePrice,
    /// Pre-mint point-max and total live payout.
    max_payout: u64,
    total_payout: u64,
    /// Pre-mint payout peak inside `(lower_tick, higher_tick]`.
    range_max_payout: u64,
}

/// Pure mint terms for one prospective live mint: the priced tick range and
/// quantity, plus the admission results they produced. Built only by
/// `mint_terms` and consumed by value in `allocate_mint_order`, so one
/// terms value backs at most one allocation and allocation can never see inputs
/// that differ from the priced ones. Terms carry the pricing exposure's market
/// identity; allocation asserts it, so terms cannot cross exposure books.
public struct MintTerms has drop {
    expiry_market_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    price: RangePrice,
    premium: u64,
    /// Separate inventory-impact charge, sampled against the pre-mint book.
    inventory_impact_charge: u64,
}

/// Compute-once terms for one prospective live close. Built only by
/// `quote_live_close` and consumed by value in `apply_close`, so one terms
/// value backs at most one mutation. The survivor's quantity is derived by
/// conservation (`total - removed`) at the mutation.
public struct LiveCloseTerms has drop {
    expiry_market_id: ID,
    order: Order,
    close_quantity: u64,
    redeem_amount: u64,
    price: RangePrice,
    /// Separate inventory-impact rebate, sampled against the pre-close book.
    inventory_impact_rebate: u64,
}

public(package) fun range_px(range: &MintRange): &RangePrice {
    &range.price
}

/// Premium for minting `quantity` over `range`: the expression mint admission
/// charges, without admission's policy asserts, for quantity searches.
public(package) fun range_prem(range: &MintRange, quantity: u64): u64 {
    math::mul_down(range.price.probability(), quantity)
}

#[test_only]
public(package) fun entry_probability(terms: &MintTerms): u64 {
    terms.price.probability()
}

public(package) fun premium(terms: &MintTerms): u64 {
    terms.premium
}

public(package) fun quantity(terms: &MintTerms): u64 {
    terms.quantity
}

public(package) fun inventory_impact_charge(terms: &MintTerms): u64 {
    terms.inventory_impact_charge
}

public(package) fun mint_price(terms: &MintTerms): &RangePrice {
    &terms.price
}

public(package) fun redeem_amt(terms: &LiveCloseTerms): u64 {
    terms.redeem_amount
}

public(package) fun close_prob(terms: &LiveCloseTerms): u64 {
    terms.price.probability()
}

public(package) fun rebate(terms: &LiveCloseTerms): u64 {
    terms.inventory_impact_rebate
}

public(package) fun close_price(terms: &LiveCloseTerms): &RangePrice {
    &terms.price
}

/// Return the recorded settlement price. Aborts while the exposure is live.
public(package) fun settlement_price(exposure: &StrikeExposure): u64 {
    exposure.settlement_price.destroy_some()
}

/// Return whether this exposure has entered its settled phase.
public(package) fun is_settled(exposure: &StrikeExposure): bool {
    exposure.settlement_price.is_some()
}

/// Return the recorded settlement price, or `none` while the exposure is live.
public(package) fun try_settlement_price(exposure: &StrikeExposure): Option<u64> {
    exposure.settlement_price
}

/// Return the buffered live reserve or remaining settled payout liability.
///
/// Live reserve is the settlement floor (max single-point payout) plus a
/// configured fraction of the gap between summed and maximum point payout.
public(package) fun payout_liability(exposure: &StrikeExposure): u64 {
    if (exposure.is_settled()) {
        exposure.settled_payout_liability
    } else {
        let (max_payout, total_payout) = exposure.payout.rsv_terms();
        exposure.liab_of(max_payout, total_payout)
    }
}

/// Return the live marked liability: every open contract's range-probability
/// value, priced once per boundary by the payout tree's in-order walk. Every order
/// is worth `quantity * P(range)` live, so no per-order correction is needed. The
/// aggregate is netted per boundary rather than per order, so it can differ from
/// the per-order sum by boundary rounding; it is clamped at zero once, in the walk.
public(package) fun marked_liab(exposure: &StrikeExposure, pricer: &Pricer): u64 {
    exposure.payout.walk_linear(pricer, exposure.tick_size)
}

/// Return the marked liability the book held at generation `snapshot_seq`'s
/// valuation snapshot: the same walk as `marked_liab` over the terms
/// the payout tree captured at that instant. Same per-boundary rounding,
/// clamping, and monotonicity contract over the snapshot-instant book.
public(package) fun frozen_liab(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    snapshot_seq: u64,
): u64 {
    exposure.payout.walk_frozen(pricer, exposure.tick_size, snapshot_seq)
}

/// Begin holding generation `snapshot_seq`'s book snapshot for the frozen walk.
public(package) fun start_snap(exposure: &mut StrikeExposure, snapshot_seq: u64) {
    exposure.payout.snap_on(snapshot_seq);
}

/// Discard a stale (aborted-flush) snapshot without walking the tree.
public(package) fun stop_snap(exposure: &mut StrikeExposure) {
    exposure.payout.snap_off();
}

/// Consume the snapshot after its frozen walk was read, removing retained husks
/// that no waiting order pins.
public(package) fun drop_snap(exposure: &mut StrikeExposure, pins: &VecMap<u64, u64>) {
    exposure.payout.snap_done(pins);
}

/// Return one live order's full-close range value without consulting book state.
public(package) fun live_order_value(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
): u64 {
    math::mul_down(exposure.order_px(pricer, order).probability(), order.quantity())
}

/// Return one settled order's full terminal payout.
public(package) fun settled_order_payout(exposure: &StrikeExposure, order: &Order): u64 {
    let settlement_price = exposure.settlement_price();
    if (
        range_codec::in_range(
            order.lower_tick(),
            order.higher_tick(),
            settlement_price,
            exposure.tick_size,
        )
    ) {
        order.quantity()
    } else {
        0
    }
}

/// Return the backing-buffer lambda snapshotted for this exposure book.
public(package) fun backing_buffer_lambda(exposure: &StrikeExposure): u64 {
    exposure.config.backing_buffer_lambda()
}

public(package) fun expiry_fee_window_ms(exposure: &StrikeExposure): u64 {
    exposure.config.expiry_fee_window_ms()
}

public(package) fun expiry_fee_max_multiplier(exposure: &StrikeExposure): u64 {
    exposure.config.expiry_fee_max_multiplier()
}

public(package) fun inventory_impact_max_rate(exposure: &StrikeExposure): u64 {
    exposure.config.inventory_impact_max_rate()
}

public(package) fun inventory_impact_scale(exposure: &StrikeExposure): u64 {
    exposure.inventory_impact_scale
}

public(package) fun tick_size(exposure: &StrikeExposure): u64 {
    exposure.tick_size
}

public(package) fun admission_tick_size(exposure: &StrikeExposure): u64 {
    exposure.admission_tick_size
}

public(package) fun reference_tick_source_timestamp_ms(exposure: &StrikeExposure): u64 {
    exposure.reference_tick_source_timestamp_ms
}

public(package) fun reference_tick(exposure: &StrikeExposure): Option<u64> {
    exposure.reference_tick
}

/// Return the payout tree's node count, pinned zero nodes included.
public(package) fun tree_nodes(exposure: &StrikeExposure): u64 {
    exposure.payout.node_count()
}

/// Return the snapshotted minimum entry probability. A queued mint's cash need
/// is bounded with it, since every fill pays at least this per contract.
public(package) fun min_prob(exposure: &StrikeExposure): u64 {
    exposure.config.min_prob()
}

/// Whether both finite boundaries of a mint range already exist as tree nodes.
public(package) fun nodes_exist(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
): bool {
    exposure.payout.has_nodes(lower_tick, higher_tick)
}

/// Payout liability after a prospective mint of `quantity` over `range`, from
/// the pre-mint book reads the range sampled. Resolve's no-cash check compares
/// it before anything moves; on a live exposure it equals what
/// `payout_liability` (and so `chk_backed`) reads after
/// `allocate` applies the same terms to the same book.
///
/// `range` must come from `try_mint_rng`, which always samples the
/// reads. `quote_mint_range` skips them while inventory impact is off, and its
/// zeros would understate the result. The point max after the mint is the
/// larger of the old max and the candidate's own range peak plus `quantity`,
/// since only points inside the range move.
public(package) fun liab_minted(exposure: &StrikeExposure, range: &MintRange, quantity: u64): u64 {
    exposure.liab_of(
        range.max_payout.max(range.range_max_payout + quantity),
        range.total_payout + quantity,
    )
}

/// Payout liability after a prospective live close of `close_quantity` over
/// `(lower_tick, higher_tick]`: on a live exposure, what `payout_liability`
/// reads after `apply_close` removes it. Every point inside the range
/// drops by `close_quantity` and every point outside keeps its payout, so the
/// new point max is the larger of the lowered range peak and the complement
/// peak. The closing order is in the book, so neither subtraction can underflow.
public(package) fun liab_closed(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    close_quantity: u64,
): u64 {
    let (_, total_payout) = exposure.payout.rsv_terms();
    let range_max = exposure.payout.range_max(lower_tick, higher_tick);
    let complement_max = exposure.payout.outside_max(lower_tick, higher_tick);
    exposure.liab_of(
        (range_max - close_quantity).max(complement_max),
        total_payout - close_quantity,
    )
}

/// Return the sum of finite-boundary fees for a live range and quantity.
///
/// Fee collection is expiry-market payment accounting; exposure only owns the
/// snapshotted config needed to price it.
#[test_only]
public(package) fun trading_fee(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    price: &RangePrice,
    quantity: u64,
    clock: &sui::clock::Clock,
): u64 {
    exposure
        .config
        .trading_fee(
            expiry_ms,
            price,
            quantity,
            clock.timestamp_ms(),
        )
}

/// `trading_fee` at an explicit time: a queued fill is charged at its committed
/// tick, not at the resolve transaction's clock.
public(package) fun fee_at(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    price: &RangePrice,
    quantity: u64,
    now_ms: u64,
): u64 {
    exposure.config.trading_fee(expiry_ms, price, quantity, now_ms)
}

/// Return the deterministic inventory-impact potential for the current live
/// payout liability. The marginal rate rises linearly from zero to
/// `inventory_impact_max_rate` over `inventory_impact_scale`, then stays capped:
///
/// `phi(L) = r_max * L^2 / (2B)` for `L <= B`
/// `phi(L) = phi(B) + r_max * (L - B)` for `L > B`.
///
/// On-chain arithmetic defines `phi` by this exact sequence of rounded integer
/// operations. Trades always subtract two evaluations of the same function, so
/// charges and rebates telescope exactly even when the ideal real-valued
/// quadratic would have fractional dust.
public(package) fun impact_pot(exposure: &StrikeExposure): u64 {
    // Preserve the zero-rate kill switch through the post-trade backing check:
    // disabled markets do not perform a second payout-tree read here.
    if (exposure.is_settled() || exposure.config.inventory_impact_max_rate() == 0) return 0;
    exposure.pot_for_liab(exposure.payout_liability())
}

/// Price one mint of `quantity` over `range` as the exact increase of the
/// book-level potential, evaluated against the pre-mint book terms `range`
/// sampled. Live closes are rebated the exact decrease of the same potential
/// (`close_impact`); using one state function for every range makes
/// all closed inventory cycles sum to zero before ordinary trading fees.
///
/// Nondecreasing in `quantity`, which is what lets a budget search binary-search
/// over it. The prospective liability is `max(M, R + q) + lambda * (T + q - that)`:
/// while `R + q <= M` it rises at `lambda`, past that point the candidate carries
/// the max itself and the gap `T - R` is constant so it rises at 1, and at the
/// switch `q = M - R` both arms evaluate to `M + lambda * (T - R)` exactly. The
/// two arms therefore agree where they meet and neither falls, independently of
/// `backing_buffer_lambda`, and the potential is nondecreasing in liability.
public(package) fun mint_impact(exposure: &StrikeExposure, range: &MintRange, quantity: u64): u64 {
    if (exposure.config.inventory_impact_max_rate() == 0 || quantity == 0) return 0;

    let before = exposure.liab_of(range.max_payout, range.total_payout);
    let after = exposure.liab_of(
        range.max_payout.max(range.range_max_payout + quantity),
        range.total_payout + quantity,
    );
    exposure.pot_for_liab(after)
        - exposure.pot_for_liab(before)
}

/// Price one live close of `payout` over `(lower_tick, higher_tick]` as the exact
/// decrease of the book-level potential mints are charged against
/// (`mint_impact`).
public(package) fun close_impact(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    payout: u64,
): u64 {
    // Kill switch before the O(log n) range and complement reads.
    if (exposure.config.inventory_impact_max_rate() == 0 || payout == 0) return 0;

    let (max_payout, total_payout) = exposure.payout.rsv_terms();
    // Every live order contributes its complete payout at every point in its
    // range, so the pre-close range maximum is at least `payout`.
    let range_max = exposure.payout.range_max(lower_tick, higher_tick);
    let complement_max = exposure.payout.outside_max(lower_tick, higher_tick);
    let before = exposure.liab_of(max_payout, total_payout);
    let after = exposure.liab_of(
        (range_max - payout).max(complement_max),
        total_payout - payout,
    );
    exposure.pot_for_liab(before)
        - exposure.pot_for_liab(after)
}

/// Price a mint range, apply the entry-probability policy, and sample the pre-mint
/// book terms its inventory-impact charge depends on. Returns a range token for a
/// quantity search followed by `mint_terms`.
#[test_only]
public(package) fun quote_mint_range(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
): MintRange {
    let price = exposure.admitted_range_price(pricer, lower_tick, higher_tick);
    exposure.config.assert_range_mint_probability_policy(&price);
    // Kill switch before the O(log n) range read.
    let (max_payout, total_payout, range_max_payout) = if (
        exposure.config.inventory_impact_max_rate() == 0
    ) {
        (0, 0, 0)
    } else {
        let (max_payout, total_payout) = exposure.payout.rsv_terms();
        (max_payout, total_payout, exposure.payout.range_max(lower_tick, higher_tick))
    };
    MintRange {
        expiry_market_id: exposure.expiry_market_id,
        lower_tick,
        higher_tick,
        price,
        max_payout,
        total_payout,
        range_max_payout,
    }
}

/// Non-aborting `quote_mint_range`: `none` when the range cannot be priced or
/// fails the entry-probability policy. Always samples the pre-mint book reads,
/// even with inventory impact off, because resolve's no-cash check needs them.
///
/// `none` covers every input `quote_mint_range` aborts on (an off-grid tick, a
/// strike the pricer cannot price, the entry band) and also a tick pair no
/// order can encode, which would otherwise abort later at allocation.
public(package) fun try_mint_rng(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
): Option<MintRange> {
    if (
        !valid_range(lower_tick, higher_tick)
            || !exposure.is_admitted(lower_tick, higher_tick)
    ) return option::none();
    let price = pricer.try_range(
        range_codec::strike_from_tick(lower_tick, exposure.tick_size),
        range_codec::strike_from_tick(higher_tick, exposure.tick_size),
    );
    if (price.is_none()) return option::none();
    let price = price.destroy_some();
    if (!exposure.config.range_ok(&price)) return option::none();

    let (max_payout, total_payout) = exposure.payout.rsv_terms();
    option::some(MintRange {
        expiry_market_id: exposure.expiry_market_id,
        lower_tick,
        higher_tick,
        price,
        max_payout,
        total_payout,
        range_max_payout: exposure.payout.range_max(lower_tick, higher_tick),
    })
}

/// Non-aborting `mint_terms`. Returns the terms and `0`, or `none` and the
/// refund reason: `1` (limits: zero, below `min_quantity`, or not an encodable
/// lot quantity) or `2` (admission: probability band or minimum premium).
///
/// `none` covers exactly the inputs `mint_terms` aborts on. The size checks run
/// first, so a zero size reports `1` even though `mint_terms` would hit the
/// premium floor before its quantity check. A range quoted on another exposure
/// still aborts `ETermsExposureMismatch`: that is a caller bug, not a tick input.
public(package) fun try_terms(
    exposure: &StrikeExposure,
    range: MintRange,
    quantity: u64,
    min_quantity: u64,
): (Option<MintTerms>, u8) {
    assert!(range.expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);
    if (quantity < min_quantity || !valid_qty(quantity)) {
        return (option::none(), constants::fill_reason_limits!())
    };
    let entry_probability = range.price.probability();
    let premium = math::mul_down(entry_probability, quantity);
    if (
        !exposure.config.prob_ok(entry_probability)
            || premium < constants::min_premium!()
    ) {
        return (option::none(), constants::fill_reason_admission!())
    };

    let inventory_impact_charge = exposure.mint_impact(&range, quantity);
    let MintRange { expiry_market_id, lower_tick, higher_tick, price, .. } = range;
    let terms = MintTerms {
        expiry_market_id,
        lower_tick,
        higher_tick,
        quantity,
        price,
        premium,
        inventory_impact_charge,
    };
    (option::some(terms), 0)
}

/// Non-aborting `quote_mint_terms`: `try_mint_rng`, then sizing, then
/// `try_terms`, with the same reason codes. A range that cannot be quoted
/// reports `2`; a budget too small for one lot sizes to zero and reports `1`.
#[test_only]
public(package) fun try_quote_mint_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
): (Option<MintTerms>, u8) {
    let range = exposure.try_mint_rng(pricer, lower_tick, higher_tick);
    if (range.is_none()) return (option::none(), constants::fill_reason_admission!());
    let range = range.destroy_some();
    let quantity = if (exact_quantity) {
        min_quantity
    } else {
        range.qty_for_prem(max_premium)
    };
    exposure.try_terms(range, quantity, min_quantity)
}

/// Return the largest lot-rounded quantity whose premium over `range` fits
/// `max_premium`. The probe is the expression admission charges, so the result is
/// exact; the search domain is the lot cap, so an oversized budget saturates
/// instead of aborting.
public(package) fun qty_for_prem(range: &MintRange, max_premium: u64): u64 {
    pmath::max_qty(
        range.price.probability(),
        max_premium,
        constants::position_lot_size!(),
        order::max_quantity_lots!(),
    )
}

/// Admit a quantity over a quoted range: require it to meet `min_quantity`, run
/// mint admission, and build the terms with the range's inventory-impact charge.
#[test_only]
public(package) fun mint_terms(
    exposure: &StrikeExposure,
    range: MintRange,
    quantity: u64,
    min_quantity: u64,
): MintTerms {
    // The range carries the book reads its impact charge is priced against, so a
    // range from another exposure would misprice silently — and in the quote path
    // no allocation follows to catch it.
    assert!(range.expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);
    assert!(quantity >= min_quantity, EMintQuantityBelowMin);
    let premium = exposure.config.assert_mint_admission(range.price.probability(), quantity);
    // Preserve the mutation path's validation order.
    order::chk_quantity(quantity);
    let inventory_impact_charge = exposure.mint_impact(&range, quantity);
    let MintRange { expiry_market_id, lower_tick, higher_tick, price, .. } = range;
    MintTerms {
        expiry_market_id,
        lower_tick,
        higher_tick,
        quantity,
        price,
        premium,
        inventory_impact_charge,
    }
}

/// Price a range, choose quantity under the requested bias, and run mint
/// admission. Exact-quantity mode uses `min_quantity`. Budget mode sizes with
/// `qty_for_prem`, then requires the result to meet `min_quantity`.
#[test_only]
public(package) fun quote_mint_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
): MintTerms {
    let range = exposure.quote_mint_range(pricer, lower_tick, higher_tick);
    let quantity = if (exact_quantity) {
        min_quantity
    } else {
        range.qty_for_prem(max_premium)
    };
    exposure.mint_terms(range, quantity, min_quantity)
}

/// Allocate a live mint order from priced terms: consume the expiry-local
/// sequence and insert the order into the payout index. Taking `terms` by value
/// ties each allocation to exactly one admission result, so the order's contract
/// fields are always the ones that were priced, and the market-identity assert
/// rejects terms priced on another exposure.
#[test_only]
public(package) fun allocate_mint_order(exposure: &mut StrikeExposure, terms: MintTerms): Order {
    let MintTerms { expiry_market_id, lower_tick, higher_tick, quantity, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::from_ticks(lower_tick, higher_tick, quantity, sequence);
    exposure.next_order_sequence = sequence + 1;

    exposure.payout.insert_range(lower_tick, higher_tick, quantity);

    allocated_order
}

/// Allocate a queued mint at resolve: `allocate_mint_order` over nodes placement
/// already pinned, so the fill creates no tree node (`insert_exist`).
/// Aborts `strike_payout_tree::ENodeMissing` if a boundary is missing; resolve
/// checks `nodes_exist` first and refunds instead.
public(package) fun allocate(exposure: &mut StrikeExposure, terms: MintTerms): Order {
    let MintTerms { expiry_market_id, lower_tick, higher_tick, quantity, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::from_ticks(lower_tick, higher_tick, quantity, sequence);
    exposure.next_order_sequence = sequence + 1;

    exposure.payout.insert_exist(lower_tick, higher_tick, quantity);

    allocated_order
}

/// Ensure both finite boundaries of a mint range exist as tree nodes, so a
/// later resolve fill inserts over existing nodes only.
public(package) fun ensure_nodes(exposure: &mut StrikeExposure, lower_tick: u64, higher_tick: u64) {
    exposure.payout.ensure_node(lower_tick);
    exposure.payout.ensure_node(higher_tick);
}

/// Detach the payout-tree node at `tick` if it is empty, unpinned, and not
/// retained by the flush snapshot. Never aborts.
public(package) fun prune_node(
    exposure: &mut StrikeExposure,
    tick: u64,
    pins: &VecMap<u64, u64>,
): bool {
    exposure.payout.prune_node(tick, pins)
}

/// Non-aborting `quote_live_close`: `none` when the close cannot be priced, and
/// where `quote_live_close` aborts on its quantity checks (not an encodable lot
/// quantity, or above the order's quantity). Same terms otherwise.
public(package) fun try_close(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
): Option<LiveCloseTerms> {
    if (!valid_qty(close_quantity) || close_quantity > order.quantity()) {
        return option::none()
    };
    let price = pricer.try_range(
        range_codec::strike_from_tick(order.lower_tick(), exposure.tick_size),
        range_codec::strike_from_tick(order.higher_tick(), exposure.tick_size),
    );
    if (price.is_none()) return option::none();
    let price = price.destroy_some();
    option::some(LiveCloseTerms {
        expiry_market_id: exposure.expiry_market_id,
        order: *order,
        close_quantity,
        redeem_amount: math::mul_down(price.probability(), close_quantity),
        price,
        inventory_impact_rebate: exposure.close_impact(
            order.lower_tick(),
            order.higher_tick(),
            close_quantity,
        ),
    })
}

/// Quote one prospective live close as pure terms, touching neither the book nor
/// the oracle after the supplied `Pricer` snapshot. Boundary prices feed fees;
/// mint probability eligibility is deliberately not applied to exits.
#[test_only]
public(package) fun quote_live_close(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
): LiveCloseTerms {
    order::chk_quantity(close_quantity);
    assert!(close_quantity <= order.quantity(), EInvalidCloseQuantity);

    let price = exposure.order_px(pricer, order);
    let range_probability = price.probability();
    LiveCloseTerms {
        expiry_market_id: exposure.expiry_market_id,
        order: *order,
        close_quantity,
        redeem_amount: math::mul_down(range_probability, close_quantity),
        price,
        inventory_impact_rebate: exposure.close_impact(
            order.lower_tick(),
            order.higher_tick(),
            close_quantity,
        ),
    }
}

/// Apply one quoted live close to the book and return the replacement order a
/// partial close leaves behind. Boundaries a waiting order pins survive.
public(package) fun apply_close(
    exposure: &mut StrikeExposure,
    terms: LiveCloseTerms,
    pins: &VecMap<u64, u64>,
): Option<Order> {
    let LiveCloseTerms { expiry_market_id, order, close_quantity, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    exposure.payout.remove_range(order.lower_tick(), order.higher_tick(), close_quantity, pins);

    let remaining_quantity = order.quantity() - close_quantity;
    if (remaining_quantity == 0) return option::none();

    let replacement_order = order::replacement(
        &order,
        remaining_quantity,
        exposure.next_order_sequence,
    );
    exposure.next_order_sequence = exposure.next_order_sequence + 1;
    option::some(replacement_order)
}

/// Release one order's full terminal payout from settled liability and return it.
public(package) fun settle_close(exposure: &mut StrikeExposure, order: &Order): u64 {
    let payout = exposure.settled_order_payout(order);
    // Settlement liability and individual payouts use the same integer quantity
    // atoms, so the subtraction is additive without rounding dust.
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;
    payout
}

/// Non-aborting `settle_close` for the `try_settle` payout walk:
/// `none`, with nothing changed, when the payout would underflow settled
/// liability, or when the exposure is not settled yet. A losing order returns
/// `some(0)`.
public(package) fun try_settled(exposure: &mut StrikeExposure, order: &Order): Option<u64> {
    if (!exposure.is_settled()) return option::none();
    let payout = exposure.settled_order_payout(order);
    if (payout > exposure.settled_payout_liability) return option::none();
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;
    option::some(payout)
}

/// Enter the settled phase by recording the terminal price and aggregate payout
/// liability. The caller owns expiry and oracle validation.
public(package) fun set_settled(exposure: &mut StrikeExposure, settlement_price: u64) {
    if (exposure.is_settled()) return;

    let settled_payout_liability = exposure
        .payout
        .settled_liab(settlement_price, exposure.tick_size);
    exposure.settlement_price = option::some(settlement_price);
    exposure.settled_payout_liability = settled_payout_liability;
}

/// Set the reference fine-grid tick that can bypass coarser mint admission.
/// Returns `true` only when this call records the tick for the first time.
/// Repeated calls are idempotent for the same tick and abort for a different one.
public(package) fun set_reference_tick(exposure: &mut StrikeExposure, tick: u64): bool {
    assert!(tick > 0 && tick < constants::pos_inf_tick!(), EInvalidReferenceTick);
    if (exposure.reference_tick.is_some()) {
        assert!(*exposure.reference_tick.borrow() == tick, EReferenceTickAlreadySet);
        return false
    };
    exposure.reference_tick = option::some(tick);
    true
}

/// Create a strike exposure book for one expiry market.
public(package) fun new(
    expiry_market_id: ID,
    config: StrikeExposureConfig,
    tick_size: u64,
    admission_tick_size: u64,
    reference_tick_source_timestamp_ms: u64,
    inventory_impact_scale: u64,
    ctx: &mut TxContext,
): StrikeExposure {
    assert!(inventory_impact_scale > 0, EInvalidInventoryImpactScale);
    StrikeExposure {
        expiry_market_id,
        tick_size,
        admission_tick_size,
        reference_tick_source_timestamp_ms,
        reference_tick: option::none(),
        config,
        inventory_impact_scale,
        next_order_sequence: 0,
        settlement_price: option::none(),
        settled_payout_liability: 0,
        payout: strike_payout_tree::new(ctx),
    }
}

/// Price the mint tick range `(lower_tick, higher_tick]` after admission-grid
/// validation. The single pricing-prefix orchestration shared by every mint
/// quote/terms path.
#[test_only]
fun admitted_range_price(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
): RangePrice {
    exposure.assert_admitted_mint_ticks(lower_tick, higher_tick);
    let lower = range_codec::strike_from_tick(lower_tick, exposure.tick_size);
    let higher = range_codec::strike_from_tick(higher_tick, exposure.tick_size);
    pricer.range_price(lower, higher)
}

fun pot_for_liab(exposure: &StrikeExposure, liability: u64): u64 {
    pmath::potential(
        exposure.config.inventory_impact_max_rate(),
        exposure.inventory_impact_scale,
        liability,
    )
}

/// Return the live liability for full point-max and total payout terms. Trade
/// impact evaluates this on both the current and prospective terms: independently
/// rounding `lambda * delta(T-M)` can miss a one-atom carry already accumulated in
/// the book's buffered gap.
fun liab_of(exposure: &StrikeExposure, max_payout: u64, total_payout: u64): u64 {
    // The point max is a subset-sum of the same non-negative per-order payouts.
    let gap = total_payout - max_payout;
    max_payout + math::mul_down(exposure.config.backing_buffer_lambda(), gap)
}

#[test_only]
fun assert_admitted_mint_ticks(exposure: &StrikeExposure, lower_tick: u64, higher_tick: u64) {
    assert!(exposure.is_admitted(lower_tick, higher_tick), EInvalidAdmissionTick);
}

/// Whether each finite mint boundary sits on the admission grid or is the
/// reference tick. The assert calls this, so the rule lives in one place.
fun is_admitted(exposure: &StrikeExposure, lower_tick: u64, higher_tick: u64): bool {
    let admission_multiple = exposure.admission_tick_size / exposure.tick_size;
    let lower_admitted =
        lower_tick == 0
        || lower_tick % admission_multiple == 0
        || exposure.reference_tick.contains(&lower_tick);
    let higher_admitted =
        higher_tick == constants::pos_inf_tick!()
        || higher_tick % admission_multiple == 0
        || exposure.reference_tick.contains(&higher_tick);
    lower_admitted && higher_admitted
}

/// Non-aborting form of `order`'s range-shape check, so a try path rejects a
/// tick pair no order can encode instead of aborting at allocation.
fun valid_range(lower_tick: u64, higher_tick: u64): bool {
    let pos_inf_tick = constants::pos_inf_tick!();
    lower_tick < higher_tick
        && higher_tick <= pos_inf_tick
        && !(lower_tick == 0 && higher_tick == pos_inf_tick)
}

/// Non-aborting `order::chk_quantity`: a positive whole number of lots
/// that fits the order ID's lot field.
fun valid_qty(quantity: u64): bool {
    let lot_size = constants::position_lot_size!();
    quantity > 0 && quantity % lot_size == 0 && quantity / lot_size <= order::max_quantity_lots!()
}

fun order_px(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): RangePrice {
    pricer.range_price(
        range_codec::strike_from_tick(order.lower_tick(), exposure.tick_size),
        range_codec::strike_from_tick(order.higher_tick(), exposure.tick_size),
    )
}
