// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Scratch expiry-local exposure book shape for enumerating floor accounting.
module deepbook_predict::strike_exposure_rewrite;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    liquidation_book::{Self, LiquidationBook},
    market_oracle::MarketOracle,
    math as predict_math,
    order::{Self, Order},
    order_events,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_exposure_cofig_rewrite::StrikeExposureConfig,
    strike_grid::StrikeGrid,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const ETerminalFloorExceedsLiquidationLtv: u64 = 0;
const EOrderBelowLiquidationThreshold: u64 = 1;
const EInvalidCloseQuantity: u64 = 2;
const EOrderPrincipalBelowMinimum: u64 = 5;
const EInvalidLeverageTier: u64 = 6;
const EInvalidLeverage: u64 = 7;
// Settled-liability codes 0/1 are inlined from `strike_exposure` and intentionally
// share values with the config-derived codes above (Move permits duplicate constant
// values). In the original these lived in two separate modules; the merge preserves
// each abort's source code rather than renumbering. See ledger.
const ESettledLiabilityNotMaterialized: u64 = 0;
const ESettledLiabilityUnderflow: u64 = 1;

const LEVERAGE_ONE_X: u64 = 1_000_000_000;
const LEVERAGE_ONE_AND_HALF_X: u64 = 1_500_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const LEVERAGE_TWO_AND_HALF_X: u64 = 2_500_000_000;
const LEVERAGE_THREE_X: u64 = 3_000_000_000;

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

