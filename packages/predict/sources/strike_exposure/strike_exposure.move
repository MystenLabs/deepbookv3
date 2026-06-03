// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local exposure book for one oracle grid.
///
/// This module interprets `Order` terms against the expiry's strike grid and
/// floor-index schedule. It owns two derived views of the same active contracts:
/// payout liability for cash backing, and live position liability for LP
/// valuation. It stores the parent market identity so market-scoped liquidation
/// events can be emitted atomically with exposure removal. Expiry-market cash
/// custody, rebate accounting, manager positions, and payout movement stay outside
/// this module.
module deepbook_predict::strike_exposure;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    liquidation_book::{Self, LiquidationBook},
    market_oracle::{MarketOracle, SVIParams},
    math as predict_math,
    order::{Self, Order},
    order_events,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_grid::StrikeGrid,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const ESettledLiabilityNotMaterialized: u64 = 0;
const ESettledLiabilityUnderflow: u64 = 1;
const EInvalidCloseQuantity: u64 = 2;
const ETerminalFloorExceedsLiquidationLtv: u64 = 3;
const EOrderBelowLiquidationThreshold: u64 = 4;
const EOrderPrincipalBelowMinimum: u64 = 5;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Terminal timestamp used by floor-index and order floor math.
    expiry_ms: u64,
    grid: StrikeGrid,
    /// Max increase of the floor index over this expiry's floor window.
    /// `200_000_000` means the index rises from 1.0 to 1.2 by expiry.
    max_expiry_floor_premium: u64,
    /// 1e9-scaled floor-to-live-value liquidation threshold snapshotted at creation.
    liquidation_ltv: u64,
    /// Window before expiry over which the trade fee ramps up. Snapshotted at creation.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING; 1x disables. Snapshotted at creation.
    expiry_fee_max_multiplier: u64,
    next_order_sequence: u64,
    /// Remaining settled liability after settlement has been materialized.
    settled_payout_liability: u64,
    /// True once `settled_payout_liability` has been materialized.
    settled_liability_materialized: bool,
    liquidation: LiquidationBook,
    live: Option<LiveExposure>,
}

/// Live exposure indexes composed from dense NAV and sparse payout storage.
public struct LiveExposure has store {
    nav: StrikeNavMatrix,
    payout: StrikePayoutTree,
    /// Monotonic strike range used to bound pricing-curve construction.
    /// Removes do not shrink this cache; a wider curve is safe but can cost more gas.
    minted_min_strike: u64,
    minted_max_strike: u64,
}

/// Return conservative max-live backing, or remaining settled payout liability once materialized.
public(package) fun payout_liability(exposure: &StrikeExposure): u64 {
    if (exposure.settled_liability_materialized) {
        exposure.settled_payout_liability
    } else {
        exposure.live.borrow().payout.max_live_backing_payout()
    }
}

/// Return the terminal floor-index premium snapshotted for this exposure book.
public(package) fun max_expiry_floor_premium(exposure: &StrikeExposure): u64 {
    exposure.max_expiry_floor_premium
}

/// Return the liquidation LTV snapshotted for this exposure book.
public(package) fun liquidation_ltv(exposure: &StrikeExposure): u64 {
    exposure.liquidation_ltv
}

public(package) fun expiry_fee_window_ms(exposure: &StrikeExposure): u64 {
    exposure.expiry_fee_window_ms
}

public(package) fun expiry_fee_max_multiplier(exposure: &StrikeExposure): u64 {
    exposure.expiry_fee_max_multiplier
}

public(package) fun min_strike(exposure: &StrikeExposure): u64 {
    exposure.grid.min_strike()
}

public(package) fun tick_size(exposure: &StrikeExposure): u64 {
    exposure.grid.tick_size()
}

public(package) fun max_strike(exposure: &StrikeExposure): u64 {
    exposure.grid.max_strike()
}

