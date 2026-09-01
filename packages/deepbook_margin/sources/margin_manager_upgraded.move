// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The oracle-taking entrypoints for `margin_manager`.
///
/// Pyth replaced Core with a separately published package, so its `PriceInfoObject` is a
/// distinct Move type from the legacy one and the frozen signatures in `margin_manager`
/// can never accept it. The oracle surface therefore lives here, under the same function
/// names; each entry reads the upgraded feed and delegates to the shared core in
/// `margin_manager`.
///
/// The legacy-Pyth twins in `margin_manager` and `pool_proxy` are retired: they abort
/// `EDeprecatedUseUpgradedPyth` instead of reading a feed. Until that landed, both
/// families were live and authoritative and `PythReading` erased which feed produced it,
/// so a caller chose per call between two independently-enforced staleness windows with
/// no cross-feed comparison — one leg could be a full window stale while the other was
/// fresh. The expectation that this self-closed at Pyth's cutover did not hold: legacy
/// objects for most configured currencies stayed fresh past it, refreshed by third
/// parties DeepBook does not control.
///
/// Retiring the bodies is only half of it. A package published against an older
/// `deepbook_margin` keeps calling that version's bodies through its own linkage table,
/// so the legacy entries stop being reachable on chain when the admin calls
/// `disable_version` on the version that still carries them — see `margin_constants`.
module deepbook_margin::margin_manager_upgraded;

use deepbook::{order_info::OrderInfo, pool::Pool};
use deepbook_margin::{
    margin_constants,
    margin_manager::{Self, MarginManager},
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle,
    tpsl::{Condition, PendingOrder}
};
use pyth_upgraded::price_info::PriceInfoObject as PriceInfoObjectUpgraded;
use std::type_name;
use sui::{clock::Clock, coin::Coin};

/// Add a conditional order (take-profit / stop-loss). Specifies the condition
/// under which it triggers and the pending order to place when it does.
///
/// Lifetime: the conditional order itself is never clamped — it rests in the
/// queue until it triggers or is cancelled. A *market* pending order
/// (`tpsl::new_pending_market_order`) has no expiry, so it is the "until
/// cancelled" stop: it waits indefinitely and, when triggered, fires and
/// deleverages via `execute_conditional_orders_v3` (so it can protect even in
/// the danger band). A *limit* pending order is intentionally transient — when
/// it triggers, the resting order it places is clamped to `max_order_ttl_ms`
/// (default 3 days) by `clamp_expire_timestamp`, the same stale-price guard as
/// any margin limit order. For a permanent stop, use a market pending order.
public fun add_conditional_order<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObjectUpgraded,
    quote_price_info_object: &PriceInfoObjectUpgraded,
    registry: &MarginRegistry,
    conditional_order_id: u64,
    condition: Condition,
    pending_order: PendingOrder,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.add_conditional_order_core(
        pool,
        oracle::read_price_upgraded<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        conditional_order_id,
        condition,
        pending_order,
        clock,
        ctx,
    )
}

/// Execute conditional orders and return the order infos.
/// This is a permissionless function that can be called by anyone.
///
/// v2 adds `base_margin_pool` + `quote_margin_pool` parameters and enforces
/// a post-fill `risk_ratio >= min_borrow_risk_ratio` invariant inside the
/// inner loop. If any single triggered fill would breach that floor, the
/// entire txn aborts — no partial-state landing.
public fun execute_conditional_orders_v2<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_price_info_object: &PriceInfoObjectUpgraded,
    quote_price_info_object: &PriceInfoObjectUpgraded,
    registry: &MarginRegistry,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &TxContext,
): vector<OrderInfo> {
    self.execute_conditional_orders_v2_core(
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        max_orders_to_execute,
        clock,
        ctx,
    )
}

/// Execute conditional orders, deleveraging on each market-type fill.
/// Permissionless, like `execute_conditional_orders_v2`, with the same trigger
/// and cancellation handling — but takes the margin pools as `&mut` and repays
/// the loan with the market proceeds before gating on the net (post-repay)
/// `risk_ratio` being at least the pre-fill ratio.
///
/// This is what lets a stop-loss fire in the `liquidation..min_borrow` danger
/// band: a swap alone only lowers the oracle-valued ratio (so the v2 borrow-floor
/// gate rejects it), while repaying actually improves it. If a single triggered
/// fill would worsen net solvency the whole txn aborts — no partial-state
/// landing.
public fun execute_conditional_orders_v3<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_price_info_object: &PriceInfoObjectUpgraded,
    quote_price_info_object: &PriceInfoObjectUpgraded,
    registry: &MarginRegistry,
    max_orders_to_execute: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<OrderInfo> {
    self.execute_conditional_orders_v3_core(
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_price_info_object, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_price_info_object, registry, clock),
        registry,
        max_orders_to_execute,
        clock,
        ctx,
    )
}

