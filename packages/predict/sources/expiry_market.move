// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Per-expiry Predict market.
///
/// An ExpiryMarket is the hot shared object for one expiry. It owns trade
/// execution, strike exposure state, and an embedded expiry-cash custody
/// component. Live oracle validation is delegated to `pricing::load_live_pricer`;
/// this module owns market flow policy and then passes loaded `Pricer` snapshots
/// into exposure business logic. Pool-wide PLP accounting and profit accounting
/// remain outside this module.
module deepbook_predict::expiry_market;

use deepbook_predict::{
    admin::AdminCap,
    config_events,
    constants,
    ewma::{Self, EwmaState},
    ewma_config::EwmaConfig,
    expiry_cash::{Self, ExpiryCash},
    order::{Self, Order},
    order_events,
    predict_manager::{PredictManager, PredictTradeProof},
    pricing,
    protocol_config::ProtocolConfig,
    strike_exposure::{Self, StrikeExposure}
};
use dusdc::dusdc::DUSDC;
use fixed_math::math;
use propbook::{block_scholes_feed::BlockScholesFeed, pyth_feed::PythFeed, registry::OracleRegistry};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, vec_set::VecSet};

const EPackageVersionDisabled: u64 = 3;
const EMintPaused: u64 = 4;
const EFullCloseRequired: u64 = 5;
const EProofRequiredForLiveRedeem: u64 = 6;
const ENotImplemented: u64 = 7;

/// Per-expiry market state.
public struct ExpiryMarket has key {
    id: UID,
    /// Propbook underlying this market was created for.
    propbook_underlying_id: u32,
    expiry: u64,
    /// DUSDC custody, payout backing, and unresolved rebate reserve basis.
    cash: ExpiryCash,
    /// Exposure lifecycle state for this expiry's strike ticks.
    strike_exposure: StrikeExposure,
    /// Smoothed gas-price stats backing the congestion trade penalty.
    ewma: EwmaState,
    /// When true, new mints on this expiry abort. Other flows stay available.
    /// Admin sets/unsets it (version-gated); a `PauseCap` holder can force it
    /// true one-way through the registry (ungated kill switch).
    mint_paused: bool,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
}

// === Public Functions ===

/// Return the expiry market object ID.
public fun id(market: &ExpiryMarket): ID {
    market.id.to_inner()
}

/// Return the Propbook underlying this market was created for.
public fun propbook_underlying_id(market: &ExpiryMarket): u32 {
    market.propbook_underlying_id
}

/// Return the expiry timestamp in milliseconds.
public fun expiry(market: &ExpiryMarket): u64 {
    market.expiry
}

/// Return DUSDC currently held by this expiry.
public fun cash_balance(market: &ExpiryMarket): u64 {
    market.cash.balance()
}

/// Return DUSDC reserved for unresolved trading loss rebates.
public fun rebate_reserve(market: &ExpiryMarket): u64 {
    market.cash.rebate_reserve()
}

/// Return the trading loss rebate rate snapshotted for this expiry.
public fun trading_loss_rebate_rate(market: &ExpiryMarket): u64 {
    market.cash.trading_loss_rebate_rate()
}

/// Return the terminal floor index snapshotted for this expiry.
public fun terminal_floor_index(market: &ExpiryMarket): u64 {
    market.strike_exposure.terminal_floor_index()
}

/// Return the liquidation LTV snapshotted for this expiry.
public fun liquidation_ltv(market: &ExpiryMarket): u64 {
    market.strike_exposure.liquidation_ltv()
}

/// Return the backing-buffer lambda snapshotted for this expiry.
public fun backing_buffer_lambda(market: &ExpiryMarket): u64 {
    market.strike_exposure.backing_buffer_lambda()
}

/// Return the trade-fee ramp window snapshotted for this expiry.
public fun expiry_fee_window_ms(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_window_ms()
}

/// Return the trade-fee ramp max multiplier snapshotted for this expiry.
public fun expiry_fee_max_multiplier(market: &ExpiryMarket): u64 {
    market.strike_exposure.expiry_fee_max_multiplier()
}

/// Return the strike tick size snapshotted for this expiry. Raw strikes are
/// derived off-chain / by the SDK as `tick * tick_size`.
public fun tick_size(market: &ExpiryMarket): u64 {
    market.strike_exposure.tick_size()
}

