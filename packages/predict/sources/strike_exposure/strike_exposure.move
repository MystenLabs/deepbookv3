// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local exposure book for one expiry market.
///
/// This module interprets `Order` terms against the expiry's `tick_size`,
/// recovering raw strikes from order ticks only at the pricing/settlement boundary.
/// It owns the payout-liability view of the active contracts used for cash backing.
/// The order floor is a static dollar amount (`floor_shares`), so order accounting
/// needs no clock. It stores the parent market identity so market-scoped
/// liquidation events can be emitted atomically with exposure removal. Expiry-market
/// cash custody, rebate accounting, account positions, and payout movement stay
/// outside this module.
module deepbook_predict::strike_exposure;

use deepbook_predict::{
    constants,
    liquidation_book::{Self, LiquidationBook},
    order::{Self, Order},
    order_events,
    pricing::{Self, Pricer},
    range_codec,
    strike_exposure_config::StrikeExposureConfig,
    strike_payout_tree::{Self, StrikePayoutTree}
};
use fixed_math::math;
use sui::clock::Clock;

const EInvalidCloseQuantity: u64 = 0;
const EInvalidAdmissionTick: u64 = 1;
const EInvalidReferenceTick: u64 = 2;
const EReferenceTickAlreadySet: u64 = 3;
const ETermsExposureMismatch: u64 = 4;
const EMintQuantityBelowMin: u64 = 5;
const EWrongCloseOutcome: u64 = 6;
const EPricerRequired: u64 = 7;

/// Exposure lifecycle state for one expiry market.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Terminal timestamp used by fee and settlement math.
    expiry_ms: u64,
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
    next_order_sequence: u64,
    /// Terminal settlement price once the exposure has entered its settled phase.
    settlement_price: Option<u64>,
    /// Remaining payout liability in the settled phase.
    settled_payout_liability: u64,
    liquidation: LiquidationBook,
    /// Sparse payout tree for live cash backing and settled liability.
    payout: StrikePayoutTree,
}

/// Pure mint terms for one prospective live mint: the priced tick range,
/// quantity, and leverage, plus the admission results they produced. Built only
/// by `quote_mint_terms` and consumed by value in `allocate_mint_order`, so one
/// terms value backs at most one allocation and allocation can never see inputs
/// that differ from the priced ones. Terms carry the pricing exposure's market
/// identity; allocation asserts it, so terms cannot cross exposure books.
public struct MintTerms has drop {
    expiry_market_id: ID,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    entry_probability: u64,
    net_premium: u64,
    floor_shares: u64,
}

/// Compute-once terms for one prospective close of `order`. Built only by
/// `quote_close` and consumed by value in `process_close`, so one terms value
/// backs at most one close and the book mutation can only apply exactly the
/// quoted outcome. Terms carry the pricing exposure's market identity; the
/// consumer asserts it, so terms cannot cross exposure books. `order` names the
/// book entry the close removes (its atoms decode from the packed id); the
/// outcome payload holds the values the quote computed.
public struct CloseTerms has drop {
    expiry_market_id: ID,
    /// Which book entry the close removes.
    order: Order,
    outcome: CloseOutcome,
}

/// Every outcome of one prospective close: an already-liquidated order whose
/// book state is gone (only the holder's position clear remains), a
/// liquidatable order due its knock-out at the current price, a priced live
/// close, or the settled terminal payout
/// (zero for a loss). Enums match only inside their defining module, so flows
/// branch via the `is_*` accessors and `process_close` owns the dispatch.
public enum CloseOutcome has drop {
    Liquidated,
    Liquidatable { gross_value: u64 },
    Live(LiveCloseTerms),
    Settled { payout: u64 },
}

