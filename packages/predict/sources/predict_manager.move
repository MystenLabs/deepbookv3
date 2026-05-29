// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked by order IDs scoped to an
/// ExpiryMarket.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap};
use deepbook_predict::builder_code::{Self, BuilderCode};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, event, table::{Self, Table}};

const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EExpirySummaryHasOpenPositions: u64 = 4;
const EPositionAlreadyExists: u64 = 5;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// Manager-local position key binding an order ID to the expiry market that minted it.
public struct PositionKey has copy, drop, store {
    /// Expiry market object that minted the order.
    expiry_market_id: ID,
    /// Packed order ID returned by the mint flow.
    order_id: u256,
}

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    builder_code_id: Option<ID>,
    /// Open order positions scoped by expiry market.
    positions: Table<PositionKey, bool>,
    /// Per-expiry aggregate trading cash flows and open position count.
    expiry_summaries: Table<ID, ExpiryTradingSummary>,
    /// DEEP staked and active for trading benefits, in raw units. Custody lives
    /// in the Registry's pooled balance; this mirrors this manager's share.
    active_stake: u64,
    /// DEEP staked this epoch, not yet active. Rolls into `active_stake` on the
    /// first interaction in a later epoch (`update_stake`).
    inactive_stake: u64,
    /// Epoch the active/inactive split was last reconciled in.
    stake_epoch: u64,
}

/// Aggregate trading cash flow for one manager in one expiry market.
public struct ExpiryTradingSummary has store {
    /// Open position row count for this expiry.
    open_position_count: u64,
    /// Trading fees paid to the pool, excluding builder fees.
    trading_fees_paid: u64,
    /// DUSDC paid from this manager into the expiry market.
    cash_paid_to_expiry: u64,
    /// DUSDC received from the expiry market into this manager.
    cash_received_from_expiry: u64,
}

/// Emitted when a manager owner changes sticky builder-code attribution.
public struct BuilderCodeSet has copy, drop, store {
    predict_manager_id: ID,
    owner: address,
    builder_code_id: Option<ID>,
}

// === Public Functions ===

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

/// Return the PredictManager object ID.
public fun id(self: &PredictManager): ID {
    self.id.to_inner()
}

/// Deposit coins into the PredictManager.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &mut TxContext) {
    self.balance_manager.deposit(coin, ctx);
}

/// Withdraw coins from the PredictManager.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.balance_manager.withdraw(amount, ctx)
}

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return whether this manager has an open position for an order in one expiry market.
public fun has_position(self: &PredictManager, expiry_market_id: ID, order_id: u256): bool {
    self.positions.contains(position_key(expiry_market_id, order_id))
}

/// Return open position row count for one expiry market.
public fun expiry_position_count(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].open_position_count
    } else {
        0
    }
}

/// Return aggregate trading fees paid to the pool for one expiry market.
public fun trading_fees_paid(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].trading_fees_paid
    } else {
        0
    }
}

/// Return aggregate DUSDC paid from this manager to one expiry market.
public fun cash_paid_to_expiry(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].cash_paid_to_expiry
    } else {
        0
    }
}

/// Return aggregate DUSDC received from one expiry market into this manager.
public fun cash_received_from_expiry(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].cash_received_from_expiry
    } else {
        0
    }
}

/// Return the DUSDC balance held by this PredictManager.
public fun balance(self: &PredictManager): u64 {
    self.balance_manager.balance<DUSDC>()
}

/// Return the manager's active staked DEEP (the amount that earns benefits).
public fun active_stake(self: &PredictManager): u64 {
    self.active_stake
}

/// Return the manager's inactive staked DEEP (activates next epoch).
public fun inactive_stake(self: &PredictManager): u64 {
    self.inactive_stake
}

/// Return the sticky builder-code ID used for future trades, if one is set.
public fun builder_code_id(self: &PredictManager): Option<ID> {
    self.builder_code_id
}

/// Set sticky builder-code attribution for future trades.
public fun set_builder_code(
    self: &mut PredictManager,
    builder_code: &BuilderCode,
    ctx: &TxContext,
) {
    self.assert_owner(ctx);
    let builder_code_id = builder_code::id(builder_code);
    self.builder_code_id = option::some(builder_code_id);
    event::emit(BuilderCodeSet {
        predict_manager_id: self.id(),
        owner: self.owner(),
        builder_code_id: option::some(builder_code_id),
    });
}

/// Clear sticky builder-code attribution for future trades.
public fun unset_builder_code(self: &mut PredictManager, ctx: &TxContext) {
    self.assert_owner(ctx);
    self.builder_code_id = option::none();
    event::emit(BuilderCodeSet {
        predict_manager_id: self.id(),
        owner: self.owner(),
        builder_code_id: option::none(),
    });
}

// === Public-Package Functions ===