/// Evaluate live user-position liability over the current minted strike range.
public(package) fun valuation_liability(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    let live = exposure.live.borrow();
    let (minted_min_strike, minted_max_strike) = live.minted_strike_range();
    if (minted_min_strike == 0 && minted_max_strike == 0) {
        return 0
    };

    let (forward, svi) = pricing::live_inputs(config, market, pyth, clock);
    let curve = pricing::build_curve(
        &svi,
        forward,
        exposure.grid.tick_size(),
        minted_min_strike,
        minted_max_strike,
    );
    live
        .nav
        .live_value(
            &exposure.grid,
            &curve,
            minted_min_strike,
            minted_max_strike,
            exposure.floor_index_at_ms(clock.timestamp_ms()),
        )
}

/// Return whether an order has already been liquidated from live indexes.
public(package) fun is_liquidated_order(exposure: &StrikeExposure, order: &Order): bool {
    exposure.liquidation.is_liquidated(order)
}

/// Create a strike exposure book for the oracle grid.
public(package) fun new(
    expiry_market_id: ID,
    expiry_ms: u64,
    grid: StrikeGrid,
    preallocated_ticks: u64,
    max_expiry_floor_premium: u64,
    liquidation_ltv: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    ctx: &mut TxContext,
): StrikeExposure {
    StrikeExposure {
        expiry_market_id,
        expiry_ms,
        grid,
        max_expiry_floor_premium,
        liquidation_ltv,
        expiry_fee_window_ms,
        expiry_fee_max_multiplier,
        next_order_sequence: 0,
        settled_payout_liability: 0,
        settled_liability_materialized: false,
        liquidation: liquidation_book::new(ctx),
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(&grid, preallocated_ticks, ctx),
            payout: strike_payout_tree::new(ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
    }
}

/// Close one settled order and return the user payout.
public(package) fun close_settled_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    let user_payout = exposure.settled_order_payout(order, settlement);
    exposure.decrease_materialized_settled_liability(user_payout);
    exposure.liquidation.remove_order(order);
    user_payout
}

/// Quote and allocate a live mint order over this exposure book's strike grid.
///
/// Returns `(order, fee_amount)`.
public(package) fun allocate_mint_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
): (Order, u64) {
    let (lower_boundary_index, higher_boundary_index) = exposure.boundary_indices(lower, higher);
    let entry_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    order::assert_mint_leverage_tier(entry_probability, leverage);
    let fee_rate = pricing::assert_mint_fee_rate(
        config,
        market,
        exposure.expiry_fee_window_ms,
        exposure.expiry_fee_max_multiplier,
        entry_probability,
        clock,
    );
    let fee_amount = math::mul(fee_rate, quantity);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::new_from_boundary_indices(
        clock.timestamp_ms(),
        lower_boundary_index,
        higher_boundary_index,
        leverage,
        entry_probability,
        quantity,
        sequence,
    );
    assert!(
        allocated_order.user_contribution() >= constants::min_order_principal!(),
        EOrderPrincipalBelowMinimum,
    );
    exposure.next_order_sequence = sequence + 1;
    exposure.insert_live_order(&allocated_order, lower, higher);

    (allocated_order, fee_amount)
}

/// Close live indexed quantity and return redeem terms.
///
/// Returns `(resulting_order, redeem_amount, trading_fee)`.
/// `resulting_order` is the original order for a full close, or the replacement
/// order that remains after a partial close.
public(package) fun close_and_quote_live_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    close_quantity: u64,
    clock: &Clock,
): (Order, u64, u64) {
    let (lower, higher) = exposure.order_boundaries(order);
    let old_quantity = order.quantity();
    order::assert_valid_quantity(close_quantity);
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);
    let range_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    let fee_rate = pricing::fee_rate(
        config,
        market,
        exposure.expiry_fee_window_ms,
        exposure.expiry_fee_max_multiplier,
        range_probability,
        clock,
    );

    let (resulting_order, closed_floor_amount) = exposure.close_live_exposure(
        order,
        lower,
        higher,
        close_quantity,
        clock,
    );
    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let redeem_amount = gross_redeem_amount - gross_redeem_amount.min(closed_floor_amount);
    let fee_amount = math::mul(fee_rate, close_quantity).min(redeem_amount);
    (resulting_order, redeem_amount, fee_amount)
}