/// Live-close payload: the closed slice the mutation must remove and the
/// priced facts flow policy reads. Built only by `quote_live_close` and
/// consumed by value in `process_live_close`, so one terms value backs at most
/// one close and the book mutation can only apply exactly the quoted slice.
/// Carries only the removed side; the survivor's values are derived by
/// conservation (`total - removed`) at the mutation, so the split cannot
/// un-conserve quantity or floor shares.
public struct LiveCloseTerms has drop {
    close_quantity: u64,
    /// Floor shares leaving the book with the closed slice.
    remove_floor_shares: u64,
    redeem_amount: u64,
    range_probability: u64,
}

public(package) fun entry_probability(terms: &MintTerms): u64 {
    terms.entry_probability
}

public(package) fun net_premium(terms: &MintTerms): u64 {
    terms.net_premium
}

public(package) fun quantity(terms: &MintTerms): u64 {
    terms.quantity
}

public(package) fun leverage(terms: &MintTerms): u64 {
    terms.leverage
}

public(package) fun is_liquidated(terms: &CloseTerms): bool {
    match (&terms.outcome) {
        CloseOutcome::Liquidated => true,
        _ => false,
    }
}

public(package) fun is_liquidatable(terms: &CloseTerms): bool {
    match (&terms.outcome) {
        CloseOutcome::Liquidatable { .. } => true,
        _ => false,
    }
}

public(package) fun is_live(terms: &CloseTerms): bool {
    match (&terms.outcome) {
        CloseOutcome::Live(_) => true,
        _ => false,
    }
}

/// Terminal payout for the account credit and event: exact for a settled win,
/// zero for a settled loss; aborts unless the outcome is `Settled`.
public(package) fun settled_payout(terms: &CloseTerms): u64 {
    match (&terms.outcome) {
        CloseOutcome::Settled { payout } => *payout,
        _ => abort EWrongCloseOutcome,
    }
}

/// Live-arm reads for flow policy and the payment decomposition; abort unless
/// the outcome is `Live`.
public(package) fun redeem_amount(terms: &CloseTerms): u64 {
    terms.live_terms().redeem_amount
}