/// Return buffered live reserve, or exact remaining settled payout liability once materialized.
public fun payout_liability(market: &ExpiryMarket): u64 {
    market.strike_exposure.payout_liability()
}

/// Return this expiry market's exact live NAV: free cash minus the exact
/// per-order live liability, floored at zero. This is structurally the live
/// primitive — a past-expiry or stale market aborts here, and an empty or
/// order-free live market returns free cash (zero liability).
///
/// A pure read with no backing assert: backing is owned by the payout-tree reserve
/// and proven on every trade, and the `max(0, ·)` cash floor marks a degenerate
/// (underwater) market at 0 — the correct per-market limited-recourse value, never
/// negative. `pricing::load_live_pricer` binds the passed propbook feeds to this
/// market's current Propbook registry mapping, rejects a past-expiry market, and
/// gates surface freshness.
///
/// FLUSH-LIVENESS PRECONDITION (settlement-v2): `pricing::load_live_pricer`
/// makes pre-expiry liveness a hard precondition for the pool flush. A
/// past-expiry market that has not settled aborts here, and because settlement is
/// stubbed (`is_settled()` is always false, so the settled-sweep that would drop
/// it from the active set is dead), `value_expiry` -> `current_nav` then bricks
/// `finish_flush` pool-wide. There is no solvency-safe NAV for an unsettled
/// past-expiry market: the flush uses one mark for both supply and withdraw, so
/// the mark must equal the (settlement-dependent, here undefined) true value.
/// Until settlement-v2 restores the sweep, the operator MUST NOT let an active
/// market cross its expiry across a flush — create only far-dated markets and
/// settle before expiry.
public fun current_nav(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
): u64 {
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    let liability = market.strike_exposure.exact_live_liability(&pricer, clock);
    market.cash.free_cash().saturating_sub(liability)
}

/// Return whether minting is currently paused on this expiry market.
public fun mint_paused(market: &ExpiryMarket): bool {
    market.mint_paused
}

/// Return this market's mirrored set of allowed package versions.
public fun allowed_versions(market: &ExpiryMarket): VecSet<u64> {
    market.allowed_versions
}

/// Mint a live position interval against this expiry market.
///
/// Requires the package version to be allowed for this market, per-market mint
/// pause to be off, trading globally enabled, a valid `PredictTradeProof` for
/// the manager, a live fresh oracle, enough expiry cash to back the post-mint
/// max payout and rebate reserve, and leveraged floor terms below this expiry's
/// liquidation LTV at terminal. Leveraged mints must also satisfy leverage tier
/// policy and be above the current liquidation threshold at entry. Mint fees are
/// paid by routing a withdraw through the manager's trade proof, so the proof is
/// required even for owner-initiated mints. The position's strike range is the
/// tick pair `(lower_tick, higher_tick]` (`lower_tick = 0` is `-inf`,
/// `higher_tick = pos_inf_tick` is `+inf`); the SDK converts raw strikes to ticks.
/// Returns the minted order ID for future order-scoped flows.
public fun mint(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    market.assert_version_allowed();
    assert!(!market.mint_paused, EMintPaused);
    config.assert_trading_allowed();
    config.assert_not_valuation_in_progress();
    market.mint_internal(
        manager,
        proof,
        config,
        propbook_registry,
        pyth,
        bs,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
        clock,
        ctx,
    )
}

