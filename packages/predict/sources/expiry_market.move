// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns the
/// expiry-local DUSDC allocation, strike exposure state, fee balance, trade execution,
/// valuation witness, and storage cleanup state. Pool-wide PLP accounting and
/// allocation coordination remain outside this module.
module deepbook_predict::expiry_market;

use deepbook::math;
use deepbook_predict::{
    admin::AdminCap,
    claim_events,
    config_events,
    constants,
    market_oracle::{MarketOracle, MarketOracleCap},
    order::{Self, Order},
    order_events,
    predict_manager::PredictManager,
    pricing,
    pricing_config::PricingConfig,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    strike_exposure::{Self, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use sui::{balance::{Self, Balance}, clock::Clock, vec_set::VecSet};

const EWrongMarketOracle: u64 = 0;
const EWrongPythSource: u64 = 1;
const EValuationExceedsCash: u64 = 2;
const EAllocationBelowMaxPayout: u64 = 3;
const EInsufficientLpCash: u64 = 4;
const EInsufficientFeeBalance: u64 = 5;
const EPackageVersionDisabled: u64 = 6;
const EMintPaused: u64 = 7;
const EUnresolvedTradingFeesUnderflow: u64 = 8;
const EFullCloseRequired: u64 = 9;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    /// Trading loss rebate rate snapshotted from fee config at creation.
    trading_loss_rebate_rate: u64,
    /// Active risk budget assigned by the pool.
    allocated_capital: u64,
    /// LP-owned DUSDC backing this expiry's liability.
    lp_cash_balance: Balance<DUSDC>,
    /// Fee cash held until rebate reserve and settled-expiry fee surplus are resolved.
    fee_balance: Balance<DUSDC>,
    /// Trading fees whose rebate eligibility has not been resolved.
    unresolved_trading_fees_paid: u64,
    /// Exposure lifecycle state for this expiry's oracle grid.
    strike_exposure: StrikeExposure,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
    /// When true, `mint` aborts. Other flows (redeem, settle, cleanup) unaffected.
    mint_paused: bool,
}

/// Transaction-local valuation produced by an expiry market.
public struct ExpiryValuation {
    /// Expiry market that produced this valuation.
    expiry_market_id: ID,
    /// LP NAV contribution for this expiry.
    value: u64,
}

// === Public Functions ===

/// Return the expiry market object ID.
public fun id(market: &ExpiryMarket): ID {
    market.id.to_inner()
}

/// Return the market oracle this expiry market is paired with.
public fun market_oracle_id(market: &ExpiryMarket): ID {
    market.market_oracle_id
}

/// Return the Pyth Lazer feed id snapshotted at market creation.
public fun pyth_lazer_feed_id(market: &ExpiryMarket): u32 {
    market.pyth_lazer_feed_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return the DUSDC capital currently allocated to this expiry.
public fun allocated_capital(market: &ExpiryMarket): u64 {
    market.allocated_capital
}

/// Return LP-owned DUSDC currently held by this expiry.
public fun lp_cash_balance(market: &ExpiryMarket): u64 {
    market.lp_cash_balance.value()
}

/// Return DUSDC fees held by this expiry.
public fun fee_balance(market: &ExpiryMarket): u64 {
    market.fee_balance.value()
}

/// Return trading fees whose rebate eligibility has not been resolved.
public fun unresolved_trading_fees_paid(market: &ExpiryMarket): u64 {
    market.unresolved_trading_fees_paid
}

/// Return the trading loss rebate rate snapshotted for this expiry.
public fun trading_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.trading_loss_rebate_rate
}

/// Return the terminal floor-index premium snapshotted for this expiry.
public fun max_expiry_floor_premium(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_expiry_floor_premium()
}

/// Return the liquidation LTV snapshotted for this expiry.
public fun liquidation_ltv(market: &ExpiryMarket): u64 {
    market.strike_exposure.liquidation_ltv()
}

/// Return the trade-fee ramp max multiplier snapshotted for this expiry.
public fun expiry_fee_max_multiplier(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_max_multiplier()
}

/// Return the minimum strike snapshotted for this expiry's oracle grid.
public fun min_strike(market: &ExpiryMarket): u64 {
    market.strike_exposure.min_strike()
}

/// Return the strike tick size snapshotted for this expiry's oracle grid.
public fun tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.tick_size()
}