public(package) fun range_probability(terms: &CloseTerms): u64 {
    terms.live_terms().range_probability
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
/// Live reserve is the settlement floor (max single-point net payout) plus a
/// configured fraction of the gap between summed and maximum point payout.
public(package) fun payout_liability(exposure: &StrikeExposure): u64 {
    if (exposure.is_settled()) {
        exposure.settled_payout_liability
    } else {
        let (max_net_payout, total_net_payout) = exposure.payout.net_payout_reserve_terms();
        // The point max is a subset-sum of the same non-negative per-order net payouts.
        let gap = total_net_payout - max_net_payout;
        max_net_payout + math::mul(exposure.config.backing_buffer_lambda(), gap)
    }
}

/// Return the live marked liability as the aggregate boundary-linear term minus
/// the leveraged floor correction. A knocked-out order (gross at or below
/// `floor_shares / liquidation_ltv`) is marked at zero live liability, so the
/// flush mark never prices a claim above what the protocol honors once the
/// ambient sweep liquidates it; every other order contributes its positive
/// `range_value - floor_shares`. Boundary aggregation and per-order correction
/// round at different points, so the subtraction saturates at zero. Also returns
/// the certified liability error — the walk and correction errors sum, since the
/// subtraction adds their widths.
public(package) fun exact_live_liability(exposure: &StrikeExposure, pricer: &Pricer): (u64, u64) {
    let mut memo = pricing::new_price_memo();
    let (linear, linear_error) = exposure.payout.walk_linear(pricer, &mut memo, exposure.tick_size);
    let (correction, correction_error) = exposure
        .liquidation
        .correction_value(
            &memo,
            exposure.config.liquidation_ltv(),
        );
    (linear.saturating_sub(correction), linear_error + correction_error)
}

/// Return the liquidation LTV snapshotted for this exposure book.
public(package) fun liquidation_ltv(exposure: &StrikeExposure): u64 {
    exposure.config.liquidation_ltv()
}

/// Return the max admission leverage snapshotted for this exposure book.
public(package) fun max_admission_leverage(exposure: &StrikeExposure): u64 {
    exposure.config.max_admission_leverage()
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

public(package) fun no_leverage_window_ms(exposure: &StrikeExposure): u64 {
    exposure.config.no_leverage_window_ms()
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

/// Return the raw per-trade fee for a live price and quantity.
///
/// Fee collection is expiry-market payment accounting; exposure only owns the
/// snapshotted config needed to price it.
public(package) fun trading_fee(
    exposure: &StrikeExposure,
    probability: u64,
    quantity: u64,
    clock: &Clock,
): u64 {
    exposure
        .config
        .trading_fee(
            exposure.expiry_ms,
            probability,
            quantity,
            clock.timestamp_ms(),
        )
}

/// Return whether a leveraged order remains in the liquidation index. One-x
/// orders are never indexed and always return false.
public(package) fun is_active_order(exposure: &StrikeExposure, order: &Order): bool {
    exposure.liquidation.contains_active_order(order)
}

/// Price a range, choose quantity under the requested bias, and run mint
/// admission. Exact-quantity mode uses `min_quantity`. Budget mode uses a
/// conservative lot-rounded premium search, then requires the result to meet
/// `min_quantity`.
public(package) fun quote_mint_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    exact_quantity: bool,
    leverage: u64,
    clock: &Clock,
): MintTerms {
    let entry_probability = exposure.admitted_entry_probability(pricer, lower_tick, higher_tick);
    let time_to_expiry_ms = exposure.expiry_ms - clock.timestamp_ms();

    let quantity = if (exact_quantity) {
        min_quantity
    } else {
        // Validate policy before the search divides by leverage.
        exposure
            .config
            .assert_mint_probability_and_leverage_policy(
                entry_probability,
                leverage,
                time_to_expiry_ms,
            );
        // The single-floor probe overstates the admitted two-floor premium by at
        // most one unit. The configured probability floor keeps that difference
        // below one lot, so sizing never exceeds the budget and may undershoot the
        // largest admissible quantity by at most one lot.
        let lot = constants::position_lot_size!();
        let mut lo = 0;
        let mut hi = order::max_quantity_lots();
        while (lo < hi) {
            let mid = (lo + hi + 1) / 2;
            if (math::mul_div_down(entry_probability, mid * lot, leverage) <= max_premium) {
                lo = mid
            } else {
                hi = mid - 1
            }
        };
        lo * lot
    };
    assert!(quantity >= min_quantity, EMintQuantityBelowMin);

    let admission = exposure
        .config
        .assert_mint_admission(
            entry_probability,
            quantity,
            leverage,
            time_to_expiry_ms,
        );
    // Preserve the mutation path's validation order.
    order::assert_valid_quantity(quantity);
    MintTerms {
        expiry_market_id: exposure.expiry_market_id,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        entry_probability,
        net_premium: admission.net_premium(),
        floor_shares: admission.floor_shares(),
    }
}

/// Allocate a live mint order from priced terms: consume the expiry-local
/// sequence and insert the order into the liquidation and payout indexes.
/// Taking `terms` by value ties each allocation to exactly one admission
/// result, so the order's contract fields are always the ones that were priced,
/// and the market-identity assert rejects terms priced on another exposure.
public(package) fun allocate_mint_order(exposure: &mut StrikeExposure, terms: MintTerms): Order {
    let MintTerms { expiry_market_id, lower_tick, higher_tick, quantity, floor_shares, .. } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::new_from_ticks(
        lower_tick,
        higher_tick,
        floor_shares,
        quantity,
        sequence,
    );
    exposure.next_order_sequence = sequence + 1;

    exposure.liquidation.insert_order(&allocated_order);
    exposure.payout.insert_range(lower_tick, higher_tick, quantity, floor_shares);

    allocated_order
}

/// Quote the close of `order` in ANY state as compute-once close terms: the
/// single classifier for every close flow. Outcome precedence: the liquidated
/// state first (only the holder's position clear remains), then the settled
/// terminal payout from the recorded settlement, then liquidatable (knock-out
/// due) vs a priced live close — the only outcomes that need the pricer.
///
/// A `Pricer` is a live-phase capability: it is only constructible before
/// expiry and settlement is only recordable after it, so a caller holding one
/// proves the market is unsettled — the `Settled` arm is totality for
/// pricer-carrying callers, not a reachable branch.
public(package) fun quote_close(
    exposure: &StrikeExposure,
    pricer: Option<Pricer>,
    order: &Order,
    close_quantity: u64,
): CloseTerms {
    // The liquidated state is derived, not stored: every flow that removes an
    // order from the active index also removes its account position in the same
    // transaction, EXCEPT liquidation — so a leveraged order absent from the
    // index is liquidated (for a holder, one whose position still exists). 1x
    // orders are never indexed and can never be liquidated. Checked first:
    // liquidation already removed the order's book state, so no other outcome
    // can apply.
    if (order.is_leveraged() && !exposure.liquidation.contains_active_order(order)) {
        return exposure.close_terms(order, CloseOutcome::Liquidated)
    };
    if (exposure.is_settled()) {
        let payout = exposure.quote_settled_close(order);
        return exposure.close_terms(order, CloseOutcome::Settled { payout })
    };
    assert!(pricer.is_some(), EPricerRequired);
    // Price the range exactly once; the knock-out test and the live terms both
    // read this one observation.
    let range_probability = exposure.order_range_price(pricer.borrow(), order);
    let gross_value = math::mul(range_probability, order.quantity());
    // Leveraged only: a 1x order has a zero floor, so the threshold test would
    // spuriously classify a currently-worthless 1x order as liquidatable.
    if (
        order.is_leveraged() && exposure.under_liquidation_floor(gross_value, order.floor_shares())
    ) {
        return exposure.close_terms(order, CloseOutcome::Liquidatable { gross_value })
    };
    exposure.close_terms(
        order,
        CloseOutcome::Live(quote_live_close(order, close_quantity, range_probability)),
    )
}

/// Apply one quoted close to the book — the single close mutator, total over
/// every outcome. Consuming `terms` by value ties each application to exactly
/// one quote, and the market identity assert rejects terms quoted on another
/// exposure book. Returns the replacement order a partial live close leaves
/// behind. `pricer` and `clock` feed only the liquidatable arm's liquidation
/// event; a `Liquidatable` outcome is only constructible in the live phase, so
/// the pricer is present when that arm runs.
public(package) fun process_close(
    exposure: &mut StrikeExposure,
    pricer: Option<Pricer>,
    terms: CloseTerms,
    clock: &Clock,
): Option<Order> {
    let CloseTerms { expiry_market_id, order, outcome } = terms;
    assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);
    match (outcome) {
        // Liquidation already removed the order's book state; only the
        // holder's account position remains, and the flow owns that.
        CloseOutcome::Liquidated => option::none(),
        CloseOutcome::Liquidatable { gross_value } => {
            exposure.apply_liquidation(
                pricer.borrow(),
                &order,
                gross_value,
                clock.timestamp_ms(),
            );
            option::none()
        },
        CloseOutcome::Live(live) => exposure.process_live_close(&order, live),
        CloseOutcome::Settled { payout } => {
            exposure.process_settled_close(&order, payout);
            option::none()
        },
    }
}

/// Price and conditionally remove one bounded batch of liquidation candidates.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    budget: u64,
    clock: &Clock,
): u64 {
    let candidates = exposure.liquidation.select_liquidation_candidates(budget);
    if (candidates.is_empty()) return 0;
    let liquidated_at_ms = clock.timestamp_ms();

    let mut liquidated_count = 0;
    candidates.do!(|candidate| {
        let order = order::from_order_id(candidate);
        let liquidated = exposure.liquidate_order_if_under_floor(
            pricer,
            &order,
            liquidated_at_ms,
        );
        if (liquidated) {
            liquidated_count = liquidated_count + 1;
        };
    });
    liquidated_count
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
    expiry_ms: u64,
    tick_size: u64,
    admission_tick_size: u64,
    reference_tick_source_timestamp_ms: u64,
    config: StrikeExposureConfig,
    ctx: &mut TxContext,
): StrikeExposure {
    StrikeExposure {
        expiry_market_id,
        expiry_ms,
        tick_size,
        admission_tick_size,
        reference_tick_source_timestamp_ms,
        reference_tick: option::none(),
        config,
        next_order_sequence: 0,
        settlement_price: option::none(),
        settled_payout_liability: 0,
        liquidation: liquidation_book::new(ctx),
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
    // Trade path: abort if the entry price is too imprecise to execute at.
    pricer.range_price_checked(lower, higher)
}

fun assert_admitted_mint_ticks(exposure: &StrikeExposure, lower_tick: u64, higher_tick: u64) {
    let admission_multiple = exposure.admission_tick_size / exposure.tick_size;
    assert!(
        lower_tick == 0
            || lower_tick % admission_multiple == 0
            || exposure.reference_tick.contains(&lower_tick),
        EInvalidAdmissionTick,
    );
    assert!(
        higher_tick == constants::pos_inf_tick!()
            || higher_tick % admission_multiple == 0
            || exposure.reference_tick.contains(&higher_tick),
        EInvalidAdmissionTick,
    );
}

fun live_terms(terms: &CloseTerms): &LiveCloseTerms {
    match (&terms.outcome) {
        CloseOutcome::Live(live) => live,
        _ => abort EWrongCloseOutcome,
    }
}

fun close_terms(exposure: &StrikeExposure, order: &Order, outcome: CloseOutcome): CloseTerms {
    CloseTerms { expiry_market_id: exposure.expiry_market_id, order: *order, outcome }
}

/// Quote one settled order's terminal payout against the recorded settlement:
/// `quantity - floor_shares` for a win, zero for a loss. A pure read; aborts
/// while the exposure is live.
fun quote_settled_close(exposure: &StrikeExposure, order: &Order): u64 {
    let settlement_price = exposure.settlement_price();
    let won = range_codec::settlement_in_range(
        order.lower_tick(),
        order.higher_tick(),
        settlement_price,
        exposure.tick_size,
    );
    if (!won) {
        return 0
    };
    order.quantity() - order.floor_shares()
}

/// Quote one prospective live close as pure terms from the already-priced
/// range probability: the floor-share split and the redeem facts, touching
/// neither the book nor the oracle. The trade fee is recovered via
/// `trading_fee` from the returned `range_probability`.
fun quote_live_close(order: &Order, close_quantity: u64, range_probability: u64): LiveCloseTerms {
    order::assert_valid_quantity(close_quantity);
    let old_quantity = order.quantity();
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);

    // Round survivor floor down so `floor_shares <= quantity` holds by
    // construction; the closed slice carries the conserved floor-share dust.
    // Rounding down also keeps the survivor's floor ratio at or below the
    // original's, so a partial close can never move the survivor closer to
    // knockout.
    let old_floor_shares = order.floor_shares();
    let remaining_quantity = old_quantity - close_quantity;
    let remaining_floor_shares = math::mul_div_down(
        old_floor_shares,
        remaining_quantity,
        old_quantity,
    );
    let remove_floor_shares = old_floor_shares - remaining_floor_shares;

    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    // Clamp, don't abort: a full close cannot saturate (a non-knocked-out order's
    // gross value strictly exceeds its full floor), but a partial close's slice
    // can owe up to one unit of round-down dust more floor than its own gross
    // value; the shortfall stays in expiry cash.
    let redeem_amount = gross_redeem_amount.saturating_sub(remove_floor_shares);

    LiveCloseTerms {
        close_quantity,
        remove_floor_shares,
        redeem_amount,
        range_probability,
    }
}

