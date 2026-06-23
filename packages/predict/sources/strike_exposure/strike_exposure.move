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
/// cash custody, rebate accounting, manager positions, and payout movement stay
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

/// Exposure lifecycle state for one expiry market.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Terminal timestamp used by fee and settlement math.
    expiry_ms: u64,
    /// Raw-price-per-tick conversion factor; `raw_strike = tick * tick_size`.
    tick_size: u64,
    /// Snapshotted exposure and fee policy for this expiry.
    config: StrikeExposureConfig,
    next_order_sequence: u64,
    /// Remaining settled liability after settlement has been materialized.
    settled_payout_liability: u64,
    /// True once `settled_payout_liability` has been materialized.
    settled_liability_materialized: bool,
    liquidation: LiquidationBook,
    live: LiveExposure,
}

/// Live exposure index: the sparse payout tree for cash backing.
public struct LiveExposure has store {
    payout: StrikePayoutTree,
    /// Sum of net payouts for active orders; prices the buffer above the max-point floor.
    live_backing_liability: u64,
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
        let live = &exposure.live;
        let max_live = live.payout.max_live_backing_payout();
        // The point max is a subset-sum of the same non-negative per-order backings.
        let gap = live.live_backing_liability - max_live;
        max_live + math::mul(exposure.config.backing_buffer_lambda(), gap)
    }
}

/// Value this book's exact live liability for one live price snapshot:
/// `linear - correction`, where `linear = Σ_orders qty·P` is the full payout-tree
/// walk and `correction = Σ_leveraged min(qty·P, floor_shares)` is the static-floor
/// scan over the active leveraged set. The per-order floor cap makes a knocked-out
/// leveraged order net to zero, so no liquidation pass is needed for an exact mark.
/// `correction <= linear` for any mint-admitted book (each leveraged order's `min`
/// is capped at its own linear contribution), so the saturating_sub floors only the
/// bounded valuation ulp dust the linear walk can carry — or that an enabled
/// interpolation tolerance can introduce — rather than aborting. A pure read
/// returning the liability fact; the caller owns the NAV/cash clamp.
public(package) fun exact_live_liability(exposure: &StrikeExposure, pricer: &Pricer): u64 {
    // Linear term: the full payout-tree walk. Interpolation is gated by the
    // upgrade-required `nav_interpolation_price_tolerance` (0 = fully exact).
    let linear = exposure
        .live
        .payout
        .walk_linear(pricer, exposure.tick_size, constants::nav_interpolation_price_tolerance!());
    // Correction term: the static-floor-capped scan over this book's leveraged set.
    let correction = exposure.liquidation.correction_value(pricer, exposure.tick_size);
    linear.saturating_sub(correction)
}

/// Return the liquidation LTV snapshotted for this exposure book.
public(package) fun liquidation_ltv(exposure: &StrikeExposure): u64 {
    exposure.config.liquidation_ltv()
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
    config: StrikeExposureConfig,
    ctx: &mut TxContext,
): StrikeExposure {
    StrikeExposure {
        expiry_market_id,
        expiry_ms,
        tick_size,
        config,
        next_order_sequence: 0,
        settled_payout_liability: 0,
        settled_liability_materialized: false,
        liquidation: liquidation_book::new(ctx),
        live: LiveExposure {
            payout: strike_payout_tree::new(ctx),
            live_backing_liability: 0,
        },
    }
}

/// Close one settled order and return the user payout.
public(package) fun close_settled_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    let (lower, higher) = exposure.order_boundaries(order);
    exposure.liquidation.remove_order(order);
    if (settlement <= lower || settlement > higher) {
        return 0
    };
    // payout = quantity - floor_shares (= Q - F). The reserve seeded into
    // settled_payout_liability is the same per-order `net_payout` the payout tree
    // stores (mint insert and partial-close removal use it), so reserve == payout
    // and the subtraction cannot underflow (R1 liveness). The static floor makes
    // `net_payout` exactly additive, so this holds with no dust buffer.
    let payout = net_payout(order.quantity(), order.floor_shares());
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;

    payout
}

/// Quote and allocate a live mint order for the tick range `(lower_tick, higher_tick]`.
///
/// Returns `(allocated_order, entry_probability, net_premium)`.
public(package) fun allocate_mint_order(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
): (Order, u64, u64) {
    let (lower, higher) = range_codec::strikes_from_ticks(
        lower_tick,
        higher_tick,
        exposure.tick_size,
    );
    let entry_probability = pricer.range_price(lower, higher);
    let opened_at_ms = clock.timestamp_ms();
    let (net_premium, floor_shares) = exposure
        .config
        .assert_mint_admission(
            exposure.expiry_ms,
            opened_at_ms,
            entry_probability,
            quantity,
            leverage,
        );

    let sequence = exposure.next_order_sequence;

    let allocated_order = order::new_from_ticks(
        opened_at_ms,
        lower_tick,
        higher_tick,
        floor_shares,
        quantity,
        sequence,
    );
    exposure.next_order_sequence = sequence + 1;

    exposure.liquidation.insert_order(&allocated_order);
    exposure.insert_live_index_quantity(lower_tick, higher_tick, quantity, floor_shares);

    (allocated_order, entry_probability, net_premium)
}