/// Return the maximum strike snapshotted for this expiry's oracle grid.
public fun max_strike(market: &ExpiryMarket): u64 {
    market.strike_exposure.max_strike()
}

/// Return conservative max-live backing, or remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return DUSDC allocation that can leave while preserving risk and cash backing.
///
/// Live markets use conservative max-live backing; settled markets use remaining
/// materialized payout liability.
public fun returnable_capital(market: &ExpiryMarket): u64 {
    let payout_liability = market.payout_liability();
    let allocated_capital = market.allocated_capital();
    let risk_free = if (allocated_capital > payout_liability) {
        allocated_capital - payout_liability
    } else {
        0
    };
    let lp_cash_balance = market.lp_cash_balance.value();
    let cash_free = if (lp_cash_balance > payout_liability) {
        lp_cash_balance - payout_liability
    } else {
        0
    };
    risk_free.min(cash_free)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Return this market's mirrored set of allowed package versions.
public fun allowed_versions(market: &ExpiryMarket): VecSet<u64> {
    market.allowed_versions
}

/// Set per-market mint pause. Admin can pause or unpause one expiry without
/// changing global trading state.
public fun set_mint_paused(market: &mut ExpiryMarket, _admin_cap: &AdminCap, paused: bool) {
    market.assert_version_allowed();
    market.set_mint_paused_internal(paused);
}

/// Produce this expiry's valuation witness for a full-pool valuation.
///
/// For live markets, valuation first runs a bounded liquidation pass inside
/// strike exposure, then evaluates NAV against the same pricing curve.
/// If the oracle is settled, this also caches terminal payout liability in
/// strike exposure. It does not destroy live indexes; privileged compaction owns that.
public fun produce_valuation(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): ExpiryValuation {
    market.assert_version_allowed();
    config.assert_valuation_in_progress();
    let (position_liability, rebate_reserve) = market.current_nav_terms(
        config,
        market_oracle,
        pyth,
        clock,
    );
    let lp_cash_balance = market.lp_cash_balance.value();
    let fee_balance = market.fee_balance.value();
    assert!(lp_cash_balance >= position_liability, EValuationExceedsCash);
    let position_value = lp_cash_balance - position_liability;
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    let lp_fee_surplus = math::mul(
        fee_balance - rebate_reserve,
        config.fee_config().lp_fee_share(),
    );
    ExpiryValuation {
        expiry_market_id: market.id(),
        value: position_value + lp_fee_surplus,
    }
}

/// Mint a live position interval against this expiry market.
///
/// Requires the package version to be allowed for this market, per-market mint
/// pause to be off, trading globally enabled, manager ownership, a live fresh
/// oracle, enough expiry allocation to back the post-mint max payout, and
/// leveraged floor terms below this expiry's liquidation LTV at terminal.
/// Leveraged mints must also satisfy leverage tier policy and be above the
/// current liquidation threshold at entry.
/// Returns the minted order ID for future order-scoped flows.
public fun mint(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_version_allowed();
    assert!(!market.mint_paused, EMintPaused);
    config.assert_trading_allowed();
    market.mint_internal(
        manager,
        config,
        market_oracle,
        pyth,
        lower_strike,
        higher_strike,
        quantity,
        leverage,
        clock,
        ctx,
    )
}

/// Redeem live or settled order quantity.
///
/// Live redeems can close part or all of an order. Settled and liquidated-order
/// redeems require a full close and return no replacement. Returns
/// `(closed_order_id, replacement_order_id)`.
public fun redeem(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    let redeemed_order = order::from_order_id(order_id);
    if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
        market.redeem_liquidated_order(manager, &redeemed_order, close_quantity);
        return (redeemed_order.id(), option::none())
    };

    if (market_oracle.is_settled()) {
        assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
        market.redeem_settled_internal(manager, market_oracle, &redeemed_order, ctx);
        (redeemed_order.id(), option::none())
    } else {
        market.run_configured_liquidation_pass(
            config.pricing_config(),
            market_oracle,
            pyth,
            config.risk_config().trade_liquidation_budget(),
            clock,
        );
        if (market.strike_exposure.is_liquidated_order(&redeemed_order)) {
            market.redeem_liquidated_order(manager, &redeemed_order, close_quantity);
            return (redeemed_order.id(), option::none())
        };
        let replacement_order_id = market.redeem_live_internal(
            manager,
            config,
            market_oracle,
            pyth,
            &redeemed_order,
            close_quantity,
            clock,
            ctx,
        );
        (redeemed_order.id(), replacement_order_id)
    }
}