/// Return the terminal floor-index premium snapshotted for this exposure book.
public(package) fun max_expiry_floor_premium(exposure: &StrikeExposure): u64 {
    exposure.config.max_expiry_floor_premium()
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

/// Mark-to-market live liability with the full valuation flow inlined.
///
/// Returns the live NAV value of all minted strikes, or 0 for an empty book.
public(package) fun valuation_liability(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    let live = exposure.live.borrow();
    // Empty-book early return. A fresh book carries the sentinel
    // minted_min_strike = max_u64 > minted_max_strike = 0; every finite minted strike is
    // >= grid.min_strike, which strike_grid::new_centered asserts > 0, and mint records each
    // finite boundary into both min and max, so a non-empty book always has
    // minted_min_strike <= minted_max_strike. Thus min > max is the empty sentinel alone
    // (collapses the D2 `is_empty_book`/(0,0)/`==0 && ==0` triple; see ledger).
    if (live.minted_min_strike > live.minted_max_strike) {
        return 0
    };
    let minted_min_strike = live.minted_min_strike;
    let minted_max_strike = live.minted_max_strike;

    // Live price and SVI. live_inputs validates live-market preconditions (oracle
    // freshness, market active) and can abort; it must run before the curve build,
    // matching the reference ordering. This is a read-only valuation, so there is no
    // mutation to sequence around.
    let (forward, svi) = pricing::live_inputs(config, market, pyth, clock);
    let curve = pricing::build_curve(
        &svi,
        forward,
        exposure.grid.tick_size(),
        minted_min_strike,
        minted_max_strike,
    );

    let current_floor_index = exposure
        .config
        .floor_index_at_ms(exposure.expiry_ms, clock.timestamp_ms());

    live
        .nav
        .live_value(
            &exposure.grid,
            &curve,
            minted_min_strike,
            minted_max_strike,
            current_floor_index,
        )
}

/// Return the raw per-trade fee for a live price and quantity.
///
/// Mint computes its raw fee inside allocation so the all-in ask-price gate and
/// fee amount share one fee sample. Redeem uses this uncapped raw fee and applies
/// the `.min(redeem_amount)` cap at the caller.
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

/// Pay out one settled order with the full settled-close flow inlined.
///
/// Returns the user payout (terminal payout for an in-range settlement, else 0).
public(package) fun close_settled_order(
    exposure: &mut StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    assert!(exposure.settled_liability_materialized, ESettledLiabilityNotMaterialized);

    // In-range settlement determination, then the in-range terminal payout. An
    // out-of-range settlement pays 0 and needs no floor math. The boundary reads
    // release their grid borrow before the &mut exposure mutations below, so no grid
    // copy is needed here (unlike the flows that pass &grid into live-index removals).
    let lower = exposure.grid.boundary_at_index(order.lower_boundary_index());
    let higher = exposure.grid.boundary_at_index(order.higher_boundary_index());
    if (settlement <= lower || settlement > higher) {
        exposure.liquidation.remove_order(order);
        return 0
    };

    // Terminal floor at settlement, collapsed to a single round-up from the seed
    // (CC2; ledger §1). No terminal-floor LTV re-assert: provably dead on an
    // already-admitted order (v3 S1). seed is 0 for a 1x order, so terminal_floor is 0.
    let open_floor_index = exposure
        .config
        .floor_index_at_ms(exposure.expiry_ms, order.opened_at_ms());
    let terminal_floor = predict_math::mul_div_round_up(
        order.floor_seed_amount(),
        constants::float_scaling!() + exposure.config.max_expiry_floor_premium(),
        open_floor_index,
    );
    let user_payout = order.quantity() - terminal_floor;

    // Reduce cached settled liability after paying one settled order.
    let current_liability = exposure.settled_payout_liability;
    assert!(current_liability >= user_payout, ESettledLiabilityUnderflow);
    exposure.settled_payout_liability = current_liability - user_payout;

    exposure.liquidation.remove_order(order);
    user_payout
}

/// Quote and allocate a live mint order with the full mint flow inlined.
///
/// Returns `(allocated_order, entry_probability, user_contribution, raw_fee_amount)`.
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
): (Order, u64, u64, u64) {
    // Grid boundary validation, before pricing: a grid-invalid range is rejected
    // before the oracle is consulted (matches strike_exposure ordering).
    exposure.grid.assert_range_boundaries(lower, higher);

    // Live price, leverage tier, and all-in fee gate. All three validate mint
    // preconditions before any index mutation.
    let entry_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );
    assert_mint_leverage_tier(entry_probability, leverage);
    let raw_fee_amount = exposure
        .config
        .mint_trading_fee(
            exposure.expiry_ms,
            entry_probability,
            quantity,
            clock.timestamp_ms(),
        );
    let exposure_value = math::mul(entry_probability, quantity);
    let user_contribution = predict_math::mul_div_round_up(
        exposure_value,
        constants::float_scaling!(),
        leverage,
    );
    let floor_seed_amount = exposure_value - user_contribution;
    assert!(user_contribution >= constants::min_order_principal!(), EOrderPrincipalBelowMinimum);

    // Immutable contract terms.
    let opened_at_ms = clock.timestamp_ms();
    let lower_boundary_index = exposure.grid.boundary_index(lower);
    let higher_boundary_index = exposure.grid.boundary_index(higher);
    let allocated_order = order::new_from_boundary_indices(
        opened_at_ms,
        lower_boundary_index,
        higher_boundary_index,
        floor_seed_amount,
        quantity,
        exposure.next_order_sequence,
    );

    // Floor economics: the open-timestamp floor index, then the order's collapsed floor
    // amounts. floor_seed_amount is 0 for a 1x order, so every floor term is 0 with no
    // leverage guard.
    let open_floor_index = exposure.config.floor_index_at_ms(exposure.expiry_ms, opened_at_ms);
    // Terminal floor, collapsed to one round-up from the seed (CC2; ledger §1):
    // ceil(seed * (FS + max_premium) / open_index). The faithful floor-at-open round-trip
    // collapses to the seed itself (CC1; ledger §1), so it is not materialized — the live
    // backing payout and the at-open liquidation threshold below read floor_seed_amount
    // directly. floor_shares (the NAV share count) is the only term that survives the
    // collapse, and it is computed at its single sink (nav.insert_range) below.
    let terminal_floor = predict_math::mul_div_round_up(
        floor_seed_amount,
        constants::float_scaling!() + exposure.config.max_expiry_floor_premium(),
        open_floor_index,
    );

    // Mint admission policy.
    // Terminal-floor LTV cap binds for every order (terminal_floor is 0 for 1x).
    let liquidation_ltv = exposure.config.liquidation_ltv();
    let max_terminal_floor = predict_math::mul_div_round_down(
        quantity,
        liquidation_ltv,
        constants::float_scaling!(),
    );
    assert!(terminal_floor < max_terminal_floor, ETerminalFloorExceedsLiquidationLtv);
    // Open liquidation-threshold check is floor-only; for a 1x order the seed is 0, so
    // the disjunct skips the bound. With floor-at-open collapsed to the seed (CC1), the
    // threshold is ceil(seed * FS / ltv).
    let liquidation_threshold_at_open = predict_math::mul_div_round_up(
        floor_seed_amount,
        constants::float_scaling!(),
        liquidation_ltv,
    );
    let gross_value = math::mul(entry_probability, quantity);
    assert!(
        floor_seed_amount == 0 || gross_value > liquidation_threshold_at_open,
        EOrderBelowLiquidationThreshold,
    );

    // Live exposure indexes and liquidation tracking. grid is copied (StrikeGrid has copy)
    // so &grid can be passed into the inserts while exposure.live is borrowed mutably.
    // Gather each index's terms, then borrow live once for both inserts and the
    // minted-strike cache.
    let grid = exposure.grid;
    let terminal_payout = quantity - terminal_floor;
    let live_backing_payout = quantity - floor_seed_amount;
    let floor_shares = predict_math::mul_div_round_up(
        floor_seed_amount,
        constants::float_scaling!(),
        open_floor_index,
    );
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(&grid, lower, higher, terminal_payout, live_backing_payout);
    live.nav.insert_range(&grid, lower, higher, quantity, floor_shares);
    if (lower != constants::neg_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(lower);
        live.minted_max_strike = live.minted_max_strike.max(lower);
    };
    if (higher != constants::pos_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(higher);
        live.minted_max_strike = live.minted_max_strike.max(higher);
    };
    exposure.liquidation.insert_order(&allocated_order);
    exposure.next_order_sequence = exposure.next_order_sequence + 1;

    (allocated_order, entry_probability, user_contribution, raw_fee_amount)
}

