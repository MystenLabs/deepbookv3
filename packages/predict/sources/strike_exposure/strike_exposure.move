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
    pricing::Pricer,
    range_codec,
    strike_exposure_config::StrikeExposureConfig,
    strike_payout_tree::{Self, StrikePayoutTree}
};
use fixed_math::math;
use sui::clock::Clock;

const EInvalidCloseQuantity: u64 = 0;
const EInvalidAdmissionTick: u64 = 1;
const EInvalidReferenceTick: u64 = 2;
const ETermsExposureMismatch: u64 = 3;
const EMintQuantityBelowMin: u64 = 4;
const EInvalidInventoryImpactScale: u64 = 5;
const EInvalidReferenceTickSchedule: u64 = 6;

/// One creation-scheduled exact-history Pyth reference tick for an expiry market.
public struct ReferenceTick has copy, drop, store {
    source_timestamp_ms: u64,
    tick: Option<u64>,
}

/// Exposure lifecycle state for one expiry market.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Raw-price-per-tick conversion factor; `raw_strike = tick * tick_size`.
    tick_size: u64,
    /// Coarser raw-price step that new finite mint boundaries must align to.
    admission_tick_size: u64,
    /// Creation-scheduled cadence references, native first, whose filled fine-grid ticks may bypass
    /// the coarser admission grid.
    reference_ticks: vector<ReferenceTick>,
    /// Snapshotted exposure and fee policy for this expiry.
    config: StrikeExposureConfig,
    /// Immutable DUSDC scale for the inventory-impact curve. This is the
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

/// Pure mint terms for one prospective live mint: the priced tick range and
/// quantity, plus the admission results they produced. Built only by
/// `quote_mint_terms` and consumed by value in `allocate_mint_order`, so one
/// terms value backs at most one allocation and allocation can never see inputs
/// that differ from the priced ones. Terms carry the pricing exposure's market
/// identity; allocation asserts it, so terms cannot cross exposure books.
public struct MintTerms has drop {
    expiry_market_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    entry_probability: u64,
    premium: u64,
    /// Separate inventory-impact charge, sampled against the pre-mint book.
    inventory_impact_charge: u64,
}

/// Compute-once terms for one prospective live close. Built only by
/// `quote_live_close` and consumed by value in `process_live_close`, so one terms
/// value backs at most one mutation. The survivor's quantity is derived by
/// conservation (`total - removed`) at the mutation.
public struct LiveCloseTerms has drop {
    expiry_market_id: ID,
    order: Order,
    close_quantity: u64,
    redeem_amount: u64,
    range_probability: u64,
    /// Separate inventory-impact rebate, sampled against the pre-close book.
    inventory_impact_rebate: u64,
}

/// Return the exact Pyth source timestamp for one reference tick.
public fun source_timestamp_ms(reference: &ReferenceTick): u64 {
    reference.source_timestamp_ms
}

/// Return the fine-grid tick for one reference slot, or `none` until exact history is available.
public fun reference_tick_value(reference: &ReferenceTick): Option<u64> {
    reference.tick
}

public(package) fun entry_probability(terms: &MintTerms): u64 {
    terms.entry_probability
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

public(package) fun redeem_amount(terms: &LiveCloseTerms): u64 {
    terms.redeem_amount
}

public(package) fun range_probability(terms: &LiveCloseTerms): u64 {
    terms.range_probability
}

public(package) fun inventory_impact_rebate(terms: &LiveCloseTerms): u64 {
    terms.inventory_impact_rebate
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
        let (max_payout, total_payout) = exposure.payout.payout_reserve_terms();
        exposure.live_payout_liability_from_terms(max_payout, total_payout)
    }
}

/// Return the live marked liability: every open contract's range-probability
/// value, priced once per boundary by the payout tree's in-order walk. Every order
/// is worth `quantity * P(range)` live, so no per-order correction is needed. The
/// aggregate is netted per boundary rather than per order, so it can differ from
/// the per-order sum by boundary rounding; it is clamped at zero once, in the walk.
public(package) fun live_marked_liability(exposure: &StrikeExposure, pricer: &Pricer): u64 {
    exposure.payout.walk_linear(pricer, exposure.tick_size)
}