/// Redeem an order you hold trade authority over (the manager owner or a
/// `PredictTradeCap` holder), authorized by a `PredictTradeProof`. Works in any
/// order state: a live order is priced and closed (partial or full); a settled
/// or already-liquidated order is fully closed and the proof is ignored (it has
/// `drop`). Returns `(closed_order_id, replacement_order_id)`; a replacement is
/// present only when a live partial close leaves quantity open.
public fun redeem(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: PredictTradeProof,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    market.redeem_internal(
        manager,
        option::some(proof),
        config,
        propbook_registry,
        pyth,
        bs,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Permissionlessly redeem a resolved order without trade authority: a settled
/// market full close (payout credited to the order's manager) or clearing an
/// already-liquidated order (no payout). Any caller may run this for keeper
/// sweeps / cleanup. Aborts with `EProofRequiredForLiveRedeem` if the order is
/// still live, since closing live risk requires a proof. Requires a full close.
public fun redeem_settled(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    market.redeem_internal(
        manager,
        option::none(),
        config,
        propbook_registry,
        pyth,
        bs,
        order_id,
        close_quantity,
        clock,
        ctx,
    )
}

/// Run one bounded liquidation pass over active leveraged orders.
///
/// The liquidation book selects up to `budget` candidates and returns the
/// number of orders liquidated. It does not touch PredictManagers; users clear
/// their liquidated position later through `redeem`, receiving no payout.
public fun liquidate(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    budget: u64,
    clock: &Clock,
): u64 {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    market.run_liquidation_pass(
        &pricer,
        budget,
        clock,
    )
}

/// Try to liquidate one active leveraged order by ID.
public fun liquidate_order(
    market: &mut ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    clock: &Clock,
): bool {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);

    let order = order::from_order_id(order_id);
    market.strike_exposure.liquidate_live_order(&pricer, &order, clock)
}

/// Set whether new mints are paused on this expiry market. Admin-only and
/// version-gated. A `PauseCap` holder can force-engage the pause one-way under a
/// version freeze via `registry::pause_expiry_market_mint_pause_cap`.
public fun set_mint_paused(market: &mut ExpiryMarket, _admin_cap: &AdminCap, paused: bool) {
    market.assert_version_allowed();
    market.mint_paused = paused;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), paused);
}

// === Public-Package Functions ===

/// Whether terminal settlement has been recorded. Settlement is deferred to
/// settlement-v2 (off Propbook exact timestamp history), so this is always false today;
/// the settled-redeem and settled-sweep paths stay in place, gated on it.
public(package) fun is_settled(_market: &ExpiryMarket): bool {
    false
}

/// The terminal settlement price. Aborts `ENotImplemented` until settlement-v2 —
/// only reachable through `is_settled`-gated paths, which are unreachable under the
/// stub, so this abort never fires in practice.
public(package) fun settlement_price(_market: &ExpiryMarket): u64 {
    abort ENotImplemented
}