/// Run one bounded liquidation pass over active leveraged orders.
///
/// The liquidation book selects up to `budget` candidates and returns the
/// number of orders liquidated. It does not touch PredictManagers; users clear
/// their liquidated position later through `redeem`, receiving no payout.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
): u64 {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market
        .strike_exposure
        .liquidate_live_orders(
            config.pricing_config(),
            market_oracle,
            pyth,
            budget,
            clock,
        )
}

/// Resolve a manager's aggregate expiry trading-loss rebate after all its
/// positions close. Permissionless by design: any caller may settle this for a
/// manager — the rebate is credited to the manager via its deposit cap and the
/// un-granted remainder compounds into PLP cash, so PLP value accrues without
/// the owner acting. The rebate share uses the manager's active staking.
public fun claim_trading_loss_rebate(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    ctx: &mut TxContext,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.materialize_settled_liability(market_oracle);

    let (
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
    ) = manager.resolve_expiry_summary(market.id());
    if (trading_fees_paid == 0 && cash_paid_to_expiry == 0 && cash_received_from_expiry == 0) {
        return
    };

    market.resolve_trading_fee_basis(trading_fees_paid);
    let trading_loss = if (cash_paid_to_expiry > cash_received_from_expiry) {
        cash_paid_to_expiry - cash_received_from_expiry
    } else {
        0
    };
    let max_rebate = math::mul(trading_fees_paid, market.trading_loss_rebate_rate);
    let eligible_rebate = trading_loss.min(max_rebate);

    // Active staking decides the manager's share of the eligible rebate; the
    // remainder compounds into LP cash (returns fully to the pool on the
    // settlement sweep, no protocol/insurance split).
    manager.update_stake(ctx);
    let rebate_fraction = config.stake_config().rebate_fraction(manager.active_stake());
    let (rebate_amount, lp_compound_amount) = apply_stake_benefit(eligible_rebate, rebate_fraction);

    if (rebate_amount > 0) {
        let payout = market.dispense_fee_cash(rebate_amount);
        manager.deposit_permissionless(payout.into_coin(ctx), ctx);
    };
    if (lp_compound_amount > 0) {
        let lp_cash = market.dispense_fee_cash(lp_compound_amount);
        market.lp_cash_balance.join(lp_cash);
    };

    claim_events::emit_trading_loss_rebate_claimed(
        market.id(),
        manager.id(),
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
        rebate_amount,
    );
}

/// Cache terminal liability if needed, then destroy live exposure indexes.
///
/// This is cap-gated because index destruction returns storage rebates. Surplus
/// LP cash and fee cash remain in the expiry until a pool sweep moves them.
public fun compact_storage(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    cap: &MarketOracleCap,
) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    market.assert_market_oracle(market_oracle);
    market_oracle.assert_authorized_cap(cap);
    market.materialize_settled_liability(market_oracle);
    market.strike_exposure.destroy_live_indexes();
    market.assert_cash_backing();
}

// === Public-Package Functions ===

/// Overwrite this market's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_expiry_market_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(market: &mut ExpiryMarket, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Consume an expiry valuation and return its market ID and value.
public(package) fun unpack(valuation: ExpiryValuation): (ID, u64) {
    let ExpiryValuation {
        expiry_market_id,
        value,
    } = valuation;
    (expiry_market_id, value)
}

/// Assert that a market oracle belongs to this expiry market.
public(package) fun assert_market_oracle(market: &ExpiryMarket, market_oracle: &MarketOracle) {
    assert!(market.market_oracle_id == market_oracle.id(), EWrongMarketOracle);
}