/// Deposit a coin into the margin manager. The coin must be of the same type as either the base, quote, or DEEP.
public fun deposit<BaseAsset, QuoteAsset, DepositAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    coin: Coin<DepositAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let event_reading = if (
        !margin_manager::emits_collateral_event<BaseAsset, QuoteAsset, DepositAsset>()
    ) {
        option::none()
    } else if (
        type_name::with_defining_ids<DepositAsset>() == type_name::with_defining_ids<BaseAsset>()
    ) {
        option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock))
    } else {
        option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock))
    };

    self.deposit_core(
        registry,
        event_reading,
        coin,
        clock,
        ctx,
    )
}

/// Withdraw a specified amount of an asset from the margin manager. The asset must be of the same type as either the base, quote, or DEEP.
/// The withdrawal is subject to the risk ratio limit.
public fun withdraw<BaseAsset, QuoteAsset, WithdrawAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    withdraw_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<WithdrawAsset> {
    let (risk_base_reading, risk_quote_reading) = if (
        self.withdraw_needs_risk_check(base_margin_pool, quote_margin_pool)
    ) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };
    let (event_base_reading, event_quote_reading) = if (
        margin_manager::emits_collateral_event<BaseAsset, QuoteAsset, WithdrawAsset>()
    ) {
        (
            option::some(oracle::read_price_upgraded_unsafe<BaseAsset>(base_oracle, registry)),
            option::some(oracle::read_price_upgraded_unsafe<QuoteAsset>(quote_oracle, registry)),
        )
    } else {
        (option::none(), option::none())
    };

    self.withdraw_core(
        registry,
        base_margin_pool,
        quote_margin_pool,
        risk_base_reading,
        risk_quote_reading,
        event_base_reading,
        event_quote_reading,
        pool,
        withdraw_amount,
        clock,
        ctx,
    )
}

/// Borrow the base asset using the margin manager.
public fun borrow_base<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.borrow_base_core(
        registry,
        base_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Borrow the quote asset using the margin manager.
public fun borrow_quote<BaseAsset, QuoteAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    loan_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.borrow_quote_core(
        registry,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        loan_amount,
        clock,
        ctx,
    )
}

/// Liquidates an unhealthy margin manager, returning the seized assets and any unspent repay.
public fun liquidate<BaseAsset, QuoteAsset, DebtAsset>(
    self: &mut MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    margin_pool: &mut MarginPool<DebtAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    repay_coin: Coin<DebtAsset>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DebtAsset>) {
    self.liquidate_core(
        registry,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        margin_pool,
        pool,
        repay_coin,
        clock,
        ctx,
    )
}

/// Returns the risk ratio of the margin manager given the corresponding margin pools.
public fun risk_ratio<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    // No debt means no oracle is needed: `assets_in_debt_unit` short-circuits and the
    // ratio is MAX regardless of price. Returning here keeps a stale feed from
    // breaking a read-only query, as it did before Pyth's upgraded Core.
    if (self.margin_pool_id().is_none()) return margin_constants::max_risk_ratio();

    self.risk_ratio_core(
        registry,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

/// Returns the risk ratio without validating staleness, EWMA divergence or confidence - only the feed id is checked.
/// Use for read-only queries where stale prices are acceptable.
public fun risk_ratio_unsafe<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): u64 {
    // No debt means no oracle is needed: `assets_in_debt_unit` short-circuits and the
    // ratio is MAX regardless of price. Returning here keeps a stale feed from
    // breaking a read-only query, as it did before Pyth's upgraded Core.
    if (self.margin_pool_id().is_none()) return margin_constants::max_risk_ratio();

    self.risk_ratio_core(
        registry,
        oracle::read_price_upgraded_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_upgraded_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

/// Returns comprehensive state information for a margin manager.
/// Returns (manager_id, deepbook_pool_id, risk_ratio, base_asset, quote_asset,
///          base_debt, quote_debt, base_pyth_price, base_pyth_decimals,
///          quote_pyth_price, quote_pyth_decimals, current_price,
///          lowest_trigger_above_price, highest_trigger_below_price)
public fun manager_state<BaseAsset, QuoteAsset>(
    self: &MarginManager<BaseAsset, QuoteAsset>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): (ID, ID, u64, u64, u64, u64, u64, u64, u8, u64, u8, u64, u64, u64) {
    self.manager_state_core(
        registry,
        oracle::read_price_upgraded_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_upgraded_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}

/// Returns comprehensive state information for multiple margin managers.
/// Same as manager_state but takes a vector and returns vectors of all values.
/// All managers must be of the same type.
public fun manager_states<BaseAsset, QuoteAsset>(
    margin_managers: &vector<MarginManager<BaseAsset, QuoteAsset>>,
    registry: &MarginRegistry,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    clock: &Clock,
): (
    vector<ID>,
    vector<ID>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
    vector<u8>,
    vector<u64>,
    vector<u8>,
    vector<u64>,
    vector<u64>,
    vector<u64>,
) {
    margin_manager::manager_states_core<BaseAsset, QuoteAsset>(
        margin_managers,
        registry,
        oracle::read_price_upgraded_unsafe<BaseAsset>(base_oracle, registry),
        oracle::read_price_upgraded_unsafe<QuoteAsset>(quote_oracle, registry),
        pool,
        base_margin_pool,
        quote_margin_pool,
        clock,
    )
}
