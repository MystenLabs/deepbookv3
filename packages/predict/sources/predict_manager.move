// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as individual orders keyed by
/// expiry market and order ID. The manager also tracks per-expiry aggregate cash
/// flows for settlement cleanup and rebate accounting.
module deepbook_predict::predict_manager;

use deepbook::{balance_manager::{Self, BalanceManager, DepositCap}, math};
use deepbook_predict::{builder_code::{Self, BuilderCode}, constants, predict_order_id};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, event, table::{Self, Table}};

const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EZeroQuantity: u64 = 2;
const EOpenPositions: u64 = 3;
const EWrongOrderQuantity: u64 = 4;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    builder_code_id: Option<ID>,
    /// Active order quantity mirror keyed by expiry market and order ID.
    positions: Table<PositionKey, u64>,
    /// Active order IDs by expiry market, used for full-expiry cleanup.
    expiry_order_ids: Table<ID, vector<u256>>,
    /// Per-expiry aggregate user trading cash flows.
    expiry_summaries: Table<ID, ExpiryTradingSummary>,
}

/// Key for one order-owned position in one expiry market.
public struct PositionKey has copy, drop, store {
    expiry_market_id: ID,
    order_id: u256,
}

/// Aggregate trading cash flow for one manager in one expiry market.
public struct ExpiryTradingSummary has store {
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

/// Return the PredictManager object ID.
public fun id(self: &PredictManager): ID {
    self.id.to_inner()
}

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return the position quantity for an order ID.
public fun position(self: &PredictManager, expiry_market_id: ID, order_id: u256): u64 {
    let key = position_key(expiry_market_id, order_id);
    if (self.positions.contains(key)) {
        self.positions[key]
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

/// Return DUSDC paid from this manager into one expiry market.
public fun cash_paid_to_expiry(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].cash_paid_to_expiry
    } else {
        0
    }
}

/// Return DUSDC received from one expiry market into this manager.
public fun cash_received_from_expiry(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        self.expiry_summaries[expiry_market_id].cash_received_from_expiry
    } else {
        0
    }
}

/// Return the current aggregate fee rebate estimate for one expiry market.
public fun estimated_expiry_rebate(self: &PredictManager, expiry_market_id: ID): u64 {
    if (self.expiry_summaries.contains(expiry_market_id)) {
        let summary = &self.expiry_summaries[expiry_market_id];
        rebate_amount(
            summary.trading_fees_paid,
            summary.cash_paid_to_expiry,
            summary.cash_received_from_expiry,
        )
    } else {
        0
    }
}

/// Return the DUSDC balance held by this PredictManager.
public fun balance(self: &PredictManager): u64 {
    self.balance_manager.balance<DUSDC>()
}

/// Return the sticky builder-code ID used for future trades, if one is set.
public fun builder_code_id(self: &PredictManager): Option<ID> {
    self.builder_code_id
}

/// Share a newly created PredictManager object.
public fun share(self: PredictManager) {
    transfer::share_object(self);
}

/// Deposit coins into the PredictManager.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &mut TxContext) {
    self.balance_manager.deposit(coin, ctx);
}

/// Withdraw coins from the PredictManager.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.balance_manager.withdraw(amount, ctx)
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

/// Abort unless the transaction sender owns this manager.
public(package) fun assert_owner(self: &PredictManager, ctx: &TxContext) {
    assert!(ctx.sender() == self.balance_manager.owner(), ENotOwner);
}

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
        expiry_order_ids: table::new(ctx),
        expiry_summaries: table::new(ctx),
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

/// Add position quantity for a new order.
public(package) fun increase_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
) {
    let quantity = predict_order_id::quantity(order_id);
    assert_nonzero_quantity(quantity);
    let position_key = position_key(expiry_market_id, order_id);
    self.insert_expiry_order_id(expiry_market_id, order_id);
    self.positions.add(position_key, quantity);
}