/// Create a derived PredictManager for the sender.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(registry_uid, PredictManagerKey(ctx.sender(), 0));
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);

    PredictManager {
        id,
        balance_manager,
        deposit_cap,
        builder_code_id: option::none(),
        positions: table::new(ctx),
        expiry_summaries: table::new(ctx),
        active_stake: 0,
        inactive_stake: 0,
        stake_epoch: ctx.epoch(),
    }
}

/// Deposit protocol payouts without requiring the manager owner as sender.
public(package) fun deposit_permissionless(
    self: &mut PredictManager,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Add an order position.
public(package) fun add_position(self: &mut PredictManager, expiry_market_id: ID, order_id: u256) {
    let key = position_key(expiry_market_id, order_id);
    assert!(!self.positions.contains(key), EPositionAlreadyExists);
    self.ensure_expiry_summary(expiry_market_id);
    self.positions.add(key, true);
    let summary = &mut self.expiry_summaries[expiry_market_id];
    summary.open_position_count = summary.open_position_count + 1;
}

/// Remove an order position.
public(package) fun remove_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
) {
    let key = position_key(expiry_market_id, order_id);
    assert!(self.positions.contains(key), EInsufficientPosition);
    self.positions.remove(key);
    self.ensure_expiry_summary(expiry_market_id);
    let summary = &mut self.expiry_summaries[expiry_market_id];
    assert!(summary.open_position_count > 0, EInsufficientPosition);
    summary.open_position_count = summary.open_position_count - 1;
}

/// Record DUSDC paid from this manager into an expiry market.
public(package) fun record_cash_paid_to_expiry(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    self.ensure_expiry_summary(expiry_market_id);
    let summary = &mut self.expiry_summaries[expiry_market_id];
    summary.cash_paid_to_expiry = summary.cash_paid_to_expiry + amount;
}

/// Record DUSDC received from an expiry market into this manager.
public(package) fun record_cash_received_from_expiry(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    self.ensure_expiry_summary(expiry_market_id);
    let summary = &mut self.expiry_summaries[expiry_market_id];
    summary.cash_received_from_expiry = summary.cash_received_from_expiry + amount;
}

/// Record pool trading fees paid by this manager for one expiry market.
public(package) fun record_trading_fee_paid(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    self.ensure_expiry_summary(expiry_market_id);
    let summary = &mut self.expiry_summaries[expiry_market_id];
    summary.trading_fees_paid = summary.trading_fees_paid + amount;
}

/// Remove and return the aggregate trading summary once all expiry positions are closed.
public(package) fun resolve_expiry_summary(
    self: &mut PredictManager,
    expiry_market_id: ID,
): (u64, u64, u64) {
    if (!self.expiry_summaries.contains(expiry_market_id)) return (0, 0, 0);

    assert!(
        self.expiry_summaries[expiry_market_id].open_position_count == 0,
        EExpirySummaryHasOpenPositions,
    );
    let ExpiryTradingSummary {
        open_position_count: _,
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
    } = self.expiry_summaries.remove(expiry_market_id);
    (trading_fees_paid, cash_paid_to_expiry, cash_received_from_expiry)
}

/// Roll inactive stake into active stake once a new epoch has begun. Idempotent
/// within an epoch; callers run it before reading `active_stake`.
public(package) fun update_stake(self: &mut PredictManager, ctx: &TxContext) {
    if (self.stake_epoch == ctx.epoch()) return;
    self.active_stake = self.active_stake + self.inactive_stake;
    self.inactive_stake = 0;
    self.stake_epoch = ctx.epoch();
}

/// Add freshly staked DEEP as inactive; it activates next epoch.
public(package) fun add_inactive_stake(self: &mut PredictManager, stake: u64) {
    self.inactive_stake = self.inactive_stake + stake;
}

/// Zero out active and inactive stake and return the combined amount.
public(package) fun remove_all_stake(self: &mut PredictManager): u64 {
    let total = self.active_stake + self.inactive_stake;
    self.active_stake = 0;
    self.inactive_stake = 0;
    total
}

/// Abort unless the transaction sender owns this manager.
public(package) fun assert_owner(self: &PredictManager, ctx: &TxContext) {
    assert!(ctx.sender() == self.balance_manager.owner(), ENotOwner);
}

fun ensure_expiry_summary(self: &mut PredictManager, expiry_market_id: ID) {
    if (!self.expiry_summaries.contains(expiry_market_id)) {
        let summary = ExpiryTradingSummary {
            open_position_count: 0,
            trading_fees_paid: 0,
            cash_paid_to_expiry: 0,
            cash_received_from_expiry: 0,
        };
        self.expiry_summaries.add(expiry_market_id, summary);
    }
}

fun position_key(expiry_market_id: ID, order_id: u256): PositionKey {
    PositionKey { expiry_market_id, order_id }
}