/// Close live indexed quantity with the full live-close flow inlined.
///
/// Returns `(resulting_order, redeem_amount, range_probability)`. The trade fee is
/// recovered via `trading_fee` from the returned `range_probability`.
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
    // Close quantity validation.
    order::assert_valid_quantity(close_quantity);
    let old_quantity = order.quantity();
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);

    // Order range boundaries, shared by pricing and index removal.
    let grid = exposure.grid;
    let lower = grid.boundary_at_index(order.lower_boundary_index());
    let higher = grid.boundary_at_index(order.higher_boundary_index());

    // Live price. Validates live-market preconditions (oracle freshness, market
    // active, now < expiry) and so must run before any index mutation; its value is
    // not consumed until the redeem math below.
    let range_probability = pricing::live_range_probability(
        config,
        market,
        pyth,
        lower,
        higher,
        clock,
    );

    // Floor economics -> index-removal deltas. Terminal floor is collapsed to one round-up
    // from the seed (CC2; ledger §1); floor-at-open collapses to the seed (CC1; ledger §1),
    // so live backing reads the seed directly. Only the NAV share count (floor_shares) — the
    // value actually removed from the matrix — survives the collapse. floor_seed_amount is 0
    // for a 1x order, so every floor term below is 0 with no leverage guard.
    // Open timestamp -> floor index. (Replicates floor_index_at_ms; see ledger.)
    let opened_at_ms = order.opened_at_ms();
    let remaining_ms_at_open = if (opened_at_ms >= exposure.expiry_ms) {
        0
    } else {
        exposure.expiry_ms - opened_at_ms
    };
    let elapsed_ms_at_open = if (remaining_ms_at_open >= constants::leverage_floor_window_ms!()) {
        0
    } else {
        constants::leverage_floor_window_ms!() - remaining_ms_at_open
    };
    let open_floor_phase = predict_math::mul_div_round_down(
        elapsed_ms_at_open,
        constants::float_scaling!(),
        constants::leverage_floor_window_ms!(),
    );
    let open_floor_phase_squared = predict_math::mul_div_round_down(
        open_floor_phase,
        open_floor_phase,
        constants::float_scaling!(),
    );
    let open_floor_premium = predict_math::mul_div_round_down(
        exposure.config.max_expiry_floor_premium(),
        open_floor_phase_squared,
        constants::float_scaling!(),
    );
    let open_floor_index = constants::float_scaling!() + open_floor_premium;
    // floor_index_at_ms(expiry, expiry) collapses to FS + max_premium; used by both orders'
    // terminal floor.
    let terminal_floor_index =
        constants::float_scaling!() + exposure.config.max_expiry_floor_premium();

    // Old order terms: NAV share count (the removal delta), collapsed terminal floor (CC2),
    // and live backing read straight from the seed (CC1). No terminal-floor LTV re-assert: the
    // old order already passed it at creation under the same snapshotted config and unchanged
    // stored fields, so on the old order the assert is provably dead (see ledger S1).
    let old_floor_seed_amount = order.floor_seed_amount();
    let old_floor_shares = predict_math::mul_div_round_up(
        old_floor_seed_amount,
        constants::float_scaling!(),
        open_floor_index,
    );
    let old_terminal_floor = predict_math::mul_div_round_up(
        old_floor_seed_amount,
        terminal_floor_index,
        open_floor_index,
    );
    let old_terminal_payout = old_quantity - old_terminal_floor;
    let old_live_backing_payout = old_quantity - old_floor_seed_amount;

    // Replacement order: identity, then floor terms. seed is 0 for a full close, so its floor
    // terms are 0. The terminal-floor LTV cap IS re-checked here: the replacement is created in
    // this close and has not been admitted before (guarded so a full close does not abort on
    // 0 < 0). The identity is computed here, directly above its first use, since nothing
    // between close-validation and this point needs it.
    let replacement_quantity = old_quantity - close_quantity;
    let has_replacement = replacement_quantity > 0;
    let resulting_order = if (has_replacement) {
        let replacement_floor_seed_amount = predict_math::mul_div_round_down(
            old_floor_seed_amount,
            replacement_quantity,
            old_quantity,
        );
        order::replacement(
            order,
            replacement_quantity,
            replacement_floor_seed_amount,
            exposure.next_order_sequence,
        )
    } else {
        *order
    };
    let remaining_floor_seed_amount = if (has_replacement) {
        resulting_order.floor_seed_amount()
    } else {
        0
    };
    let remaining_floor_shares = predict_math::mul_div_round_up(
        remaining_floor_seed_amount,
        constants::float_scaling!(),
        open_floor_index,
    );
    let remaining_terminal_floor = predict_math::mul_div_round_up(
        remaining_floor_seed_amount,
        terminal_floor_index,
        open_floor_index,
    );
    let liquidation_ltv = exposure.config.liquidation_ltv();
    let remaining_max_terminal_floor = predict_math::mul_div_round_down(
        replacement_quantity,
        liquidation_ltv,
        constants::float_scaling!(),
    );
    assert!(
        !has_replacement || remaining_terminal_floor < remaining_max_terminal_floor,
        ETerminalFloorExceedsLiquidationLtv,
    );
    let remaining_terminal_payout = replacement_quantity - remaining_terminal_floor;
    let remaining_live_backing_payout = replacement_quantity - remaining_floor_seed_amount;

    // Closed deltas removed from the live indexes: the old order's contribution minus what the
    // replacement keeps. All three stay >= 0 — the mint LTV admission keeps each order's
    // per-unit terminal floor below ltv/FS < 1, and the seed is 1-Lipschitz in quantity, so
    // (old term - remaining term) <= close_quantity (see ledger T3).
    let closed_floor_shares = old_floor_shares - remaining_floor_shares;
    let closed_terminal_payout = old_terminal_payout - remaining_terminal_payout;
    let closed_live_backing_payout = old_live_backing_payout - remaining_live_backing_payout;

    // Index removal and liquidation tracking.
    let live = exposure.live.borrow_mut();
    live
        .payout
        .remove_range(&grid, lower, higher, closed_terminal_payout, closed_live_backing_payout);
    live.nav.remove_range(&grid, lower, higher, close_quantity, closed_floor_shares);
    exposure.liquidation.remove_order(order);
    if (has_replacement) {
        exposure.liquidation.insert_order(&resulting_order);
        exposure.next_order_sequence = exposure.next_order_sequence + 1;
    };

    // Current timestamp -> floor index, fully enumerated. (Replicates floor_index_at_ms;
    // see ledger.) closed_floor_shares is 0 for a 1x order, so closed_floor_amount is 0.
    let now_ms = clock.timestamp_ms();
    let remaining_ms_now = if (now_ms >= exposure.expiry_ms) {
        0
    } else {
        exposure.expiry_ms - now_ms
    };
    let elapsed_ms_now = if (remaining_ms_now >= constants::leverage_floor_window_ms!()) {
        0
    } else {
        constants::leverage_floor_window_ms!() - remaining_ms_now
    };
    let current_floor_phase = predict_math::mul_div_round_down(
        elapsed_ms_now,
        constants::float_scaling!(),
        constants::leverage_floor_window_ms!(),
    );
    let current_floor_phase_squared = predict_math::mul_div_round_down(
        current_floor_phase,
        current_floor_phase,
        constants::float_scaling!(),
    );
    let current_floor_premium = predict_math::mul_div_round_down(
        exposure.config.max_expiry_floor_premium(),
        current_floor_phase_squared,
        constants::float_scaling!(),
    );
    let current_floor_index = constants::float_scaling!() + current_floor_premium;

    // Redeem amount: gross range value minus the current floor on the closed shares.
    let closed_floor_amount = predict_math::mul_div_round_up(
        closed_floor_shares,
        current_floor_index,
        constants::float_scaling!(),
    );
    let gross_redeem_amount = math::mul(range_probability, close_quantity);
    let redeem_amount = gross_redeem_amount - gross_redeem_amount.min(closed_floor_amount);
    (resulting_order, redeem_amount, range_probability)
}

