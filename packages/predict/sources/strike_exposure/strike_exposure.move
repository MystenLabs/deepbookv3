// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local exposure book for one expiry market.
///
/// This module interprets `Order` terms against the expiry's `tick_size` and
/// floor-index schedule, recovering raw strikes from order ticks only at the
/// pricing/settlement boundary. It owns the payout-liability view of the active
/// contracts used for cash backing. It stores the parent market identity so
/// market-scoped liquidation events can be emitted atomically with exposure
/// removal. Expiry-market cash custody, rebate accounting, manager positions,
/// and payout movement stay outside this module.
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
    /// Terminal timestamp used by floor-index and order floor math.
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
    /// Sum of live backing payouts for active orders; prices the buffer above the max-point floor.
    live_backing_liability: u64,
}

/// Return the buffered live reserve, or exact remaining settled payout liability once materialized.
///
/// Live reserve is the settlement floor (max single-point backing) plus a
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
/// walk and `correction = Σ_leveraged min(qty·P, floor_shares·index_now)` is the
/// scan over the active leveraged set. The per-order floor cap makes an underwater
/// leveraged order net to zero, so no liquidation pass is needed. `correction <=
/// linear` for any mint-admitted book (each leveraged order's `min` is capped at
/// its own linear contribution, which the boundary aggregation only raises), so the
/// saturating_sub is a no-op there; it floors the bounded valuation ulp dust the
/// linear walk can carry — or that an enabled interpolation tolerance can introduce
/// — rather than aborting. A pure read returning the liability fact; the caller
/// owns the NAV/cash clamp.
public(package) fun exact_live_liability(
    exposure: &StrikeExposure,
    pricer: &Pricer,
    clock: &Clock,
): u64 {
    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    // Linear term: the full payout-tree walk. Interpolation is gated by the
    // upgrade-required `nav_interpolation_price_tolerance` (0 = fully exact).
    let linear = exposure
        .live
        .payout
        .walk_linear(pricer, exposure.tick_size, constants::nav_interpolation_price_tolerance!());
    // Correction term: the floor-capped scan over this book's active leveraged set.
    let correction = exposure.liquidation.correction_value(pricer, exposure.tick_size, index_now);
    linear.saturating_sub(correction)
}

