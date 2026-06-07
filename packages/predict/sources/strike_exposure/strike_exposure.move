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
    market_oracle::MarketOracle,
    order::{Self, Order},
    order_events,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_exposure_config::StrikeExposureConfig,
    strike_grid::StrikeGrid,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const ESettledLiabilityNotMaterialized: u64 = 0;
const EInvalidCloseQuantity: u64 = 2;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    /// Expiry market that owns this exposure book.
    expiry_market_id: ID,
    /// Terminal timestamp used by floor-index and order floor math.
    expiry_ms: u64,
    grid: StrikeGrid,
    /// Snapshotted exposure and fee policy for this expiry.
    config: StrikeExposureConfig,
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

/// Return the terminal floor index snapshotted for this exposure book.
public(package) fun terminal_floor_index(exposure: &StrikeExposure): u64 {
    exposure.config.terminal_floor_index()
}

/// Return the liquidation LTV snapshotted for this exposure book.
public(package) fun liquidation_ltv(exposure: &StrikeExposure): u64 {
    exposure.config.liquidation_ltv()
}

public(package) fun expiry_fee_window_ms(exposure: &StrikeExposure): u64 {
    exposure.config.expiry_fee_window_ms()
}

public(package) fun expiry_fee_max_multiplier(exposure: &StrikeExposure): u64 {
    exposure.config.expiry_fee_max_multiplier()
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
            exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms()),
        )
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

/// Create a strike exposure book for the oracle grid.
public(package) fun new(
    expiry_market_id: ID,
    expiry_ms: u64,
    grid: StrikeGrid,
    preallocated_ticks: u64,
    config: StrikeExposureConfig,
    ctx: &mut TxContext,
): StrikeExposure {
    StrikeExposure {
        expiry_market_id,
        expiry_ms,
        grid,
        config,
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
    let (lower, higher) = exposure.order_boundaries(order);
    exposure.liquidation.remove_order(order);
    if (settlement <= lower || settlement > higher) {
        return 0
    };
    let quantity = order.quantity();
    let index_at_settlement = exposure.config.terminal_floor_index();
    let terminal_floor = math::mul(order.floor_shares(), index_at_settlement);
    let payout = quantity - terminal_floor;
    exposure.settled_payout_liability = exposure.settled_payout_liability - payout;

    payout
}

/// Quote and allocate a live mint order over this exposure book's strike grid.
///
/// Returns `(allocated_order, entry_probability, user_contribution)`.
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
): (Order, u64, u64) {
    let entry_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    let opened_at_ms = clock.timestamp_ms();
    let (user_contribution, floor_seed_amount) = exposure
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
            floor_seed_amount,
            quantity,
        );

    let (lower_boundary_index, higher_boundary_index) = exposure.boundary_indices(lower, higher);
    let sequence = exposure.next_order_sequence;

    let allocated_order = order::new_from_boundary_indices(
        opened_at_ms,
        lower_boundary_index,
        higher_boundary_index,
        floor_shares,
        quantity,
        sequence,
    );
    exposure.next_order_sequence = sequence + 1;

    exposure.liquidation.insert_order(&allocated_order);
    exposure.insert_live_index_quantity(
        lower,
        higher,
        quantity,
        floor_shares,
        terminal_payout,
        live_backing_payout,
    );

    (allocated_order, entry_probability, user_contribution)
}

/// Close live indexed quantity and return redeem terms.
///
/// Returns `(resulting_order, redeem_amount, range_probability)`.
/// The trade fee is recovered via `trading_fee` from the returned price.
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
    order::assert_valid_quantity(close_quantity);
    let old_quantity = order.quantity();
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);

    let (lower, higher) = exposure.order_boundaries(order);

    let old_floor_shares = order.floor_shares();
    let close_fraction = math::div(close_quantity, old_quantity);
    let remove_floor_shares = math::mul(old_floor_shares, close_fraction);

    exposure.remove_live_index_quantity(order, lower, higher, close_quantity, remove_floor_shares);
    exposure.liquidation.remove_order(order);

    // calculate payout
    let range_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    let removed_floor_amount = math::mul(remove_floor_shares, index_now);
    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let redeem_amount = gross_redeem_amount - gross_redeem_amount.min(removed_floor_amount);

    let remaining_quantity = old_quantity - close_quantity;
    if (remaining_quantity == 0) {
        return (*order, redeem_amount, range_probability)
    };

    let remaining_floor_shares = old_floor_shares - remove_floor_shares;
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
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    clock: &Clock,
): bool {
    if (!exposure.liquidation.contains_active_order(order)) return false;

    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    let liquidation_ltv = exposure.config.liquidation_ltv();
    exposure.liquidate_order_if_under_floor(
        config,
        market,
        pyth,
        order,
        index_now,
        liquidation_ltv,
        clock,
    )
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
    let index_now = exposure.config.floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());
    let liquidation_ltv = exposure.config.liquidation_ltv();

    let mut liquidated_count = 0;
    let mut i = 0;
    while (i < candidates.length()) {
        let order = order::from_order_id(candidates[i]);
        if (
            exposure.liquidate_order_if_under_floor(
                config,
                market,
                pyth,
                &order,
                index_now,
                liquidation_ltv,
                clock,
            )
        ) {
            liquidated_count = liquidated_count + 1;
        };

        i = i + 1;
    };

    liquidated_count
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

fun insert_live_index_quantity(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    quantity: u64,
    floor_shares: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    let grid = exposure.grid;
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(&grid, lower, higher, terminal_payout, live_backing_payout);
    live.nav.insert_range(&grid, lower, higher, quantity, floor_shares);
    live.track_minted_boundaries(lower, higher);
}

fun liquidate_order_if_under_floor(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    index_now: u64,
    liquidation_ltv: u64,
    clock: &Clock,
): bool {
    let quantity = order.quantity();
    let (lower, higher) = exposure.order_boundaries(order);
    let range_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    let floor_shares = order.floor_shares();
    let current_floor_amount = math::mul(floor_shares, index_now);
    let gross_value = math::mul(range_probability, quantity);
    let liquidation_threshold = math::div(current_floor_amount, liquidation_ltv);
    let can_liquidate = gross_value <= liquidation_threshold;
    if (!can_liquidate) return false;

    exposure.liquidation.mark_liquidated(order);
    exposure.remove_live_index_quantity(order, lower, higher, quantity, floor_shares);

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
    lower: u64,
    higher: u64,
    quantity: u64,
    floor_shares: u64,
) {
    let terminal_floor = math::mul(floor_shares, exposure.config.terminal_floor_index());
    let terminal_payout = quantity - terminal_floor;
    let index_at_open = exposure
        .config
        .floor_index_at_ms(
            exposure.expiry_ms,
            order.opened_at_ms(),
        );
    let floor_amount_at_open = math::mul(floor_shares, index_at_open);
    let live_backing_payout = quantity - floor_amount_at_open;

    let grid = exposure.grid;
    {
        let live = exposure.live.borrow_mut();
        live.nav.remove_range(&grid, lower, higher, quantity, floor_shares);
        live.payout.remove_range(&grid, lower, higher, terminal_payout, live_backing_payout);
    };
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