/// Apply one quoted settled close to the book: remove the order from the live
/// index and release its quoted payout from the settled liability.
fun process_settled_close(exposure: &mut StrikeExposure, order: &Order, payout: u64) {
    exposure.liquidation.remove_order(order);
    // Settlement liability and individual payouts use the same integer quantity
    // and floor atoms, so the subtraction is additive without rounding dust.
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;
}

/// Apply one quoted live close to the book: remove the closed slice from the
/// payout and liquidation indexes and, for a partial close, insert and return
/// the replacement order that remains.
fun process_live_close(
    exposure: &mut StrikeExposure,
    order: &Order,
    terms: LiveCloseTerms,
): Option<Order> {
    let LiveCloseTerms { close_quantity, remove_floor_shares, .. } = terms;

    exposure
        .payout
        .remove_range(
            order.lower_tick(),
            order.higher_tick(),
            close_quantity,
            remove_floor_shares,
        );
    exposure.liquidation.remove_order(order);

    // The survivor keeps exactly what the closed slice did not remove:
    // conservation by construction, with `order::replacement` re-validating
    // the derived floor against the derived quantity.
    let remaining_quantity = order.quantity() - close_quantity;
    if (remaining_quantity == 0) {
        return option::none()
    };
    let remaining_floor_shares = order.floor_shares() - remove_floor_shares;

    let replacement_order = order::replacement(
        order,
        remaining_quantity,
        remaining_floor_shares,
        exposure.next_order_sequence,
    );
    exposure.liquidation.insert_order(&replacement_order);
    exposure.next_order_sequence = exposure.next_order_sequence + 1;

    option::some(replacement_order)
}