/// Return the terminal floor index snapshotted for this exposure book.
public(package) fun terminal_floor_index(exposure: &StrikeExposure): u64 {
    exposure.config.terminal_floor_index()
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
    let quantity = order.quantity();
    // payout = quantity - floor(floor_shares * terminal_floor_index); rounds down,
    // winner eats <=1 ulp. The reserve seeded into settled_payout_liability (the
    // payout tree's terminal_payout, via materialize_settled_liability) is the
    // same canonical `terminal_payout` evaluation by construction: mint insert
    // and partial-close reinsert price through it, so reserve == payout and the
    // subtraction below cannot underflow (R1 liveness).
    let payout = exposure.config.terminal_payout(quantity, order.floor_shares());
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
    let (net_premium, financed_amount) = exposure
        .config
        .assert_mint_admission_policy(
            exposure.expiry_ms,
            opened_at_ms,
            entry_probability,
            quantity,
            leverage,
        );
    let (floor_shares, terminal_payout, live_backing_payout) = exposure
        .config
        .assert_mint_floor_terms(
            exposure.expiry_ms,
            opened_at_ms,
            financed_amount,
            quantity,
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
    exposure.insert_live_index_quantity(
        lower_tick,
        higher_tick,
        quantity,
        terminal_payout,
        live_backing_payout,
    );

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
    clock: &Clock,
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

    // Remove the order's FULL live-index terms (bit-equal to the mint insert),
    // then reinsert the survivor's exact terms below. Removing only the closed
    // slice would leave the payout tree's residual 1 ulp short of what
    // `close_settled_order` recomputes at settlement (round-down `mul` is
    // sub-additive over the floor-share split: `mul(old_fs,T) >=
    // mul(remove_fs,T) + mul(remaining_fs,T)`), underflowing the settled redeem.
    exposure.remove_live_index_quantity(order, old_quantity, old_floor_shares);
    exposure.liquidation.remove_order(order);

    // calculate payout
    let range_probability = pricer.range_price(lower, higher);
    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    // Live redeem outflow rounds toward the pool (R2): the gross rounds DOWN and
    // the floor deduction (subtrahend) rounds UP, so redeem_amount <= the exact
    // live value `prob*qty - fs*index` and the user eats <=1 ulp. saturating_sub
    // floors it at 0 (R1: no underflow). Rounding the deduction up is solvency-safe
    // here because `removed_floor_amount` backs no stored reserve — unlike the
    // settled C1 path, where the deduction must round down to stay bit-equal to the
    // payout tree.
    let removed_floor_amount = math::mul_div_up(
        remove_floor_shares,
        index_now,
        math::float_scaling!(),
    );
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
    exposure.reinsert_live_index_quantity(
        &replacement_order,
        remaining_quantity,
        remaining_floor_shares,
    );
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
    clock: &Clock,
): bool {
    if (!exposure.liquidation.contains_active_order(order)) return false;

    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    let liquidation_ltv = exposure.config.liquidation_ltv();
    exposure.liquidate_order_if_under_floor(
        pricer,
        order,
        index_now,
        liquidation_ltv,
    )
}

/// Run one bounded liquidation pass using exact per-candidate pricing.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    budget: u64,
    clock: &Clock,
): u64 {
    let candidates = exposure.liquidation.select_liquidation_candidates(budget);
    if (candidates.is_empty()) return 0;
    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    let liquidation_ltv = exposure.config.liquidation_ltv();

    let mut liquidated_count = 0;
    let mut i = 0;
    while (i < candidates.length()) {
        let order = order::from_order_id(candidates[i]);
        let liquidated = exposure.liquidate_order_if_under_floor(
            pricer,
            &order,
            index_now,
            liquidation_ltv,
        );
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
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    let live = &mut exposure.live;
    live
        .payout
        .insert_range(lower_tick, higher_tick, quantity, terminal_payout, live_backing_payout);
    live.live_backing_liability = live.live_backing_liability + live_backing_payout;
}

fun liquidate_order_if_under_floor(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    order: &Order,
    index_now: u64,
    liquidation_ltv: u64,
): bool {
    let quantity = order.quantity();
    let (lower, higher) = exposure.order_boundaries(order);
    let range_probability = pricer.range_price(lower, higher);
    let floor_shares = order.floor_shares();
    let current_floor_amount = math::mul(floor_shares, index_now);
    let gross_value = math::mul(range_probability, quantity);
    let liquidation_threshold = math::div(current_floor_amount, liquidation_ltv);
    let can_liquidate = gross_value <= liquidation_threshold;
    if (!can_liquidate) return false;

    exposure.liquidation.mark_liquidated(order);
    exposure.remove_live_index_quantity(order, quantity, floor_shares);

    order_events::emit_order_liquidated(
        exposure.expiry_market_id,
        order,
        quantity,
        gross_value,
        current_floor_amount,
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
    let (terminal_payout, live_backing_payout) = exposure
        .config
        .index_terms(
            exposure.expiry_ms,
            order.opened_at_ms(),
            quantity,
            floor_shares,
        );
    let live = &mut exposure.live;
    live
        .payout
        .remove_range(
            order.lower_tick(),
            order.higher_tick(),
            quantity,
            terminal_payout,
            live_backing_payout,
        );
    live.live_backing_liability = live.live_backing_liability - live_backing_payout;
}

/// Reinsert a partial-close survivor's exact live-index terms, mirroring the
/// mint insert so the payout tree's residual is bit-equal to what
/// `close_settled_order` recomputes for this order at settlement.
fun reinsert_live_index_quantity(
    exposure: &mut StrikeExposure,
    order: &Order,
    quantity: u64,
    floor_shares: u64,
) {
    let (terminal_payout, live_backing_payout) = exposure
        .config
        .index_terms(
            exposure.expiry_ms,
            order.opened_at_ms(),
            quantity,
            floor_shares,
        );
    exposure.insert_live_index_quantity(
        order.lower_tick(),
        order.higher_tick(),
        quantity,
        terminal_payout,
        live_backing_payout,
    );
}

/// Decode an order into `(lower, higher)` raw strike boundaries for pricing and
/// settlement comparison, mapping the open-ended sentinels.
fun order_boundaries(exposure: &StrikeExposure, order: &Order): (u64, u64) {
    range_codec::strikes_from_ticks(order.lower_tick(), order.higher_tick(), exposure.tick_size)
}