/// Clear one liquidated-order tombstone after its manager position is closed.
public(package) fun clear_liquidated_order(exposure: &mut StrikeExposure, order: &Order) {
    exposure.liquidation.clear_liquidated(order);
}

/// Run one bounded liquidation pass using exact per-candidate pricing.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
): u64 {
    let candidates = exposure.liquidation.select_liquidation_candidates(budget);
    if (candidates.is_empty()) return 0;

    let (forward, svi) = pricing::live_inputs(config, market, pyth, clock);
    exposure.liquidate_candidates(&svi, forward, candidates, clock)
}

/// Cache terminal settled payout liability.
///
/// Live indexes are kept until privileged compaction destroys them.
public(package) fun materialize_settled_liability(
    exposure: &mut StrikeExposure,
    settlement: u64,
): u64 {
    if (exposure.settled_liability_materialized) {
        return exposure.settled_payout_liability
    };

    let settled_liability = exposure.live.borrow().payout.settled_payout_liability(settlement);
    exposure.settled_payout_liability = settled_liability;
    exposure.settled_liability_materialized = true;
    settled_liability
}

/// Reduce cached settled liability after paying one settled order.
public(package) fun decrease_materialized_settled_liability(
    exposure: &mut StrikeExposure,
    amount: u64,
) {
    assert!(exposure.settled_liability_materialized, ESettledLiabilityNotMaterialized);
    let current_liability = exposure.settled_payout_liability;
    assert!(current_liability >= amount, ESettledLiabilityUnderflow);
    exposure.settled_payout_liability = current_liability - amount;
}

/// Destroy live indexes after terminal liability has been cached.
///
/// Callers must keep this behind privileged compaction because destruction
/// returns storage rebates.
public(package) fun destroy_live_indexes(exposure: &mut StrikeExposure) {
    assert!(exposure.settled_liability_materialized, ESettledLiabilityNotMaterialized);
    let live = exposure.live.extract();
    let LiveExposure {
        nav,
        payout,
        minted_min_strike: _,
        minted_max_strike: _,
    } = live;
    nav.destroy();
    payout.destroy();
}

fun liquidate_candidates(
    exposure: &mut StrikeExposure,
    svi: &SVIParams,
    forward: u64,
    candidates: vector<u256>,
    clock: &Clock,
): u64 {
    let mut liquidated_count = 0;
    let mut i = 0;
    while (i < candidates.length()) {
        let order = order::from_order_id(candidates[i]);
        let (lower, higher) = exposure.order_boundaries(&order);
        let range_probability = pricing::compute_range_price(
            svi,
            forward,
            lower,
            higher,
        );
        if (
            exposure.liquidate_candidate_if_under_floor(
                &order,
                lower,
                higher,
                range_probability,
                clock,
            )
        ) {
            liquidated_count = liquidated_count + 1;
        };
        i = i + 1;
    };
    liquidated_count
}

/// Return terminal payout for one order at settlement, including the contract floor.
fun settled_order_payout(exposure: &StrikeExposure, order: &Order, settlement: u64): u64 {
    let (lower, higher) = exposure.order_boundaries(order);
    if (settlement > lower && settlement <= higher) {
        let (_, terminal_payout, _) = exposure.order_index_update_terms(order);
        terminal_payout
    } else {
        0
    }
}

/// Return index update terms for this order.
///
/// `floor_shares` updates NAV; `terminal_payout` and `live_backing_payout`
/// update payout backing.
fun order_index_update_terms(exposure: &StrikeExposure, order: &Order): (u64, u64, u64) {
    let floor_shares = exposure.order_floor_shares(order);
    let quantity = order.quantity();
    let terminal_floor = exposure.floor_amount_at_ms(floor_shares, exposure.expiry_ms);
    let max_terminal_floor_before_liquidation = predict_math::mul_div_round_down(
        quantity,
        exposure.liquidation_ltv,
        constants::float_scaling!(),
    );
    assert!(
        terminal_floor < max_terminal_floor_before_liquidation,
        ETerminalFloorExceedsLiquidationLtv,
    );
    let floor_at_open = exposure.floor_amount_at_ms(
        floor_shares,
        order.opened_at_ms(),
    );
    (floor_shares, quantity - terminal_floor, quantity - floor_at_open)
}

