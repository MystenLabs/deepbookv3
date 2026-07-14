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
    strike_exposure_config::{Self, StrikeExposureConfig},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use fixed_math::math;
use sui::clock::Clock;

const EInvalidCloseQuantity: u64 = 0;
const EInvalidAdmissionTick: u64 = 1;
const EInvalidReferenceTick: u64 = 2;
const EReferenceTickAlreadySet: u64 = 3;
const ETermsExposureMismatch: u64 = 4;

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
    /// Remaining settled liability after settlement has been materialized.
    settled_payout_liability: u64,
    /// True once `settled_payout_liability` has been materialized.
    settled_liability_materialized: bool,
    liquidation: LiquidationBook,
    /// Sparse payout tree for live cash backing and settled liability.
    payout: StrikePayoutTree,
}

/// Pure mint terms for one prospective live mint: the priced tick range,
/// quantity, and leverage, plus the admission results they produced. Built only
/// by the in-module terms constructors — `quote_mint_terms` (quantity intent)
/// and `quote_mint_terms_for_amount` (budget intent), one full constructor per
/// user intent — and consumed by value in `allocate_mint_order`, so one terms
/// value backs at most one allocation and allocation can never see inputs that
/// differ from the priced ones. Terms carry the pricing exposure's market
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

/// Redeem terms from closing live indexed quantity. `resulting_order` is the
/// original order for a full close, or the replacement that remains after a
/// partial close.
public struct CloseQuote has drop {
    resulting_order: Order,
    redeem_amount: u64,
    range_probability: u64,
}

/// Priced close outcome for one live order — the complete pricing-derived
/// outcome space of "close this order at the current price": a survivor closes
/// at the quoted probability, an under-floor leveraged order knocks out. Built
/// only by `quote_live_close_terms` and consumed by value in `close_live_order`,
/// so the applied transition is always the one that was priced and each terms
/// value backs at most one close. Carries the pricing exposure's market
/// identity; consumption asserts it, so terms cannot cross exposure books.
public enum LiveCloseTerms has drop {
    /// Live value at or under the knock-out threshold: full close at zero payout.
    KnockedOut { expiry_market_id: ID, order: Order, gross_value: u64 },
    /// Surviving order: closes at the quoted per-contract probability.
    LiveClose { expiry_market_id: ID, order: Order, range_probability: u64 },
}

public(package) fun is_knocked_out(terms: &LiveCloseTerms): bool {
    match (terms) {
        LiveCloseTerms::KnockedOut { .. } => true,
        LiveCloseTerms::LiveClose { .. } => false,
    }
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

public(package) fun resulting_order(quote: &CloseQuote): Order {
    quote.resulting_order
}

public(package) fun redeem_amount(quote: &CloseQuote): u64 {
    quote.redeem_amount
}

public(package) fun range_probability(quote: &CloseQuote): u64 {
    quote.range_probability
}

/// Return the buffered live reserve, or exact remaining settled payout liability once materialized.
///
/// Live reserve is the settlement floor (max single-point net payout) plus a
/// configured fraction of the disjoint-book gap. Lambda at 1.0 reproduces the
/// old summed reserve because `math::mul(1_000_000_000, gap) == gap`.
public(package) fun payout_liability(exposure: &StrikeExposure): u64 {
    if (exposure.settled_liability_materialized) {
        exposure.settled_payout_liability
    } else {
        let (max_net_payout, total_net_payout) = exposure.payout.net_payout_reserve_terms();
        // The point max is a subset-sum of the same non-negative per-order net payouts.
        let gap = total_net_payout - max_net_payout;
        max_net_payout + math::mul(exposure.config.backing_buffer_lambda(), gap)
    }
}

/// Value this book's exact live liability for one live price snapshot:
/// `linear - correction`, where `linear = Σ_orders qty·P` is the full payout-tree
/// walk and `correction = Σ_leveraged min(qty·P, floor_shares)` is the static-floor
/// scan over the active leveraged set. The per-order floor cap makes a knocked-out
/// leveraged order net to zero, so no liquidation pass is needed for an exact mark.
/// `correction <= linear` for any mint-admitted book (each leveraged order's `min`
/// is capped at its own linear contribution), so the saturating_sub floors only the
/// bounded valuation ulp dust the linear walk can carry, rather than aborting. A
/// pure read returning the liability fact; the caller owns the NAV/cash clamp.
///
/// The linear walk prices every tree node once into `memo`; the correction reads
/// each leveraged order's boundary prices back from it, so no order is re-priced.
public(package) fun exact_live_liability(exposure: &StrikeExposure, pricer: &Pricer): u64 {
    let mut memo = pricing::new_price_memo();
    // Linear term: the full payout-tree walk, caching each boundary's price.
    let linear = exposure.payout.walk_linear(pricer, &mut memo, exposure.tick_size);
    // Correction term: the static-floor-capped scan, reading prices from the cache.
    let correction = exposure.liquidation.correction_value(&memo);
    linear.saturating_sub(correction)
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

/// Return whether an order has already been liquidated from live indexes.
public(package) fun is_liquidated_order(exposure: &StrikeExposure, order: &Order): bool {
    exposure.liquidation.is_liquidated(order)
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
        settled_payout_liability: 0,
        settled_liability_materialized: false,
        liquidation: liquidation_book::new(ctx),
        payout: strike_payout_tree::new(ctx),
    }
}

/// Close one settled order and return the user payout.
public(package) fun close_settled_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    exposure.liquidation.remove_order(order);
    let won = range_codec::settlement_in_range(
        order.lower_tick(),
        order.higher_tick(),
        settlement,
        exposure.tick_size,
    );
    if (!won) {
        return 0
    };
    // payout = quantity - floor_shares (= Q - F). The settled liability was derived
    // from the payout tree's same aggregate atoms, so reserve == payout and the
    // subtraction cannot underflow (R1 liveness). The static floor makes the terms
    // exactly additive, so this holds with no dust buffer.
    let payout = order.quantity() - order.floor_shares();
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;

    payout
}