/// Abort if the running package version is not allowed for this market.
public(package) fun assert_version_allowed(market: &ExpiryMarket) {
    assert!(
        market.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Overwrite this market's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_expiry_market_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(market: &mut ExpiryMarket, allowed_versions: VecSet<u64>) {
    market.allowed_versions = allowed_versions;
}

/// Force `mint_paused = true`. Reserved for `PauseCap` holders going through
/// `registry::pause_expiry_market_mint_pause_cap`; cannot unpause. Deliberately
/// not version-gated so the kill switch survives a version freeze.
public(package) fun pause_mint(market: &mut ExpiryMarket) {
    market.mint_paused = true;
    config_events::emit_expiry_market_mint_paused_updated(market.id(), true);
}

/// Receive pool-provided cash without interpreting pool allocation policy.
public(package) fun receive_pool_cash(market: &mut ExpiryMarket, cash: Balance<DUSDC>) {
    market.assert_version_allowed();
    market.cash.receive(cash);
    market.assert_cash_backing();
}

/// Release pool cash while preserving expiry-local payout and rebate backing.
public(package) fun release_pool_cash(market: &mut ExpiryMarket, amount: u64): Balance<DUSDC> {
    market.assert_version_allowed();
    if (amount == 0) {
        return balance::zero()
    };
    let payout_liability = market.payout_liability();
    let released_cash = market.cash.release_surplus(amount, payout_liability);
    market.assert_cash_backing();
    released_cash
}

/// Materialize this expiry's settled payout liability and release every unit of
/// cash above it back to the pool. Used by the settled-market sweep, which then
/// deactivates the expiry and materializes its profit.
public(package) fun release_settled_pool_cash(market: &mut ExpiryMarket): Balance<DUSDC> {
    market.assert_version_allowed();
    let settled_liability = market.materialize_settled_liability();
    let reserved_cash = market.cash.required_cash(settled_liability);
    market.cash.assert_backing(settled_liability);

    let returned_cash_amount = market.cash.balance() - reserved_cash;
    market.release_pool_cash(returned_cash_amount)
}

/// Create and share a zero-cash expiry market for one Propbook underlying.
///
/// The market snapshots the underlying, tick size, and per-market config and
/// starts with zero expiry cash; it needs no live spot at creation (strikes are
/// absolute ticks, so there is no grid to center). Current oracle object IDs stay
/// in Propbook and are resolved on every priced flow. The `MarketCreated` event
/// is emitted here rather than in `registry`: the market owns the snapshotted
/// `tick_size`, and the registry holds no reference after `share_object`.
public(package) fun create_and_share(
    config: &ProtocolConfig,
    allowed_versions: VecSet<u64>,
    propbook_underlying_id: u32,
    pool_vault_id: ID,
    expiry: u64,
    tick_size: u64,
    ctx: &mut TxContext,
): ID {
    let id = object::new(ctx);
    let expiry_market_id = id.to_inner();
    let cash_config = config.expiry_cash_config_snapshot();
    let strike_exposure_config = config.strike_exposure_config_snapshot();
    config_events::emit_market_config_snapshot(
        expiry_market_id,
        &strike_exposure_config,
        &cash_config,
    );
    let market = ExpiryMarket {
        id,
        propbook_underlying_id,
        expiry,
        cash: expiry_cash::new(cash_config),
        strike_exposure: strike_exposure::new(
            expiry_market_id,
            expiry,
            tick_size,
            strike_exposure_config,
            ctx,
        ),
        ewma: ewma::new(ctx),
        mint_paused: false,
        allowed_versions,
    };
    config_events::emit_market_created(
        expiry_market_id,
        pool_vault_id,
        propbook_underlying_id,
        expiry,
        market.tick_size(),
    );
    transfer::share_object(market);
    expiry_market_id
}

// === Private Functions ===

/// Cache terminal payout liability in strike exposure if it has not already been cached.
fun materialize_settled_liability(market: &mut ExpiryMarket): u64 {
    let settlement = market.settlement_price();
    market.strike_exposure.materialize_settled_liability(settlement)
}

fun load_live_pricer(
    market: &ExpiryMarket,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    clock: &Clock,
): pricing::Pricer {
    pricing::load_live_pricer(
        config.pricing_config(),
        propbook_registry,
        market.propbook_underlying_id,
        pyth,
        bs,
        market.expiry,
        clock,
    )
}

/// Run one expiry-local liquidation pass with the caller-selected budget and
/// already-loaded live pricer. Version gating lives on the public entrypoints
/// (`mint`, `redeem`, `liquidate`) that reach this helper.
fun run_liquidation_pass(
    market: &mut ExpiryMarket,
    pricer: &pricing::Pricer,
    budget: u64,
    clock: &Clock,
): u64 {
    market
        .strike_exposure
        .liquidate_live_orders(
            pricer,
            budget,
            clock,
        )
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

/// Shared redeem dispatch behind `redeem` (proof) and `redeem_settled` (none).
/// `proof` is consumed only on the live branch; the settled and liquidated
/// branches drop it. The live branch requires `some`, else
/// `EProofRequiredForLiveRedeem`.
fun redeem_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: Option<PredictTradeProof>,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    order_id: u256,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    market.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    let redeemed_order = order::from_order_id(order_id);
    if (market.try_redeem_if_liquidated(manager, &redeemed_order, close_quantity))
        return (redeemed_order.id(), option::none());

    if (market.is_settled()) {
        assert!(close_quantity == redeemed_order.quantity(), EFullCloseRequired);
        market.redeem_settled_internal(manager, &redeemed_order, ctx);
        (redeemed_order.id(), option::none())
    } else {
        let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
        market.run_liquidation_pass(
            &pricer,
            config.trade_liquidation_budget(),
            clock,
        );
        if (market.try_redeem_if_liquidated(manager, &redeemed_order, close_quantity))
            return (redeemed_order.id(), option::none());
        assert!(proof.is_some(), EProofRequiredForLiveRedeem);
        let live_proof = proof.destroy_some();
        let replacement_order_id = market.redeem_live_internal(
            manager,
            &live_proof,
            config,
            &pricer,
            &redeemed_order,
            close_quantity,
            clock,
            ctx,
        );
        (redeemed_order.id(), replacement_order_id)
    }
}

/// If `order` has been liquidated, clear it (full close) and return `true`;
/// otherwise leave state untouched and return `false`.
fun try_redeem_if_liquidated(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    close_quantity: u64,
): bool {
    if (market.strike_exposure.is_liquidated_order(order)) {
        market.redeem_liquidated_order(manager, order, close_quantity);
        true
    } else {
        false
    }
}

fun redeem_liquidated_order(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    close_quantity: u64,
) {
    assert!(close_quantity == order.quantity(), EFullCloseRequired);
    let position_root_id = manager.remove_position(market.id(), order.id());
    market.strike_exposure.clear_liquidated_order(order);
    order_events::emit_liquidated_order_redeemed(market.id(), manager, order, position_root_id);
}

fun assert_cash_backing(market: &ExpiryMarket) {
    market.cash.assert_backing(market.payout_liability());
}

/// Fold the current gas price into this market's EWMA and return the congestion
/// surcharge (in DUSDC) for `quantity`, zero unless the penalty is enabled and
/// gas is a high outlier. Mutates the smoothed estimate on every trade.
fun ewma_penalty(
    market: &mut ExpiryMarket,
    config: &EwmaConfig,
    quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    market.ewma.update(config, clock, ctx);
    market.ewma.penalty_fee(config, quantity, ctx)
}

fun mint_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs: &BlockScholesFeed,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    leverage: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let pricer = market.load_live_pricer(config, propbook_registry, pyth, bs, clock);
    // Proof is validated inside withdraw_with_proof below. Live oracle validation
    // and liveness are resolved into `pricer` before any trade mutation.
    manager.update_stake(ctx);
    market.run_liquidation_pass(
        &pricer,
        config.trade_liquidation_budget(),
        clock,
    );

    let (minted_order, entry_probability, net_premium) = market
        .strike_exposure
        .allocate_mint_order(
            &pricer,
            lower_tick,
            higher_tick,
            quantity,
            leverage,
            clock,
        );
    let raw_fee_amount = market.strike_exposure.trading_fee(entry_probability, quantity, clock);
    let fee_amount = config
        .stake_config()
        .fee_amount_after_discount(raw_fee_amount, manager.active_stake());
    let penalty_amount = market.ewma_penalty(config.ewma_config(), quantity, clock, ctx);

    let builder_fee_amount = market.settle_mint_payment(
        manager,
        proof,
        &minted_order,
        net_premium,
        fee_amount,
        penalty_amount,
        ctx,
    );
    order_events::emit_order_minted(
        market.id(),
        manager,
        &minted_order,
        leverage,
        entry_probability,
        net_premium,
        fee_amount,
        builder_fee_amount,
        penalty_amount,
    );
    minted_order.id()
}

