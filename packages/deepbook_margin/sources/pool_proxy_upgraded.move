// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The oracle-taking entrypoints for `pool_proxy`.
///
/// Pyth replaced Core with a separately published package, so its `PriceInfoObject` is a
/// distinct Move type from the legacy one and the frozen signatures in `pool_proxy` can
/// never accept it. The oracle surface therefore lives here, under the same function
/// names; each entry reads the upgraded feed and delegates to the shared core in
/// `pool_proxy`. The legacy-Pyth twins in `pool_proxy` are retired and abort
/// `EDeprecatedUseUpgradedPyth`; the module-level note in `margin_manager_upgraded`
/// records why, and what has to happen on chain for them to stop being reachable.
module deepbook_margin::pool_proxy_upgraded;

use deepbook::{order_info::OrderInfo, pool::Pool};
use deepbook_margin::{
    margin_manager::MarginManager,
    margin_pool::MarginPool,
    margin_registry::MarginRegistry,
    oracle,
    pool_proxy
};
use pyth_upgraded::price_info::PriceInfoObject as PriceInfoObjectUpgraded;
use sui::clock::Clock;

/// Updates the current price for a pool using safe oracle price calculation.
/// Anyone can call this to update the price oracle used for order validation.
public fun update_current_price<BaseAsset, QuoteAsset>(
    registry: &mut MarginRegistry,
    pool: &Pool<BaseAsset, QuoteAsset>,
    base_price_info_object: &PriceInfoObjectUpgraded,
    quote_price_info_object: &PriceInfoObjectUpgraded,
    clock: &Clock,
) {
    // Safe reads enforce staleness, feed id, and EWMA. Price conversion enforces confidence.
    let base_reading = oracle::read_price_upgraded<BaseAsset>(
        base_price_info_object,
        registry,
        clock,
    );
    let quote_reading = oracle::read_price_upgraded<QuoteAsset>(
        quote_price_info_object,
        registry,
        clock,
    );

    pool_proxy::update_current_price_core<BaseAsset, QuoteAsset>(
        registry,
        pool,
        base_reading,
        quote_reading,
        clock,
    )
}

/// Places a limit order in the pool.
public fun place_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_limit_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Places a market order in the pool.
public fun place_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_market_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Places a reduce-only order in the pool. Used when margin trading is disabled.
public fun place_reduce_only_limit_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_limit_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Places a reduce-only market order in the pool. Used when margin trading is
/// disabled.
///
/// Superseded by `place_reduce_only_market_order_and_repay_loan`. A market
/// (taker) fill always pays the spread, which lowers the oracle-valued
/// `risk_ratio` while the debt is unchanged, so the swap-only monotonic check
/// here rejects essentially every taker fill. The `_and_repay` variant
/// deleverages with the proceeds so the net-state ratio actually improves. Kept
/// callable for existing integrators; its reduce-only *direction* guard matches
/// the other entries — a bid needs base (short-side) debt, the ask needs quote
/// (long-side) debt and sells up to gross base held — with no size cap.
public fun place_reduce_only_market_order_v2<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &MarginPool<BaseAsset>,
    quote_margin_pool: &MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_market_order_v2_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Atomically winds down a leveraged position: places a reduce-only market
/// order, repays the loan with the proceeds, then requires the net (post-repay)
/// risk ratio to be at least the pre-trade ratio.
///
/// The post-repay check is the point. A market close pays the spread, which
/// alone lowers the oracle-valued ratio (debt is unchanged until repay) and
/// would abort the plain reduce-only path. Repaying first deleverages and
/// absorbs the slippage (still bounded by the `assert_price` band), and lets a
/// manager in the `liquidation..min_borrow` band climb out — it cannot reach
/// the borrow floor in a single swap.
public fun place_reduce_only_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_market_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}

/// Reduce-only **limit** order that atomically repays the loan with the taker
/// fills. It is the limit/maker behaviour of `place_reduce_only_limit_order_v2`
/// plus the repay-then-net-monotonic gate of
/// `place_reduce_only_market_order_and_repay_loan`: the portion that crosses the
/// book fills immediately and settles, the rest rests as a maker, then the
/// settled (taker) proceeds repay the debt before the monotonic check on the net
/// (post-repay) state.
///
/// This is the danger-band tool for a *price-bounded* reduce: a crossing
/// reduce-only limit pays the spread on its taker fills, which alone would abort
/// `place_reduce_only_limit_order_v2`'s swap-only monotonic check; repaying first
/// deleverages so the net ratio holds. The resting remainder only locks balance
/// (counted in assets), so it doesn't move the ratio. Unfilled-and-resting
/// behaves exactly like `place_reduce_only_limit_order_v2` (nothing to repay).
public fun place_reduce_only_limit_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    pool_proxy::place_reduce_only_limit_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock),
        oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock),
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        ctx,
    )
}

/// Atomically places a market order and repays the loan with the proceeds,
/// gating on a **monotonic** net-state check: if any debt remains after the
/// repay, the post-repay `risk_ratio` must be at least the pre-trade ratio
/// (improve-or-hold). A full close drives debt to 0 (`risk_ratio` MAX), which
/// always passes.
///
/// This is the everyday close / deleverage tool. The monotonic gate — rather than
/// the `min_open` opening floor used by `place_market_order_v2` — lets a position
/// in the `liquidation..min_borrow` danger band wind down *partially*: a small
/// close that lifts the ratio from, say, 1.12 to 1.15 is allowed even though 1.15
/// is still below `min_open`, which the opening floor would reject.
///
/// Not reduce-only and uncapped, but the monotonic check makes a quantity cap
/// unnecessary: a market (taker) fill settles immediately, so any genuinely
/// exposure-*increasing* trade lowers the ratio and aborts here, while any
/// deleveraging trade is allowed at any size — an overshoot past the debt is fine
/// (surplus is the manager's own holding) and `assert_price` still bounds
/// slippage. Requires margin trading enabled; in reduce-only mode use
/// `place_reduce_only_market_order_and_repay_loan`.
public fun place_market_order_and_repay_loan<BaseAsset, QuoteAsset>(
    registry: &MarginRegistry,
    margin_manager: &mut MarginManager<BaseAsset, QuoteAsset>,
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    base_margin_pool: &mut MarginPool<BaseAsset>,
    quote_margin_pool: &mut MarginPool<QuoteAsset>,
    base_oracle: &PriceInfoObjectUpgraded,
    quote_oracle: &PriceInfoObjectUpgraded,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    // A debt-free manager needs no price: every consumer below is debt-gated, so
    // reading eagerly would let a stale feed block an order that used to succeed.
    let (base_reading, quote_reading) = if (margin_manager.has_debt()) {
        (
            option::some(oracle::read_price_upgraded<BaseAsset>(base_oracle, registry, clock)),
            option::some(oracle::read_price_upgraded<QuoteAsset>(quote_oracle, registry, clock)),
        )
    } else {
        (option::none(), option::none())
    };

    pool_proxy::place_market_order_and_repay_loan_core<BaseAsset, QuoteAsset>(
        registry,
        margin_manager,
        pool,
        base_margin_pool,
        quote_margin_pool,
        base_reading,
        quote_reading,
        client_order_id,
        self_matching_option,
        quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    )
}