/// Quote the pure mint terms for the tick range `(lower_tick, higher_tick]`
/// without touching the exposure book: entry pricing, mint admission, and the
/// derived premium/floor. Shares every admission abort with the mint path,
/// including lot-size validity, so a quote aborts exactly when the mint-side
/// terms computation would.
public(package) fun quote_mint_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
): MintTerms {
    let entry_probability = exposure.admitted_entry_probability(pricer, lower_tick, higher_tick);
    exposure.priced_mint_terms(lower_tick, higher_tick, quantity, leverage, entry_probability)
}

/// Budget-denominated sibling of `quote_mint_terms`: full terms for the largest
/// lot-aligned quantity whose net premium fits `amount`, clamped to the max
/// order size. Prices the range once and runs the same full admission as the
/// quantity path — the terms gate covers both mint intents, so no flow needs a
/// priced fact before the gate.
public(package) fun quote_mint_terms_for_amount(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    amount: u64,
    leverage: u64,
): MintTerms {
    let entry_probability = exposure.admitted_entry_probability(pricer, lower_tick, higher_tick);
    let raw_quantity = strike_exposure_config::max_quantity_for_net_premium(
        entry_probability,
        amount,
        leverage,
    );
    let lots = (raw_quantity / constants::position_lot_size!()).min(order::max_quantity_lots());
    let quantity = lots * constants::position_lot_size!();
    exposure.priced_mint_terms(lower_tick, higher_tick, quantity, leverage, entry_probability)
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

/// Set the reference fine-grid tick that can bypass coarser mint admission once wired.
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

/// Return the live holder value of a full order close, gross of fees.
///
/// Already-liquidated and currently-liquidatable orders have zero holder value;
/// otherwise this returns the order's current range value net of its static floor.
public(package) fun order_value(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): u64 {
    if (exposure.is_liquidated_order(order)) return 0;

    let gross_value = exposure.gross_order_value(pricer, order);
    let floor_amount = order.floor_shares();
    if (under_liquidation_floor(gross_value, floor_amount, exposure.config.liquidation_ltv())) {
        return 0
    };

    // Exact: threshold = floor(F / ltv) >= F since the ltv setter envelope caps
    // ltv at 0.95e9 < 1e9, so the guard above proves gross_value > floor_amount.
    gross_value - floor_amount
}

/// Price one live order once and classify the complete close outcome. Pure: the
/// flow applies its close policies (full-close-on-knockout, the same-timestamp
/// guard, slippage floors) between this quote and `close_live_order`. Knock-out
/// classification applies only to orders in the active liquidation index (a 1x
/// order has no floor and always closes live).
public(package) fun quote_live_close_terms(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    order: &Order,
): LiveCloseTerms {
    let (lower, higher) = exposure.order_boundaries(order);
    let range_probability = pricer.range_price(lower, higher);
    if (exposure.liquidation.contains_active_order(order)) {
        let gross_value = math::mul(range_probability, order.quantity());
        let liquidation_ltv = exposure.config.liquidation_ltv();
        if (under_liquidation_floor(gross_value, order.floor_shares(), liquidation_ltv)) {
            return LiveCloseTerms::KnockedOut {
                expiry_market_id: exposure.expiry_market_id,
                order: *order,
                gross_value,
            }
        };
    };
    LiveCloseTerms::LiveClose {
        expiry_market_id: exposure.expiry_market_id,
        order: *order,
        range_probability,
    }
}

/// Apply one priced close outcome and return the redeem terms. A knock-out
/// removes the full order at zero payout and emits `OrderLiquidated` with no
/// tombstone — the holder is redeeming in this same transaction, so the
/// tombstone would be cleared immediately; a live close removes the closed
/// slice at the quoted probability. Consuming by value ties each priced
/// outcome to at most one applied transition.
public(package) fun close_live_order(
    exposure: &mut StrikeExposure,
    terms: LiveCloseTerms,
    close_quantity: u64,
): CloseQuote {
    match (terms) {
        LiveCloseTerms::KnockedOut { expiry_market_id, order, gross_value } => {
            assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);
            let liquidation_ltv = exposure.config.liquidation_ltv();
            exposure.liquidation.remove_order(&order);
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
                &order,
                gross_value,
                liquidation_ltv,
            );
            CloseQuote { resulting_order: order, redeem_amount: 0, range_probability: 0 }
        },
        LiveCloseTerms::LiveClose { expiry_market_id, order, range_probability } => {
            assert!(expiry_market_id == exposure.expiry_market_id, ETermsExposureMismatch);
            exposure.close_priced_live_order(&order, close_quantity, range_probability)
        },
    }
}