/// Clear one liquidated-order tombstone after its manager position is closed.
public(package) fun clear_liquidated_order(exposure: &mut StrikeExposure, order: &Order) {
    exposure.liquidation.clear_liquidated(order);
}

/// Run one bounded liquidation pass with the full liquidation flow inlined.
///
/// Returns the number of orders liquidated this pass.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
): u64 {
    // Candidate selection mutates the passive-scan watermark; faithful to the
    // reference this runs BEFORE the live-inputs validation gate.
    let candidates = exposure.liquidation.select_liquidation_candidates(budget);
    if (candidates.is_empty()) return 0;

    // Live oracle inputs validate freshness/market-active before any index mutation.
    let (forward, svi) = pricing::live_inputs(config, market, pyth, clock);

    let grid = exposure.grid;
    let mut liquidated_count = 0;
    let mut i = 0;
    while (i < candidates.length()) {
        let order = order::from_order_id(candidates[i]);
        let lower = grid.boundary_at_index(order.lower_boundary_index());
        let higher = grid.boundary_at_index(order.higher_boundary_index());
        // compute_range_price validates the range; keep it before this candidate's removal.
        let range_probability = pricing::compute_range_price(&svi, forward, lower, higher);

        // Liquidation check terms. Candidates are always leveraged, so the floor pipeline is
        // computed unconditionally (seed is 0 only for a 1x order). The current floor amount is
        // collapsed to one round-up from the seed (CC3; ledger §1): ceil(seed * current_index /
        // open_index). It is not an index term — only the should-liquidate gate and the emitted
        // event read it — so its collapse never touches index balance.
        // Open + current floor indexes (replicate floor_index_at_ms at opened_at and now).
        let opened_at_ms = order.opened_at_ms();
        let remaining_ms_at_open = if (opened_at_ms >= exposure.expiry_ms) {
            0
        } else {
            exposure.expiry_ms - opened_at_ms
        };
        let elapsed_ms_at_open = if (
            remaining_ms_at_open >= constants::leverage_floor_window_ms!()
        ) {
            0
        } else {
            constants::leverage_floor_window_ms!() - remaining_ms_at_open
        };
        let open_floor_phase = predict_math::mul_div_round_down(
            elapsed_ms_at_open,
            constants::float_scaling!(),
            constants::leverage_floor_window_ms!(),
        );
        let open_floor_phase_squared = predict_math::mul_div_round_down(
            open_floor_phase,
            open_floor_phase,
            constants::float_scaling!(),
        );
        let open_floor_premium = predict_math::mul_div_round_down(
            exposure.config.max_expiry_floor_premium(),
            open_floor_phase_squared,
            constants::float_scaling!(),
        );
        let open_floor_index = constants::float_scaling!() + open_floor_premium;
        let now_ms = clock.timestamp_ms();
        let remaining_ms_now = if (now_ms >= exposure.expiry_ms) {
            0
        } else {
            exposure.expiry_ms - now_ms
        };
        let elapsed_ms_now = if (remaining_ms_now >= constants::leverage_floor_window_ms!()) {
            0
        } else {
            constants::leverage_floor_window_ms!() - remaining_ms_now
        };
        let current_floor_phase = predict_math::mul_div_round_down(
            elapsed_ms_now,
            constants::float_scaling!(),
            constants::leverage_floor_window_ms!(),
        );
        let current_floor_phase_squared = predict_math::mul_div_round_down(
            current_floor_phase,
            current_floor_phase,
            constants::float_scaling!(),
        );
        let current_floor_premium = predict_math::mul_div_round_down(
            exposure.config.max_expiry_floor_premium(),
            current_floor_phase_squared,
            constants::float_scaling!(),
        );
        let current_floor_index = constants::float_scaling!() + current_floor_premium;
        let floor_seed_amount = order.floor_seed_amount();
        let current_floor_amount = predict_math::mul_div_round_up(
            floor_seed_amount,
            current_floor_index,
            open_floor_index,
        );
        let liquidation_ltv = exposure.config.liquidation_ltv();
        let liquidation_threshold = predict_math::mul_div_round_up(
            current_floor_amount,
            constants::float_scaling!(),
            liquidation_ltv,
        );
        let quantity = order.quantity();
        let gross_value = math::mul(range_probability, quantity);
        let should_liquidate = !(gross_value > liquidation_threshold);

        // Liquidation removes the order from the live indexes and emits the event, gated on
        // should_liquidate. The index-removal terms — collapsed terminal floor (CC2), live
        // backing read straight from the seed (CC1), and the NAV share count — feed only this
        // gated mutation, so they are computed inside the branch (matching the reference, which
        // reaches order_index_update_terms only after the gate). No terminal-floor LTV re-assert:
        // the candidate passed it at creation under the same snapshotted config and unchanged
        // stored fields, so it is provably dead here (see ledger S1). These three values match
        // what mint inserted, so the indexes stay balanced.
        if (should_liquidate) {
            let terminal_floor = predict_math::mul_div_round_up(
                floor_seed_amount,
                constants::float_scaling!() + exposure.config.max_expiry_floor_premium(),
                open_floor_index,
            );
            let terminal_payout = quantity - terminal_floor;
            let live_backing_payout = quantity - floor_seed_amount;
            let floor_shares = predict_math::mul_div_round_up(
                floor_seed_amount,
                constants::float_scaling!(),
                open_floor_index,
            );
            let live = exposure.live.borrow_mut();
            live.payout.remove_range(&grid, lower, higher, terminal_payout, live_backing_payout);
            live.nav.remove_range(&grid, lower, higher, quantity, floor_shares);
            exposure.liquidation.mark_liquidated(&order);
            order_events::emit_order_liquidated(
                exposure.expiry_market_id,
                &order,
                gross_value,
                current_floor_amount,
                liquidation_ltv,
            );
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

/// Abort unless requested leverage is allowed for a new mint at this entry probability.
fun assert_mint_leverage_tier(entry_probability: u64, leverage: u64) {
    assert_valid_leverage(leverage);
    if (entry_probability < constants::leverage_one_x_only_price_threshold!()) {
        assert!(leverage == LEVERAGE_ONE_X, EInvalidLeverageTier);
    } else if (entry_probability < constants::leverage_two_x_max_price_threshold!()) {
        assert!(leverage <= LEVERAGE_TWO_X, EInvalidLeverageTier);
    };
}

fun assert_valid_leverage(leverage: u64) {
    assert!(
        leverage == LEVERAGE_ONE_X
            || leverage == LEVERAGE_ONE_AND_HALF_X
            || leverage == LEVERAGE_TWO_X
            || leverage == LEVERAGE_TWO_AND_HALF_X
            || leverage == LEVERAGE_THREE_X,
        EInvalidLeverage,
    );
}