/// Convert floor shares into a floor amount at one timestamp in this expiry.
fun floor_amount_at_ms(exposure: &StrikeExposure, floor_shares: u64, timestamp_ms: u64): u64 {
    let floor_index = exposure.floor_index_at_ms(timestamp_ms);
    predict_math::mul_div_round_up(floor_shares, floor_index, constants::float_scaling!())
}

/// Return floor-index-normalized shares for this order's floor seed.
fun order_floor_shares(exposure: &StrikeExposure, order: &Order): u64 {
    if (!order.is_leveraged()) return 0;

    let floor_seed_amount = order.floor_seed_amount();
    let open_index = exposure.floor_index_at_ms(order.opened_at_ms());
    predict_math::mul_div_round_up(
        floor_seed_amount,
        constants::float_scaling!(),
        open_index,
    )
}

/// Return the deterministic floor index at a timestamp for this expiry.
fun floor_index_at_ms(exposure: &StrikeExposure, timestamp_ms: u64): u64 {
    let window = constants::leverage_floor_window_ms!();
    let remaining = if (timestamp_ms >= exposure.expiry_ms) {
        0
    } else {
        exposure.expiry_ms - timestamp_ms
    };
    let elapsed = if (remaining >= window) {
        0
    } else {
        window - remaining
    };
    let phase = predict_math::mul_div_round_down(elapsed, constants::float_scaling!(), window);
    let phase_squared = predict_math::mul_div_round_down(
        phase,
        phase,
        constants::float_scaling!(),
    );

    constants::float_scaling!()
        + predict_math::mul_div_round_down(
            exposure.max_expiry_floor_premium,
            phase_squared,
            constants::float_scaling!(),
        )
}

/// Return `(min_strike, max_strike)` bounds used for pricing-curve construction.
fun minted_strike_range(live: &LiveExposure): (u64, u64) {
    if (live.minted_min_strike > live.minted_max_strike) (0, 0) else (
        live.minted_min_strike,
        live.minted_max_strike,
    )
}

/// Convert raw order boundaries into boundary indexes for this grid.
fun boundary_indices(exposure: &StrikeExposure, lower: u64, higher: u64): (u64, u64) {
    exposure.grid.assert_range_boundaries(lower, higher);
    (exposure.grid.boundary_index(lower), exposure.grid.boundary_index(higher))
}

/// Decode an order into `(lower, higher)` raw boundaries for this grid.
fun order_boundaries(exposure: &StrikeExposure, order: &Order): (u64, u64) {
    (
        exposure.grid.boundary_at_index(order.lower_boundary_index()),
        exposure.grid.boundary_at_index(order.higher_boundary_index()),
    )
}

/// Close live exposure and return `(resulting_order, closed_floor_amount)`.
///
/// `closed_floor_amount` is the current floor amount deducted from the closed
/// quantity's gross redeem value.
fun close_live_exposure(
    exposure: &mut StrikeExposure,
    order: &Order,
    lower: u64,
    higher: u64,
    close_quantity: u64,
    clock: &Clock,
): (Order, u64) {
    let resulting_order = exposure.resulting_order_after_close(order, close_quantity);
    let closed_floor_amount = exposure.remove_closed_live_order(
        order,
        &resulting_order,
        lower,
        higher,
        close_quantity,
        clock,
    );
    exposure.liquidation.remove_order(order);
    if (resulting_order.id() != order.id()) {
        exposure.liquidation.insert_order(&resulting_order);
    };
    (resulting_order, closed_floor_amount)
}

fun resulting_order_after_close(
    exposure: &mut StrikeExposure,
    order: &Order,
    close_quantity: u64,
): Order {
    let replacement_quantity = order.quantity() - close_quantity;
    if (replacement_quantity == 0) return *order;

    let sequence = exposure.next_order_sequence;
    let replacement_order = order::replacement(order, replacement_quantity, sequence);
    exposure.next_order_sequence = sequence + 1;
    replacement_order
}