/// Clear one liquidated-order tombstone after its account position is closed.
public(package) fun clear_liquidated_order(exposure: &mut StrikeExposure, order: &Order) {
    exposure.liquidation.clear_liquidated(order);
}

/// Try to liquidate one active leveraged order using exact live pricing.
public(package) fun liquidate_live_order(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
): bool {
    if (!exposure.liquidation.contains_active_order(order)) return false;
    let liquidation_ltv = exposure.config.liquidation_ltv();
    exposure.liquidate_order_if_under_floor(pricer, order, liquidation_ltv)
}

/// Run one bounded liquidation pass using exact per-candidate pricing.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    budget: u64,
): u64 {
    let candidates = exposure.liquidation.select_liquidation_candidates(budget);
    if (candidates.is_empty()) return 0;
    let liquidation_ltv = exposure.config.liquidation_ltv();

    let mut liquidated_count = 0;
    candidates.do!(|candidate| {
        let order = order::from_order_id(candidate);
        let liquidated = exposure.liquidate_order_if_under_floor(pricer, &order, liquidation_ltv);
        if (liquidated) {
            liquidated_count = liquidated_count + 1;
        };
    });
    liquidated_count
}

/// Cache terminal settled payout liability.
///
/// The live payout tree is retained after caching because nothing deletes it —
/// no compaction path exists; post-materialization it is never read or mutated
/// (settled redeems touch only the liquidation book and the cached liability).
/// This retained storage is an input to the H-6 compaction decision.
public(package) fun materialize_settled_liability(
    exposure: &mut StrikeExposure,
    settlement: u64,
): u64 {
    if (exposure.settled_liability_materialized) {
        return exposure.settled_payout_liability
    };

    let settled_liability = exposure
        .payout
        .settled_payout_liability(settlement, exposure.tick_size);
    exposure.settled_payout_liability = settled_liability;
    exposure.settled_liability_materialized = true;
    settled_liability
}