fun redeem_live_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    config: &ProtocolConfig,
    pricer: &pricing::Pricer,
    order: &Order,
    close_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    // Proof is validated inside deposit_with_proof below. Live oracle validation
    // and liveness are resolved into `pricer` before the live branch mutates.
    manager.update_stake(ctx);
    let position_root_id = manager.remove_position(market.id(), order.id());

    let (resulting_order, redeem_amount, range_probability) = market
        .strike_exposure
        .close_and_quote_live_order(
            pricer,
            order,
            close_quantity,
            clock,
        );
    let fee_amount = market
        .strike_exposure
        .trading_fee(
            range_probability,
            close_quantity,
            clock,
        )
        .min(redeem_amount);
    let fee_amount = config
        .stake_config()
        .fee_amount_after_discount(fee_amount, manager.active_stake());
    let penalty_amount = market.ewma_penalty(config.ewma_config(), close_quantity, clock, ctx);

    let replacement_order_id = if (resulting_order.id() == order.id()) {
        option::none()
    } else {
        let replacement_order_id = resulting_order.id();
        manager.add_position(market.id(), replacement_order_id, position_root_id);
        option::some(replacement_order_id)
    };

    let (builder_fee_amount, penalty_amount) = market.settle_live_redeem_payment(
        manager,
        proof,
        redeem_amount,
        fee_amount,
        penalty_amount,
        close_quantity,
        ctx,
    );

    order_events::emit_live_order_redeemed(
        market.id(),
        manager,
        order,
        position_root_id,
        close_quantity,
        replacement_order_id,
        redeem_amount,
        fee_amount,
        builder_fee_amount,
        penalty_amount,
    );
    replacement_order_id
}