/// Abort if the running package version is not allowed for this market.
public(package) fun assert_version_allowed(market: &ExpiryMarket) {
    assert!(
        market.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Create and share a funded expiry market for one market oracle.
///
/// The market snapshots the Pyth feed ID, initializes strike exposure state, and
/// takes custody of the pool-provided allocation as LP cash.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    allocation: Balance<DUSDC>,
    allowed_versions: VecSet<u64>,
    market_oracle_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    preallocated_ticks: u64,
    expiry_fee_max_multiplier: u64,
    ctx: &mut TxContext,
): ID {
    let allocated_capital = allocation.value();
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let market = ExpiryMarket {
        id,
        market_oracle_id,
        pyth_lazer_feed_id,
        expiry,
        trading_loss_rebate_rate: config.fee_config().trading_loss_rebate_rate(),
        allocated_capital,
        lp_cash_balance: allocation,
        fee_balance: balance::zero(),
        unresolved_trading_fees_paid: 0,
        strike_exposure: strike_exposure::new(
            expiry_market_id,
            expiry,
            min_strike,
            tick_size,
            preallocated_ticks,
            config.leverage_config().max_expiry_floor_premium(),
            config.leverage_config().liquidation_ltv(),
            expiry_fee_max_multiplier,
            ctx,
        ),
        allowed_versions,
        mint_paused: false,
    };
    transfer::share_object(market);
    expiry_market_id
}

/// Add pool-provided DUSDC to this live expiry's allocation and LP cash.
public(package) fun receive_allocation(market: &mut ExpiryMarket, allocation: Balance<DUSDC>) {
    market.assert_version_allowed();
    let amount = allocation.value();
    market.allocated_capital = market.allocated_capital + amount;
    market.lp_cash_balance.join(allocation);
}

/// Return free DUSDC allocation from this expiry to the pool.
///
/// Aborts if the requested amount would reduce allocation or cash below the
/// expiry's payout backing requirement.
public(package) fun return_allocation(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    market.assert_version_allowed();
    assert!(amount <= market.returnable_capital(), EAllocationBelowMaxPayout);

    market.allocated_capital = market.allocated_capital - amount;
    market.lp_cash_balance.split(amount)
}

/// Force `mint_paused = true` (used by PauseCap path on registry; one-way).
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.set_mint_paused_internal(true);
}

/// Cache terminal payout liability in strike exposure if it has not already been cached.
public(package) fun materialize_settled_liability(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): u64 {
    market.assert_market_oracle(market_oracle);
    let settlement = pricing::settlement_price(market_oracle);
    market.strike_exposure.materialize_settled_liability(settlement)
}

/// Release settled LP and fee surplus derived from materialized settlement liability.
public(package) fun release_settled_surplus(
    market: &mut ExpiryMarket,
    market_oracle: &MarketOracle,
): (Balance<DUSDC>, Balance<DUSDC>) {
    market.assert_version_allowed();
    let settled_liability = market.materialize_settled_liability(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    assert!(market.lp_cash_balance.value() >= settled_liability, EInsufficientLpCash);
    assert!(market.fee_balance.value() >= rebate_reserve, EInsufficientFeeBalance);

    if (market.allocated_capital > 0) {
        assert!(market.allocated_capital >= settled_liability, EAllocationBelowMaxPayout);
        market.allocated_capital = 0;
    };
    let returned_cash_amount = market.lp_cash_balance.value() - settled_liability;
    let returned_cash = market.lp_cash_balance.split(returned_cash_amount);
    let returned_fees = market.split_fee_surplus();
    market.assert_cash_backing();

    (returned_cash, returned_fees)
}

// === Private Functions ===

fun set_mint_paused_internal(market: &mut ExpiryMarket, paused: bool) {
    market.mint_paused = paused;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), paused);
}

fun current_nav_terms(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, u64) {
    market.assert_market_oracle(market_oracle);
    let rebate_reserve = market.aggregate_rebate_reserve();
    if (market_oracle.is_settled()) {
        let settled_liability = market.materialize_settled_liability(market_oracle);
        (settled_liability, rebate_reserve)
    } else {
        market.assert_pyth_feed(pyth);
        market_oracle.assert_not_pending_settlement(clock);
        // Valuation uses a bounded, policy-tuned liquidation maintenance pass.
        // Residual underwater-order risk is controlled by the configured budget,
        // LTV buffer, priority ordering, and off-chain simulation policy.
        let live_position_liability = market
            .strike_exposure
            .liquidate_and_live_position_liability(
                config.pricing_config(),
                market_oracle,
                pyth,
                config.risk_config().valuation_liquidation_budget(),
                clock,
            );
        (live_position_liability, rebate_reserve)
    }
}