fun gross_order_value(exposure: &StrikeExposure, pricer: &Pricer, order: &Order): u64 {
    let (lower, higher) = exposure.order_boundaries(order);
    let range_probability = pricer.range_price(lower, higher);
    math::mul(range_probability, order.quantity())
}

/// The knock-out predicate — the single home of the threshold test every
/// liquidation and close-classification site uses: live value at or under
/// `floor / liquidation_ltv`. Callers on candidate loops hoist the ltv.
fun under_liquidation_floor(gross_value: u64, floor_amount: u64, liquidation_ltv: u64): bool {
    gross_value <= math::div(floor_amount, liquidation_ltv)
}

/// Close live indexed quantity at an already-quoted probability and return the
/// redeem terms. `resulting_order` is the original order for a full close, or
/// the replacement that remains after a partial close. The trade fee is
/// recovered via `trading_fee` from the returned `range_probability`.
fun close_priced_live_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    close_quantity: u64,
    range_probability: u64,
): CloseQuote {
    order::assert_valid_quantity(close_quantity);
    let old_quantity = order.quantity();
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);

    let old_floor_shares = order.floor_shares();
    let remaining_quantity = old_quantity - close_quantity;
    let remaining_floor_shares = math::mul_div_down(
        old_floor_shares,
        remaining_quantity,
        old_quantity,
    );
    let remove_floor_shares = old_floor_shares - remaining_floor_shares;

    // Round survivor floor down so `floor_shares <= quantity` holds by
    // construction; the closed slice carries the conserved floor-share dust.
    exposure
        .payout
        .remove_range(
            order.lower_tick(),
            order.higher_tick(),
            close_quantity,
            remove_floor_shares,
        );
    exposure.liquidation.remove_order(order);

    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let redeem_amount = gross_redeem_amount.saturating_sub(remove_floor_shares);

    if (remaining_quantity == 0) {
        return CloseQuote { resulting_order: *order, redeem_amount, range_probability }
    };

    let replacement_order = order::replacement(
        order,
        remaining_quantity,
        remaining_floor_shares,
        exposure.next_order_sequence,
    );
    exposure.liquidation.insert_order(&replacement_order);
    exposure.next_order_sequence = exposure.next_order_sequence + 1;

    CloseQuote { resulting_order: replacement_order, redeem_amount, range_probability }
}

/// Liquidate (knock out) `order` when its live value has reached the static floor:
/// `qty·P <= floor_shares / liquidation_ltv`. The LTV buffer is the anti-arbitrage
/// enforcement margin — knock out a hair before zero equity so a missed barrier
/// touch can't be monetized; the reserve already backs the full `Q - F`, so this is
/// not a solvency margin.
fun liquidate_order_if_under_floor(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    liquidation_ltv: u64,
): bool {
    let quantity = order.quantity();
    let floor_amount = order.floor_shares();
    let gross_value = exposure.gross_order_value(pricer, order);
    if (!under_liquidation_floor(gross_value, floor_amount, liquidation_ltv)) return false;

    exposure.liquidation.mark_liquidated(order);
    exposure
        .payout
        .remove_range(
            order.lower_tick(),
            order.higher_tick(),
            quantity,
            floor_amount,
        );

    order_events::emit_order_liquidated(
        exposure.expiry_market_id,
        order,
        gross_value,
        liquidation_ltv,
    );

    true
}

/// Decode an order into `(lower, higher)` raw strike boundaries for pricing and
/// settlement comparison, mapping the open-ended sentinels.
fun order_boundaries(exposure: &StrikeExposure, order: &Order): (u64, u64) {
    range_codec::strikes_from_ticks(order.lower_tick(), order.higher_tick(), exposure.tick_size)
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
    let (lower, higher) = range_codec::strikes_from_ticks(
        lower_tick,
        higher_tick,
        exposure.tick_size,
    );
    pricer.range_price(lower, higher)
}

/// Shared tail of the terms constructors: full mint admission over an
/// already-priced entry probability, then the terms value.
fun priced_mint_terms(
    exposure: &StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    entry_probability: u64,
): MintTerms {
    let admission = exposure
        .config
        .assert_mint_admission(
            entry_probability,
            quantity,
            leverage,
        );
    // Runs after admission so the quote path keeps mint's abort order (mint hits
    // this check inside order construction, after admission).
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
