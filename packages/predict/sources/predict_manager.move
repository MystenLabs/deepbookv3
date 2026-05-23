// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked as canonical ranges keyed by
/// RangeKey.
module deepbook_predict::predict_manager;

use deepbook::balance_manager::{Self, BalanceManager, DepositCap};
use deepbook_predict::{builder_code::{Self, BuilderCode}, range_key::RangeKey};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, event, table::{Self, Table}, vec_set::VecSet};

const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EZeroQuantity: u64 = 2;
const EPackageVersionDisabled: u64 = 3;

/// The key for deriving predict manager. u64 is optional for
/// supporting multiple managers per address. Defaults to 0 in v1.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// PredictManager stores DUSDC in a BalanceManager and tracks positions.
public struct PredictManager has key {
    id: UID,
    balance_manager: BalanceManager,
    deposit_cap: DepositCap,
    builder_code_id: Option<ID>,
    /// RangeKey -> open position quantity.
    positions: Table<RangeKey, u64>,
    /// Per-expiry aggregate trading cash flows and open position count.
    expiry_summaries: Table<ID, ExpiryTradingSummary>,
    /// Mirror of `ProtocolConfig.allowed_versions`. Owners run the permissionless
    /// sync to track admin changes; package mutations gate on this set.
    allowed_versions: VecSet<u64>,
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
    self.assert_version_allowed();
    self.balance_manager.deposit(coin, ctx);
}

/// Withdraw coins from the PredictManager.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.assert_version_allowed();
    self.balance_manager.withdraw(amount, ctx)
}

/// Return this manager's mirrored set of allowed package versions.
public fun allowed_versions(self: &PredictManager): VecSet<u64> {
    self.allowed_versions
}

/// Refresh this manager's mirrored `allowed_versions`. Permissionless: callers
/// pass `registry.allowed_versions()` as the source of truth.
public fun update_allowed_versions(self: &mut PredictManager, allowed_versions: VecSet<u64>) {
    self.allowed_versions = allowed_versions;
}

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return the position quantity for a range key.
public fun position(self: &PredictManager, key: RangeKey): u64 {
    if (self.positions.contains(key)) {
        self.positions[key]
    } else {
        0
    }
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
    self.assert_version_allowed();
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
    self.assert_version_allowed();
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
public(package) fun new(
    registry_uid: &mut UID,
    allowed_versions: VecSet<u64>,
    ctx: &mut TxContext,
): PredictManager {
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
        allowed_versions,
    }
}

/// Abort if the running package version is not allowed for this manager.
public(package) fun assert_version_allowed(self: &PredictManager) {
    assert!(
        self.allowed_versions.contains(&deepbook_predict::constants::current_version!()),
        EPackageVersionDisabled,
    );
}

/// Deposit protocol payouts without requiring the manager owner as sender.
public(package) fun deposit_permissionless(
    self: &mut PredictManager,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Add position quantity to a range.
public(package) fun increase_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    key: RangeKey,
    quantity: u64,
) {
    assert_nonzero_quantity(quantity);
    if (!self.positions.contains(key)) {
        self.ensure_expiry_summary(expiry_market_id);
        self.positions.add(key, 0);
        let summary = &mut self.expiry_summaries[expiry_market_id];
        summary.open_position_count = summary.open_position_count + 1;
    };
    let position = &mut self.positions[key];
    *position = *position + quantity;
}

/// Remove position quantity from a range and delete empty rows.
public(package) fun decrease_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    key: RangeKey,
    quantity: u64,
) {
    self.assert_can_decrease_position(key, quantity);
    let remove_position;
    {
        let position = &mut self.positions[key];
        *position = *position - quantity;
        remove_position = *position == 0;
    };
    if (remove_position) {
        self.positions.remove(key);
        self.ensure_expiry_summary(expiry_market_id);
        let summary = &mut self.expiry_summaries[expiry_market_id];
        assert!(summary.open_position_count > 0, EInsufficientPosition);
        summary.open_position_count = summary.open_position_count - 1;
    };
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

fun assert_can_decrease_position(self: &PredictManager, key: RangeKey, quantity: u64) {
    assert_nonzero_quantity(quantity);
    assert!(self.positions.contains(key), EInsufficientPosition);
    assert!(self.positions[key] >= quantity, EInsufficientPosition);
}

fun assert_nonzero_quantity(quantity: u64) {
    assert!(quantity > 0, EZeroQuantity);
}