fun aggregate_rebate_reserve(market: &ExpiryMarket): u64 {
    math::mul(market.unresolved_trading_fees_paid, market.trading_loss_rebate_rate)
}

fun assert_pyth_feed(market: &ExpiryMarket, pyth: &PythSource) {
    assert!(market.pyth_lazer_feed_id == pyth.feed_id(), EWrongPythSource);
}

/// Split `amount` by a stake benefit `fraction` (FLOAT_SCALING) into the
/// fraction-weighted part and the remainder. The fee discount discards the
/// weighted part and charges only the remainder — reducing protocol fee margin
/// only, never payout backing, so cash-backing invariants are unaffected. The
/// loss rebate pays the manager the weighted part and compounds the remainder
/// to LPs.
fun apply_stake_benefit(amount: u64, fraction: u64): (u64, u64) {
    let weighted = math::mul(amount, fraction);
    (weighted, amount - weighted)
}

fun run_configured_liquidation_pass(
    market: &mut ExpiryMarket,
    pricing_config: &PricingConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    budget: u64,
    clock: &Clock,
) {
    if (budget == 0) return;

    market.assert_market_oracle(market_oracle);
    if (market_oracle.is_settled()) return;

    market.assert_pyth_feed(pyth);
    market
        .strike_exposure
        .liquidate_live_orders(
            pricing_config,
            market_oracle,
            pyth,
            budget,
            clock,
        );
}

fun builder_fee_amount(builder_code_id: &Option<ID>, fee_amount: u64, quantity: u64): u64 {
    if (builder_code_id.is_some()) {
        math::mul(fee_amount, constants::builder_fee_multiplier!()).min(
            math::mul(quantity, constants::max_builder_fee_rate!()),
        )
    } else {
        0
    }
}

fun redeem_liquidated_order(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    close_quantity: u64,
) {
    assert!(close_quantity == order.quantity(), EFullCloseRequired);
    manager.remove_position(market.id(), order.id());
    market.strike_exposure.clear_liquidated_order(order);
    order_events::emit_liquidated_order_redeemed(market.id(), manager, order);
}

fun assert_allocation_backing(market: &ExpiryMarket) {
    assert!(market.allocated_capital >= market.payout_liability(), EAllocationBelowMaxPayout);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    assert!(market.lp_cash_balance.value() >= market.payout_liability(), EInsufficientLpCash);
}

fun mint_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    lower_strike: u64,
    higher_strike: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    market.assert_market_oracle(market_oracle);
    market.assert_pyth_feed(pyth);
    market.run_configured_liquidation_pass(
        config.pricing_config(),
        market_oracle,
        pyth,
        config.risk_config().trade_liquidation_budget(),
        clock,
    );

    let (minted_order, fee_amount) = market
        .strike_exposure
        .allocate_mint_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            lower_strike,
            higher_strike,
            quantity,
            leverage,
            clock,
        );
    let fee_discount = config.stake_config().fee_discount_fraction(manager.active_stake());
    let (_, fee_amount) = apply_stake_benefit(fee_amount, fee_discount);

    market.assert_allocation_backing();
    let builder_fee_amount = market.settle_mint_payment(
        manager,
        &minted_order,
        fee_amount,
        ctx,
    );
    order_events::emit_order_minted(
        market.id(),
        manager,
        &minted_order,
        lower_strike,
        higher_strike,
        fee_amount,
        builder_fee_amount,
    );
    minted_order.id()
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    market_oracle: &MarketOracle,
    pyth: &PythSource,
    order: &Order,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    manager.assert_owner(ctx);
    manager.update_stake(ctx);
    market.assert_pyth_feed(pyth);
    pricing::assert_live_quote_available(config.pricing_config(), market_oracle, pyth, clock);
    manager.remove_position(market.id(), order.id());

    let (resulting_order, redeem_amount, fee_amount) = market
        .strike_exposure
        .close_and_quote_live_order(
            config.pricing_config(),
            market_oracle,
            pyth,
            order,
            close_quantity,
            clock,
        );
    let fee_discount = config.stake_config().fee_discount_fraction(manager.active_stake());
    let (_, fee_amount) = apply_stake_benefit(fee_amount, fee_discount);

    let replacement_order_id = if (resulting_order.id() == order.id()) {
        option::none()
    } else {
        let replacement_order_id = resulting_order.id();
        manager.add_position(market.id(), replacement_order_id);
        option::some(replacement_order_id)
    };

    let builder_fee_amount = market.settle_live_redeem_payment(
        manager,
        redeem_amount,
        fee_amount,
        close_quantity,
        ctx,
    );

    order_events::emit_live_order_redeemed(
        market.id(),
        manager,
        order,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
    );
    replacement_order_id
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    market_oracle: &MarketOracle,
    order: &Order,
    ctx: &mut TxContext,
) {
    manager.remove_position(market.id(), order.id());
    market.materialize_settled_liability(market_oracle);

    let settlement = pricing::settlement_price(market_oracle);
    let payout_amount = market.strike_exposure.close_settled_order(order, settlement);
    market.settle_settled_redeem_payment(manager, payout_amount, ctx);

    order_events::emit_settled_order_redeemed(
        market.id(),
        manager,
        order,
        settlement,
        payout_amount,
    );
}