/// Close live indexed quantity and return redeem terms.
///
/// Returns `(resulting_order, redeem_amount, range_probability)`.
/// The trade fee is recovered via `trading_fee` from the returned price.
/// `resulting_order` is the original order for a full close, or the replacement
/// order that remains after a partial close.
public(package) fun close_and_quote_live_order(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    close_quantity: u64,
): (Order, u64, u64) {
    order::assert_valid_quantity(close_quantity);
    let old_quantity = order.quantity();
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);

    let (lower, higher) = exposure.order_boundaries(order);

    let old_floor_shares = order.floor_shares();
    let close_fraction = math::div(close_quantity, old_quantity);
    let remove_floor_shares = math::mul(old_floor_shares, close_fraction);
    let remaining_quantity = old_quantity - close_quantity;
    let remaining_floor_shares = old_floor_shares - remove_floor_shares;

    // Remove only the closed slice. Under the static floor `net_payout = q - fs` is
    // exactly additive over the split (`old_q - old_fs == (close_q - remove_fs) +
    // (remaining_q - remaining_fs)`, both q and fs split exactly), so the tree
    // residual is the survivor's exact `net_payout` with no full-remove/reinsert
    // dance and no 1-ulp underflow at settlement.
    exposure.remove_live_index_quantity(order, close_quantity, remove_floor_shares);
    exposure.liquidation.remove_order(order);

    let range_probability = pricer.range_price(lower, higher);
    // Live redeem = close_q*P - ceil(F * close_q/old_q), the static-floor equity of
    // the closed slice. The deduction rounds UP (R2: user eats <=1 ulp) and is
    // >= the tree's removed net_payout (`remove_floor_shares`, round-down), so the
    // redeem never exceeds the reserve released. saturating_sub floors at 0 (R1).
    let removed_floor_amount = math::mul_div_up(old_floor_shares, close_quantity, old_quantity);
    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let redeem_amount = gross_redeem_amount.saturating_sub(removed_floor_amount);

    if (remaining_quantity == 0) {
        return (*order, redeem_amount, range_probability)
    };

    let replacement_order = order::replacement(
        order,
        remaining_quantity,
        remaining_floor_shares,
        exposure.next_order_sequence,
    );
    exposure.liquidation.insert_order(&replacement_order);
    exposure.next_order_sequence = exposure.next_order_sequence + 1;

    (replacement_order, redeem_amount, range_probability)
}

/// Clear one liquidated-order tombstone after its manager position is closed.
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
    let mut i = 0;
    while (i < candidates.length()) {
        let order = order::from_order_id(candidates[i]);
        let liquidated = exposure.liquidate_order_if_under_floor(pricer, &order, liquidation_ltv);
        if (liquidated) {
            liquidated_count = liquidated_count + 1;
        };
        i = i + 1;
    };
    liquidated_count
}

/// Cache terminal settled payout liability.
///
/// The live payout tree is retained after caching (the settled-redeem path
/// still removes from it order by order).
public(package) fun materialize_settled_liability(
    exposure: &mut StrikeExposure,
    settlement: u64,
): u64 {
    if (exposure.settled_liability_materialized) {
        return exposure.settled_payout_liability
    };

    let settled_liability = exposure
        .live
        .payout
        .settled_payout_liability(settlement, exposure.tick_size);
    exposure.settled_payout_liability = settled_liability;
    exposure.settled_liability_materialized = true;
    settled_liability
}

fun insert_live_index_quantity(
    exposure: &mut StrikeExposure,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    floor_shares: u64,
) {
    let net_payout = net_payout(quantity, floor_shares);
    let live = &mut exposure.live;
    live.payout.insert_range(lower_tick, higher_tick, quantity, net_payout);
    live.live_backing_liability = live.live_backing_liability + net_payout;
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
    let (lower, higher) = exposure.order_boundaries(order);
    let range_probability = pricer.range_price(lower, higher);
    let floor_amount = order.floor_shares();
    let gross_value = math::mul(range_probability, quantity);
    let liquidation_threshold = math::div(floor_amount, liquidation_ltv);
    let can_liquidate = gross_value <= liquidation_threshold;
    if (!can_liquidate) return false;

    exposure.liquidation.mark_liquidated(order);
    exposure.remove_live_index_quantity(order, quantity, floor_amount);

    order_events::emit_order_liquidated(
        exposure.expiry_market_id,
        order,
        quantity,
        gross_value,
        floor_amount,
        liquidation_ltv,
    );

    true
}

fun remove_live_index_quantity(
    exposure: &mut StrikeExposure,
    order: &Order,
    quantity: u64,
    floor_shares: u64,
) {
    let net_payout = net_payout(quantity, floor_shares);
    let live = &mut exposure.live;
    live.payout.remove_range(order.lower_tick(), order.higher_tick(), quantity, net_payout);
    live.live_backing_liability = live.live_backing_liability - net_payout;
}

/// Canonical net payout for an order's atoms: `quantity - floor_shares = Q - F`.
/// The static floor makes this an exact subtraction, so mint insert, close-slice
/// remove, and settled recompute all produce bit-identical terms with no rounding.
fun net_payout(quantity: u64, floor_shares: u64): u64 {
    quantity - floor_shares
}

/// Decode an order into `(lower, higher)` raw strike boundaries for pricing and
/// settlement comparison, mapping the open-ended sentinels.
fun order_boundaries(exposure: &StrikeExposure, order: &Order): (u64, u64) {
    range_codec::strikes_from_ticks(order.lower_tick(), order.higher_tick(), exposure.tick_size)
}