fun remove_closed_live_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    resulting_order: &Order,
    lower: u64,
    higher: u64,
    close_quantity: u64,
    clock: &Clock,
): u64 {
    let (
        old_floor_shares,
        old_terminal_payout,
        old_live_backing_payout,
    ) = exposure.order_index_update_terms(order);
    let (remaining_floor_shares, remaining_terminal_payout, remaining_live_backing_payout) = if (
        resulting_order.id() == order.id()
    ) {
        (0, 0, 0)
    } else {
        exposure.order_index_update_terms(resulting_order)
    };
    let closed_floor_shares = old_floor_shares - remaining_floor_shares;
    let closed_terminal_payout = old_terminal_payout - remaining_terminal_payout;
    let closed_live_backing_payout = old_live_backing_payout - remaining_live_backing_payout;
    let closed_floor_amount = exposure.floor_amount_at_ms(
        closed_floor_shares,
        clock.timestamp_ms(),
    );

    let grid = exposure.grid;
    let live = exposure.live.borrow_mut();
    live
        .payout
        .remove_range(
            &grid,
            lower,
            higher,
            closed_terminal_payout,
            closed_live_backing_payout,
        );
    live.nav.remove_range(&grid, lower, higher, close_quantity, closed_floor_shares);
    closed_floor_amount
}

fun liquidate_candidate_if_under_floor(
    exposure: &mut StrikeExposure,
    order: &Order,
    lower: u64,
    higher: u64,
    range_probability: u64,
    clock: &Clock,
): bool {
    let gross_value = math::mul(range_probability, order.quantity());
    let floor_amount = exposure.floor_amount_at_ms(
        exposure.order_floor_shares(order),
        clock.timestamp_ms(),
    );
    let liquidation_threshold_value = predict_math::mul_div_round_up(
        floor_amount,
        constants::float_scaling!(),
        exposure.liquidation_ltv,
    );
    if (gross_value > liquidation_threshold_value) return false;

    let quantity = order.quantity();
    let (floor_shares, terminal_payout, live_backing_payout) = exposure.order_index_update_terms(
        order,
    );
    let grid = exposure.grid;
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(&grid, lower, higher, terminal_payout, live_backing_payout);
    live.nav.remove_range(&grid, lower, higher, quantity, floor_shares);
    exposure.liquidation.mark_liquidated(order);
    order_events::emit_order_liquidated(
        exposure.expiry_market_id,
        order,
        gross_value,
        floor_amount,
        exposure.liquidation_ltv,
    );
    true
}

fun assert_mint_above_liquidation_threshold(
    exposure: &StrikeExposure,
    order: &Order,
    floor_shares: u64,
) {
    if (!order.is_leveraged()) return;

    let floor_amount = exposure.floor_amount_at_ms(floor_shares, order.opened_at_ms());
    let threshold = predict_math::mul_div_round_up(
        floor_amount,
        constants::float_scaling!(),
        exposure.liquidation_ltv,
    );
    let gross_value = math::mul(order.entry_probability(), order.quantity());
    assert!(gross_value > threshold, EOrderBelowLiquidationThreshold);
}

/// Insert one active order into both live indexes.
fun insert_live_order(exposure: &mut StrikeExposure, order: &Order, lower: u64, higher: u64) {
    let quantity = order.quantity();
    let (floor_shares, terminal_payout, live_backing_payout) = exposure.order_index_update_terms(
        order,
    );
    exposure.assert_mint_above_liquidation_threshold(order, floor_shares);
    let grid = exposure.grid;
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(&grid, lower, higher, terminal_payout, live_backing_payout);
    live.nav.insert_range(&grid, lower, higher, quantity, floor_shares);
    live.track_minted_boundaries(lower, higher);
    exposure.liquidation.insert_order(order);
}

/// Expand the valuation curve cache to cover newly touched finite strikes.
fun track_minted_boundaries(live: &mut LiveExposure, lower: u64, higher: u64) {
    if (lower != constants::neg_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(lower);
        live.minted_max_strike = live.minted_max_strike.max(lower);
    };

    if (higher != constants::pos_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(higher);
        live.minted_max_strike = live.minted_max_strike.max(higher);
    };
}