/// Liquidate (knock out) `order` when `under_liquidation_floor` holds.
fun liquidate_order_if_under_floor(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    liquidated_at_ms: u64,
): bool {
    let gross_value = exposure.gross_order_value(pricer, order);
    if (!exposure.under_liquidation_floor(gross_value, order.floor_shares())) return false;

    exposure.apply_liquidation(pricer, order, gross_value, liquidated_at_ms);
    true
}

/// The single liquidation mutation: remove the order's full `(quantity, floor)`
/// terms from the active index and the payout tree, and emit the liquidation
/// event atomically with the removal. Shared by the close flow
/// (`process_close`) and the ambient sweep, so the book, tree, and event can
/// never diverge. Callers own the liquidation decision; only leveraged orders
/// reach here — the classifier by its explicit guard, the sweep because the
/// active index holds exactly the leveraged orders (1x inserts are no-ops).
fun apply_liquidation(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    gross_value: u64,
    liquidated_at_ms: u64,
) {
    exposure.liquidation.remove_order(order);
    exposure
        .payout
        .remove_range(
            order.lower_tick(),
            order.higher_tick(),
            order.quantity(),
            order.floor_shares(),
        );

    order_events::emit_order_liquidated(
        exposure.expiry_market_id,
        order,
        pricer,
        gross_value,
        exposure.config.liquidation_ltv(),
        liquidated_at_ms,
    );
}

fun gross_order_value(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): u64 {
    math::mul(exposure.order_range_price(pricer, order), order.quantity())
}

/// Return whether live gross value is at or below the configured multiple of the
/// static floor. The reserve independently backs the order's full net payout.
fun under_liquidation_floor(exposure: &StrikeExposure, gross_value: u64, floor_amount: u64): bool {
    gross_value <= math::div(floor_amount, exposure.config.liquidation_ltv())
}

fun order_range_price(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): u64 {
    pricer.range_price(
        range_codec::strike_from_tick(order.lower_tick(), exposure.tick_size),
        range_codec::strike_from_tick(order.higher_tick(), exposure.tick_size),
    )
}