public(package) fun active_order_ids(self: &PredictManager, expiry_market_id: ID): vector<u256> {
    let mut order_ids = vector[];
    if (!self.expiry_order_ids.contains(expiry_market_id)) return order_ids;

    let active_order_ids = &self.expiry_order_ids[expiry_market_id];
    let mut i = 0;
    while (i < active_order_ids.length()) {
        order_ids.push_back(active_order_ids[i]);
        i = i + 1;
    };
    order_ids
}

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

/// Consume an expiry summary after all positions are closed.
///
/// Returns the trading fees removed from expiry reserve accounting and the
/// rebate payable to this manager.
public(package) fun claim_expiry_rebate(
    self: &mut PredictManager,
    expiry_market_id: ID,
): (u64, u64) {
    assert!(!self.expiry_order_ids.contains(expiry_market_id), EOpenPositions);
    if (!self.expiry_summaries.contains(expiry_market_id)) return (0, 0);

    let ExpiryTradingSummary {
        trading_fees_paid,
        cash_paid_to_expiry,
        cash_received_from_expiry,
    } = self.expiry_summaries.remove(expiry_market_id);
    (
        trading_fees_paid,
        rebate_amount(trading_fees_paid, cash_paid_to_expiry, cash_received_from_expiry),
    )
}

/// Remove a full order position.
public(package) fun remove_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
) {
    let position_key = position_key(expiry_market_id, order_id);
    self.assert_can_remove_position(position_key);
    let _quantity = self.positions.remove(position_key);
    self.remove_expiry_order_id(expiry_market_id, order_id);
}

fun assert_can_remove_position(self: &PredictManager, key: PositionKey) {
    assert!(self.positions.contains(key), EInsufficientPosition);
    let position_quantity = self.positions[key];
    assert!(
        predict_order_id::quantity(key.order_id) == position_quantity,
        EWrongOrderQuantity,
    );
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}

fun rebate_amount(
    trading_fees_paid: u64,
    cash_paid_to_expiry: u64,
    cash_received_from_expiry: u64,
): u64 {
    let net_loss = if (cash_paid_to_expiry > cash_received_from_expiry) {
        cash_paid_to_expiry - cash_received_from_expiry
    } else {
        0
    };
    net_loss.min(rebate_cap(trading_fees_paid))
}

fun rebate_cap(trading_fees_paid: u64): u64 {
    math::mul(trading_fees_paid, constants::settlement_loss_rebate_rate!())
}

fun ensure_expiry_summary(self: &mut PredictManager, expiry_market_id: ID) {
    if (self.expiry_summaries.contains(expiry_market_id)) return;

    self
        .expiry_summaries
        .add(
            expiry_market_id,
            ExpiryTradingSummary {
                trading_fees_paid: 0,
                cash_paid_to_expiry: 0,
                cash_received_from_expiry: 0,
            },
        );
}

fun insert_expiry_order_id(self: &mut PredictManager, expiry_market_id: ID, order_id: u256) {
    if (!self.expiry_order_ids.contains(expiry_market_id)) {
        self.expiry_order_ids.add(expiry_market_id, vector[]);
    };
    self.expiry_order_ids[expiry_market_id].push_back(order_id);
}

fun remove_expiry_order_id(self: &mut PredictManager, expiry_market_id: ID, order_id: u256) {
    let remove_expiry;
    {
        let order_ids = &mut self.expiry_order_ids[expiry_market_id];
        let mut i = 0;
        while (i < order_ids.length() && order_ids[i] != order_id) {
            i = i + 1;
        };
        assert!(i < order_ids.length(), EInsufficientPosition);
        order_ids.swap_remove(i);
        remove_expiry = order_ids.is_empty();
    };
    if (remove_expiry) {
        let empty_order_ids = self.expiry_order_ids.remove(expiry_market_id);
        empty_order_ids.destroy_empty();
    };
}

fun position_key(expiry_market_id: ID, order_id: u256): PositionKey {
    PositionKey { expiry_market_id, order_id }
}