fun settle_mint_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    fee_amount: u64,
    ctx: &mut TxContext,
): u64 {
    let quantity = order.quantity();
    let user_contribution = order.user_contribution();
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let withdraw_amount = user_contribution + fee_amount + builder_fee_amount;

    manager.add_position(market.id(), order.id());
    let mut payment = manager.withdraw(withdraw_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let payment_amount = payment.value();
    let fee_payment = payment.split(fee_amount);
    market.collect_trade_fee(manager, fee_payment);
    market.lp_cash_balance.join(payment);
    manager.record_cash_paid_to_expiry(market.id(), payment_amount);

    market.assert_cash_backing();
    builder_fee_amount
}

/// Settle a live redeem and return the builder fee paid.
fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    redeem_amount: u64,
    fee_amount: u64,
    redeemed_quantity: u64,
    ctx: &mut TxContext,
): u64 {
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        redeemed_quantity,
    ).min(
        redeem_amount - fee_amount,
    );

    let mut payout = market.dispense_lp_cash(redeem_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.collect_trade_fee(manager, fee);
    send_builder_fee(builder_code_id, builder_fee);

    market.assert_cash_backing();
    deposit_live_payout(manager, market, payout, ctx);
    builder_fee_amount
}

fun settle_settled_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    payout_amount: u64,
    ctx: &mut TxContext,
) {
    let payout = market.dispense_lp_cash(payout_amount);
    deposit_permissionless_payout(manager, market, payout, ctx);

    market.assert_cash_backing();
}

fun collect_trade_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee: Balance<DUSDC>,
) {
    let fee_amount = fee.value();
    market.fee_balance.join(fee);
    if (fee_amount == 0) return;
    manager.record_trading_fee_paid(market.id(), fee_amount);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid + fee_amount;
}

fun deposit_live_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit(payout.into_coin(ctx), ctx);
}

fun deposit_permissionless_payout(
    manager: &mut PredictManager,
    market: &ExpiryMarket,
    payout: Balance<DUSDC>,
    ctx: &mut TxContext,
) {
    manager.record_cash_received_from_expiry(market.id(), payout.value());
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);
}

fun resolve_trading_fee_basis(market: &mut ExpiryMarket, amount: u64) {
    assert!(market.unresolved_trading_fees_paid >= amount, EUnresolvedTradingFeesUnderflow);
    market.unresolved_trading_fees_paid = market.unresolved_trading_fees_paid - amount;
}

fun split_fee_surplus(market: &mut ExpiryMarket): Balance<DUSDC> {
    let rebate_reserve = market.aggregate_rebate_reserve();
    let fee_balance = market.fee_balance.value();
    assert!(fee_balance >= rebate_reserve, EInsufficientFeeBalance);
    market.fee_balance.split(fee_balance - rebate_reserve)
}

fun dispense_lp_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.lp_cash_balance.value() >= amount, EInsufficientLpCash);
    market.lp_cash_balance.split(amount)
}

fun dispense_fee_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    assert!(market.fee_balance.value() >= amount, EInsufficientFeeBalance);
    market.fee_balance.split(amount)
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}
