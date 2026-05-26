// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Expiry-local exposure book for one oracle grid.
///
/// This module interprets `Order` terms against the expiry's strike grid and
/// floor-index schedule. It owns two derived views of the same active contracts:
/// payout liability for cash backing, and live position liability for LP
/// valuation. Expiry-market cash backing, fee custody, manager positions, and
/// payout movement stay outside this module.
module deepbook_predict::strike_exposure;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    math as predict_math,
    order::{Self, Order},
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const EInvalidTickSize: u64 = 2;
const EInvalidStrikeGrid: u64 = 3;
const EInvalidStrikeIndex: u64 = 4;
const ESettledLiabilityNotMaterialized: u64 = 5;
const ESettledLiabilityUnderflow: u64 = 6;
const EInvalidCloseQuantity: u64 = 7;
const EFloorExceedsMaxPayout: u64 = 8;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    /// Terminal timestamp used by floor-index and order floor math.
    expiry_ms: u64,
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    /// Max increase of the floor index over this expiry's floor window.
    /// `200_000_000` means the index rises from 1.0 to 1.2 by expiry.
    max_expiry_floor_premium: u64,
    next_order_sequence: u64,
    /// Remaining settled liability after settlement has been materialized.
    settled_payout_liability: u64,
    /// True once `settled_payout_liability` has been materialized.
    settled_liability_materialized: bool,
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

/// Return live worst-case payout, or remaining settled payout liability once materialized.
public(package) fun payout_liability(exposure: &StrikeExposure, clock: &Clock): u64 {
    if (exposure.settled_liability_materialized) {
        exposure.settled_payout_liability
    } else {
        let floor_index = exposure.floor_index_at_ms(clock.timestamp_ms());
        exposure.live.borrow().payout.max_live_payout(floor_index)
    }
}

/// Return the terminal floor-index premium snapshotted for this exposure book.
public(package) fun max_expiry_floor_premium(exposure: &StrikeExposure): u64 {
    exposure.max_expiry_floor_premium
}

/// Evaluate live user-position liability for LP valuation.
///
/// This aggregate path assumes every active floor-bearing order is above its
/// current floor. Liquidation must enforce that invariant before valuation.
public(package) fun live_position_liability(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    let live = exposure.live.borrow();
    let (minted_min_strike, minted_max_strike) = live.minted_strike_range();
    if (minted_min_strike == 0 && minted_max_strike == 0) {
        0
    } else {
        let curve = pricing::build_live_curve(
            config,
            market,
            pyth,
            clock,
            exposure.grid_min,
            exposure.grid_tick,
            exposure.grid_max,
            minted_min_strike,
            minted_max_strike,
        );
        live
            .nav
            .live_value(
                &curve,
                minted_min_strike,
                minted_max_strike,
                exposure.floor_index_at_ms(clock.timestamp_ms()),
            )
    }
}

/// Create a strike exposure book for the oracle grid.
public(package) fun new(
    expiry_ms: u64,
    min_strike: u64,
    tick_size: u64,
    max_expiry_floor_premium: u64,
    ctx: &mut TxContext,
): StrikeExposure {
    let max_strike = validated_max_strike(min_strike, tick_size);
    StrikeExposure {
        expiry_ms,
        grid_min: min_strike,
        grid_tick: tick_size,
        grid_max: max_strike,
        max_expiry_floor_premium,
        next_order_sequence: 0,
        settled_payout_liability: 0,
        settled_liability_materialized: false,
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(tick_size, min_strike, max_strike, ctx),
            payout: strike_payout_tree::new(tick_size, min_strike, max_strike, ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
    }
}

/// Close one settled order and return the payout after the contract floor.
public(package) fun close_settled_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    let user_payout = exposure.settled_order_payout(order, settlement);
    exposure.decrease_materialized_settled_liability(user_payout);
    user_payout
}

/// Quote and allocate a live mint order over this exposure book's strike grid.
///
/// Returns `(order, fee_amount, payout_liability)`, where `payout_liability`
/// is the post-mint live backing requirement.
public(package) fun allocate_mint_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
): (Order, u64, u64) {
    let (min_strike_index, max_strike_index) = exposure.strike_indices(lower, higher);
    let entry_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        clock,
        lower,
        higher,
    );
    let fee_rate = pricing::assert_mint_fee_rate(config, entry_probability);
    let fee_amount = math::mul(fee_rate, quantity);

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::new_from_strike_indices(
        clock.timestamp_ms(),
        min_strike_index,
        max_strike_index,
        leverage,
        entry_probability,
        quantity,
        sequence,
    );
    let floor_shares = exposure.assert_terminal_floor_covered(&allocated_order);
    exposure.next_order_sequence = sequence + 1;

    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, quantity, floor_shares);
    live.nav.insert_range(lower, higher, quantity, floor_shares);
    live.track_minted_boundaries(lower, higher);

    let payout_liability = exposure.payout_liability(clock);
    (allocated_order, fee_amount, payout_liability)
}