/// Return one live order's full-close range value without consulting book state.
public(package) fun live_order_value(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
): u64 {
    math::mul_down(exposure.order_range_price(pricer, order), order.quantity())
}

/// Return one settled order's full terminal payout.
public(package) fun settled_order_payout(exposure: &StrikeExposure, order: &Order): u64 {
    let settlement_price = exposure.settlement_price();
    if (
        range_codec::settlement_in_range(
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
    exposure.reference_ticks[0].source_timestamp_ms
}

/// Return all immutable cadence-aligned reference ticks.
public(package) fun reference_ticks(exposure: &StrikeExposure): vector<ReferenceTick> {
    exposure.reference_ticks
}

/// Return the native-cadence reference tick, or `none` until it is recorded.
public(package) fun reference_tick(exposure: &StrikeExposure): Option<u64> {
    exposure.reference_ticks[0].tick
}

/// Return the raw per-trade fee for a live price and quantity.
///
/// Fee collection is expiry-market payment accounting; exposure only owns the
/// snapshotted config needed to price it.
public(package) fun trading_fee(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    probability: u64,
    quantity: u64,
    clock: &Clock,
): u64 {
    exposure
        .config
        .trading_fee(
            expiry_ms,
            probability,
            quantity,
            clock.timestamp_ms(),
        )
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
public(package) fun inventory_impact_potential(exposure: &StrikeExposure): u64 {
    // Preserve the zero-rate kill switch through the post-trade backing check:
    // disabled markets do not perform a second payout-tree read here.
    if (exposure.is_settled() || exposure.config.inventory_impact_max_rate() == 0) return 0;
    exposure.inventory_impact_potential_for_liability(exposure.payout_liability())
}

/// Price one mint (`adding`) or live close (`!adding`) as the exact change of a
/// single book-level potential. Using one state function for every range makes
/// all closed inventory cycles sum to zero before ordinary trading fees.
public(package) fun inventory_impact(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    payout: u64,
    adding: bool,
): u64 {
    // Kill switch before the O(log n) range and complement reads.
    if (exposure.config.inventory_impact_max_rate() == 0 || payout == 0) return 0;

    let (before, after) = exposure.payout_liabilities_after_change(
        lower_tick,
        higher_tick,
        payout,
        adding,
    );
    let before_potential = exposure.inventory_impact_potential_for_liability(before);
    let after_potential = exposure.inventory_impact_potential_for_liability(after);
    if (adding) {
        after_potential - before_potential
    } else {
        before_potential - after_potential
    }
}

/// Price a range, choose quantity under the requested bias, and run mint
/// admission. Exact-quantity mode uses `min_quantity`. Budget mode lot-rounds a
/// premium search whose predicate is the same expression admission charges, so the
/// largest admitted quantity is exact, then requires the result to meet
/// `min_quantity`.
public(package) fun quote_mint_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
): MintTerms {
    let entry_probability = exposure.admitted_entry_probability(pricer, lower_tick, higher_tick);

    let quantity = if (exact_quantity) {
        min_quantity
    } else {
        exposure.config.assert_mint_probability_policy(entry_probability);
        let lot = constants::position_lot_size!();
        let mut lo = 0;
        let mut hi = order::max_quantity_lots();
        while (lo < hi) {
            let mid = (lo + hi + 1) / 2;
            if (math::mul_down(entry_probability, mid * lot) <= max_premium) {
                lo = mid
            } else {
                hi = mid - 1
            }
        };
        lo * lot
    };
    assert!(quantity >= min_quantity, EMintQuantityBelowMin);

    let premium = exposure.config.assert_mint_admission(entry_probability, quantity);
    // Preserve the mutation path's validation order.
    order::assert_valid_quantity(quantity);
    MintTerms {
        expiry_market_id: exposure.expiry_market_id,
        lower_tick,
        higher_tick,
        quantity,
        entry_probability,
        premium,
        inventory_impact_charge: exposure.inventory_impact(
            lower_tick,
            higher_tick,
            quantity,
            true,
        ),
    }
}

/// Allocate a live mint order from priced terms: consume the expiry-local
/// sequence and insert the order into the payout index. Taking `terms` by value
/// ties each allocation to exactly one admission result, so the order's contract
/// fields are always the ones that were priced, and the market-identity assert
/// rejects terms priced on another exposure.
public(package) fun allocate_mint_order(exposure: &mut StrikeExposure, terms: MintTerms): Order {
    let MintTerms { expiry_market_id, lower_tick, higher_tick, quantity, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::new_from_ticks(lower_tick, higher_tick, quantity, sequence);
    exposure.next_order_sequence = sequence + 1;

    exposure.payout.insert_range(lower_tick, higher_tick, quantity);

    allocated_order
}

/// Quote one prospective live close as pure terms, touching neither the book nor
/// the oracle after the supplied `Pricer` snapshot. The trade fee is recovered
/// from the returned range probability.
public(package) fun quote_live_close(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
): LiveCloseTerms {
    order::assert_valid_quantity(close_quantity);
    assert!(close_quantity <= order.quantity(), EInvalidCloseQuantity);

    let range_probability = exposure.order_range_price(pricer, order);
    LiveCloseTerms {
        expiry_market_id: exposure.expiry_market_id,
        order: *order,
        close_quantity,
        redeem_amount: math::mul_down(range_probability, close_quantity),
        range_probability,
        inventory_impact_rebate: exposure.inventory_impact(
            order.lower_tick(),
            order.higher_tick(),
            close_quantity,
            false,
        ),
    }
}

/// Apply one quoted live close to the book and return the replacement order a
/// partial close leaves behind.
public(package) fun process_live_close(
    exposure: &mut StrikeExposure,
    terms: LiveCloseTerms,
): Option<Order> {
    let LiveCloseTerms { expiry_market_id, order, close_quantity, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    exposure.payout.remove_range(order.lower_tick(), order.higher_tick(), close_quantity);

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
public(package) fun process_settled_close(exposure: &mut StrikeExposure, order: &Order): u64 {
    let payout = exposure.settled_order_payout(order);
    // Settlement liability and individual payouts use the same integer quantity
    // atoms, so the subtraction is additive without rounding dust.
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;
    payout
}

/// Enter the settled phase by recording the terminal price and aggregate payout
/// liability. The caller owns expiry and oracle validation.
public(package) fun record_settlement(exposure: &mut StrikeExposure, settlement_price: u64) {
    if (exposure.is_settled()) return;

    let settled_payout_liability = exposure
        .payout
        .settled_payout_liability(settlement_price, exposure.tick_size);
    exposure.settlement_price = option::some(settlement_price);
    exposure.settled_payout_liability = settled_payout_liability;
}

/// Fill one creation-scheduled cadence reference.
/// Returns `true` only when this call records the tick for the first time.
public(package) fun set_reference_tick(
    exposure: &mut StrikeExposure,
    reference_index: u64,
    tick: u64,
): bool {
    assert!(tick > 0 && tick < constants::pos_inf_tick!(), EInvalidReferenceTick);
    let reference = &mut exposure.reference_ticks[reference_index];
    if (reference.tick.is_some()) {
        return false
    };
    reference.tick = option::some(tick);
    true
}

/// Create a strike exposure book for one expiry market.
public(package) fun new(
    expiry_market_id: ID,
    config: StrikeExposureConfig,
    tick_size: u64,
    admission_tick_size: u64,
    reference_tick_source_timestamps_ms: vector<u64>,
    inventory_impact_scale: u64,
    ctx: &mut TxContext,
): StrikeExposure {
    assert!(!reference_tick_source_timestamps_ms.is_empty(), EInvalidReferenceTickSchedule);
    assert!(inventory_impact_scale > 0, EInvalidInventoryImpactScale);
    let mut reference_ticks = vector[];
    reference_tick_source_timestamps_ms.do!(|source_timestamp_ms| {
        reference_ticks.push_back(ReferenceTick {
            source_timestamp_ms,
            tick: option::none(),
        });
    });
    StrikeExposure {
        expiry_market_id,
        tick_size,
        admission_tick_size,
        reference_ticks,
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
fun admitted_entry_probability(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    exposure.assert_admitted_mint_ticks(lower_tick, higher_tick);
    let lower = range_codec::strike_from_tick(lower_tick, exposure.tick_size);
    let higher = range_codec::strike_from_tick(higher_tick, exposure.tick_size);
    pricer.range_price(lower, higher)
}

fun inventory_impact_potential_for_liability(exposure: &StrikeExposure, liability: u64): u64 {
    let max_rate = exposure.config.inventory_impact_max_rate();
    if (max_rate == 0 || liability == 0) return 0;

    let scale = exposure.inventory_impact_scale;
    let capped_liability = liability.min(scale);
    let utilization = math::mul_div_down(
        capped_liability,
        math::float_scaling!(),
        scale,
    );
    let marginal_rate = math::mul_down(max_rate, utilization);
    let potential_at_capped_liability =
        math::mul_down(
        marginal_rate,
        capped_liability,
    ) / 2;
    if (liability <= scale) return potential_at_capped_liability;

    potential_at_capped_liability + math::mul_down(max_rate, liability - scale)
}

/// Return the exact current and prospective live liabilities for one range
/// change. Evaluating the full terms on both sides is necessary: independently
/// rounding `lambda * delta(T-M)` can miss a one-atom carry already accumulated
/// in the book's buffered gap.
fun payout_liabilities_after_change(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    payout: u64,
    adding: bool,
): (u64, u64) {
    let (max_payout, total_payout) = exposure.payout.payout_reserve_terms();
    let range_max = exposure.payout.range_max_payout(lower_tick, higher_tick);
    let (after_max, after_total) = if (adding) {
        (max_payout.max(range_max + payout), total_payout + payout)
    } else {
        // Every live order contributes its complete payout at every point in its
        // range, so the pre-close range maximum is at least `payout`.
        let complement_max = exposure.payout.complement_max_payout(lower_tick, higher_tick);
        ((range_max - payout).max(complement_max), total_payout - payout)
    };
    (
        exposure.live_payout_liability_from_terms(max_payout, total_payout),
        exposure.live_payout_liability_from_terms(after_max, after_total),
    )
}

fun live_payout_liability_from_terms(
    exposure: &StrikeExposure,
    max_payout: u64,
    total_payout: u64,
): u64 {
    // The point max is a subset-sum of the same non-negative per-order payouts.
    let gap = total_payout - max_payout;
    max_payout + math::mul_down(exposure.config.backing_buffer_lambda(), gap)
}

fun assert_admitted_mint_ticks(exposure: &StrikeExposure, lower_tick: u64, higher_tick: u64) {
    let admission_multiple = exposure.admission_tick_size / exposure.tick_size;
    assert!(
        lower_tick == 0
            || lower_tick % admission_multiple == 0
            || exposure
                .reference_ticks
                .any!(|reference| reference.tick == option::some(lower_tick)),
        EInvalidAdmissionTick,
    );
    assert!(
        higher_tick == constants::pos_inf_tick!()
            || higher_tick % admission_multiple == 0
            || exposure
                .reference_ticks
                .any!(|reference| reference.tick == option::some(higher_tick)),
        EInvalidAdmissionTick,
    );
}

fun order_range_price(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): u64 {
    pricer.range_price(
        range_codec::strike_from_tick(order.lower_tick(), exposure.tick_size),
        range_codec::strike_from_tick(order.higher_tick(), exposure.tick_size),
    )
}