fun redeem_settled_internal(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    order: &Order,
    ctx: &mut TxContext,
) {
    let position_root_id = manager.remove_position(market.id(), order.id());
    market.materialize_settled_liability();

    let settlement = market.settlement_price();
    let payout_amount = market.strike_exposure.close_settled_order(order, settlement);
    market.settle_settled_redeem_payment(manager, payout_amount, ctx);

    order_events::emit_settled_order_redeemed(
        market.id(),
        manager,
        order,
        position_root_id,
        settlement,
        payout_amount,
    );
}

/// Settle a mint payment and return the builder fee paid.
///
/// The EWMA penalty is withdrawn alongside the net premium and fees, but rides
/// into expiry cash as surplus: it is not part of the rebate fee basis and
/// earns no builder cut.
fun settle_mint_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    order: &Order,
    net_premium: u64,
    fee_amount: u64,
    penalty_amount: u64,
    ctx: &mut TxContext,
): u64 {
    let quantity = order.quantity();
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(&builder_code_id, fee_amount, quantity);
    let withdraw_amount = net_premium + fee_amount + builder_fee_amount + penalty_amount;

    manager.add_position(market.id(), order.id(), order.id());
    let mut payment = manager.withdraw_with_proof(proof, withdraw_amount, ctx).into_balance();
    let builder_fee_payment = payment.split(builder_fee_amount);
    send_builder_fee(builder_code_id, builder_fee_payment);
    let fee_payment = payment.split(fee_amount);
    market.collect_trade_fee(manager, fee_payment);
    // Remaining balance is the net premium plus the penalty surplus.
    market.cash.receive(payment);

    market.assert_cash_backing();
    builder_fee_amount
}

/// Settle a live redeem and return the builder fee and penalty actually applied.
///
/// The EWMA penalty is withheld from the payout and kept in expiry cash
/// as surplus. Like the trading fee it comes out of `redeem_amount`, so it is
/// capped at the payout left after the fee and builder cut.
fun settle_live_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    proof: &PredictTradeProof,
    redeem_amount: u64,
    fee_amount: u64,
    penalty_amount: u64,
    redeemed_quantity: u64,
    ctx: &mut TxContext,
): (u64, u64) {
    let builder_code_id = manager.builder_code_id();
    let builder_fee_amount = builder_fee_amount(
        &builder_code_id,
        fee_amount,
        redeemed_quantity,
    ).min(
        redeem_amount - fee_amount,
    );
    let penalty_amount = penalty_amount.min(redeem_amount - fee_amount - builder_fee_amount);

    let mut payout = market.cash.pay_authorized(redeem_amount);
    let fee = payout.split(fee_amount);
    let builder_fee = payout.split(builder_fee_amount);
    market.collect_trade_fee(manager, fee);
    send_builder_fee(builder_code_id, builder_fee);
    // Penalty surplus stays in expiry cash rather than flowing to the redeemer.
    market.cash.receive(payout.split(penalty_amount));

    market.assert_cash_backing();
    manager.deposit_with_proof(proof, payout.into_coin(ctx), ctx);
    (builder_fee_amount, penalty_amount)
}

fun settle_settled_redeem_payment(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    payout_amount: u64,
    ctx: &mut TxContext,
) {
    let payout = market.cash.pay_authorized(payout_amount);
    manager.deposit_permissionless(payout.into_coin(ctx), ctx);

    market.assert_cash_backing();
}

fun collect_trade_fee(
    market: &mut ExpiryMarket,
    manager: &mut PredictManager,
    fee: Balance<DUSDC>,
) {
    let fee_amount = market.cash.collect_trade_fee(fee);
    if (fee_amount == 0) return;
    manager.record_trading_fee_paid(market.id(), fee_amount);
}

fun send_builder_fee(builder_code_id: Option<ID>, fee: Balance<DUSDC>) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let builder_code_id = builder_code_id.destroy_some();
    balance::send_funds(fee, builder_code_id.to_address());
}

// === Test-Only Functions ===

#[test_only]
public fun receive_cash_for_testing(market: &mut ExpiryMarket, funds: Coin<DUSDC>) {
    market.cash.receive(funds.into_balance());
}