/// Close live indexed quantity and return redeem terms plus post-close backing liability.
///
/// Returns `(resulting_order, net_redeem_amount, fee_amount, payout_liability)`.
/// `resulting_order` is the original order for a full close, or the replacement
/// order that remains after a partial close. `payout_liability` is the
/// post-close live backing requirement.
public(package) fun close_and_quote_live_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    order: &Order,
    close_quantity: u64,
): (Order, u64, u64, u64) {
    let (lower, higher, old_quantity) = exposure.order_range_terms(order);
    order::assert_valid_quantity(close_quantity);
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);
    let range_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        clock,
        lower,
        higher,
    );
    let fee_rate = pricing::fee_rate(config, range_probability);

    let (resulting_order, closed_floor) = exposure.close_live_exposure(
        lower,
        higher,
        close_quantity,
        old_quantity,
        order,
        clock,
    );
    let payout_liability = exposure.payout_liability(clock);
    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let net_redeem_amount = gross_redeem_amount - gross_redeem_amount.min(closed_floor);
    let fee_amount = math::mul(fee_rate, close_quantity).min(net_redeem_amount);
    (resulting_order, net_redeem_amount, fee_amount, payout_liability)
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

    let floor_index = exposure.floor_index_at_ms(exposure.expiry_ms);
    let settled_liability = exposure.live.borrow().payout.settled_value(settlement, floor_index);
    exposure.settled_payout_liability = settled_liability;
    exposure.settled_liability_materialized = true;
    settled_liability
}

/// Reduce cached settled liability after paying one settled order.
///
/// Aggregate floor-share liability may leave rounding dust after all individual
/// settled payouts are redeemed. That dust intentionally stays reserved for now.
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

/// Return terminal payout for one order at settlement, including the contract floor.
fun settled_order_payout(exposure: &StrikeExposure, order: &Order, settlement: u64): u64 {
    let (lower, higher, quantity) = exposure.order_range_terms(order);
    if (settlement > lower && settlement <= higher) {
        let terminal_floor = exposure.floor_amount_at_ms(
            exposure.order_floor_shares(order),
            exposure.expiry_ms,
        );
        quantity - terminal_floor
    } else {
        0
    }
}

/// Enforce that a winning order can still pay at least zero at expiry and return its floor shares.
fun assert_terminal_floor_covered(exposure: &StrikeExposure, order: &Order): u64 {
    let floor_shares = exposure.order_floor_shares(order);
    exposure.assert_terminal_floor_shares_covered(floor_shares, order.quantity());
    floor_shares
}

fun assert_terminal_floor_shares_covered(
    exposure: &StrikeExposure,
    floor_shares: u64,
    quantity: u64,
) {
    if (floor_shares == 0) return;

    let terminal_floor = exposure.floor_amount_at_ms(floor_shares, exposure.expiry_ms);
    assert!(terminal_floor <= quantity, EFloorExceedsMaxPayout);
}

/// Convert floor shares into a floor amount at one timestamp in this expiry.
fun floor_amount_at_ms(exposure: &StrikeExposure, floor_shares: u64, timestamp_ms: u64): u64 {
    let floor_index = exposure.floor_index_at_ms(timestamp_ms);
    // Individual floors round up while aggregate liability rounds down by convention.
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

/// Validate the creation grid and return its finite max strike.
fun validated_max_strike(min_strike: u64, tick_size: u64): u64 {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    let ticks = constants::oracle_strike_grid_ticks!();
    assert!(ticks > 0, EInvalidStrikeGrid);
    min_strike + tick_size * ticks
}

/// Convert raw order strikes into `(min_strike_index, max_strike_index)` for this grid.
fun strike_indices(exposure: &StrikeExposure, lower: u64, higher: u64): (u64, u64) {
    assert!(lower < higher, EInvalidStrikeGrid);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeGrid,
    );
    let open_index = order::open_strike_index();
    let min_strike_index = if (lower == constants::neg_inf!()) {
        open_index
    } else {
        exposure.checked_finite_strike_index(lower)
    };
    let max_strike_index = if (higher == constants::pos_inf!()) {
        open_index
    } else {
        exposure.checked_finite_strike_index(higher)
    };

    (min_strike_index, max_strike_index)
}

/// Validate one finite strike and return its grid index.
fun checked_finite_strike_index(exposure: &StrikeExposure, strike: u64): u64 {
    assert!(strike >= exposure.grid_min && strike <= exposure.grid_max, EInvalidStrikeGrid);
    assert!((strike - exposure.grid_min) % exposure.grid_tick == 0, EInvalidStrikeGrid);
    (strike - exposure.grid_min) / exposure.grid_tick
}

/// Decode an order into `(lower, higher, quantity)` for this grid.
fun order_range_terms(exposure: &StrikeExposure, order: &Order): (u64, u64, u64) {
    let open_index = order::open_strike_index();
    let min_strike_index = order.min_strike_index();
    let max_strike_index = order.max_strike_index();

    let lower = if (min_strike_index == open_index) {
        constants::neg_inf!()
    } else {
        let strike = exposure.grid_min + min_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    let higher = if (max_strike_index == open_index) {
        constants::pos_inf!()
    } else {
        let strike = exposure.grid_min + max_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    (lower, higher, order.quantity())
}

/// Close live exposure and return `(resulting_order, closed_floor)`.
fun close_live_exposure(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    close_quantity: u64,
    old_quantity: u64,
    order: &Order,
    clock: &Clock,
): (Order, u64) {
    let old_floor_shares = exposure.order_floor_shares(order);
    let replacement_quantity = old_quantity - close_quantity;
    let (resulting_order, remaining_floor_shares) = if (replacement_quantity == 0) {
        (*order, 0)
    } else {
        let sequence = exposure.next_order_sequence;
        let replacement_order = order::replacement(order, replacement_quantity, sequence);
        let remaining_floor_shares = exposure.assert_terminal_floor_covered(&replacement_order);
        exposure.next_order_sequence = sequence + 1;
        (replacement_order, remaining_floor_shares)
    };
    let closed_floor_shares = old_floor_shares - remaining_floor_shares;
    let closed_floor = exposure.floor_amount_at_ms(closed_floor_shares, clock.timestamp_ms());

    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, close_quantity, closed_floor_shares);
    live.nav.remove_range(lower, higher, close_quantity, closed_floor_shares);
    (resulting_order, closed_floor)
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
