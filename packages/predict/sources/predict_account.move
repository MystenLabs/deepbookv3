// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict's per-account state, stored as an app-data slot on a shared `Account`
/// (the `account` package).
///
/// This is Predict's account-local state: open positions, per-expiry trading
/// summaries, DEEP stake, and sticky builder-code attribution. DUSDC/PLP/DEEP
/// custody lives in `Account`. The `PredictApp` witness namespaces this slot, so
/// only Predict writes it.
///
/// Flow-driven state (positions, summaries, stake) is exposed through
/// `public(package)` primitives that mutate Predict app data directly. User-facing
/// builder-code config takes an already-loaded account, so the account package
/// remains the authority boundary.
module deepbook_predict::predict_account;

use account::{account::{Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{builder_code::BuilderCode, builder_code_events};
use std::internal::permit;
use sui::table::{Self, Table};

const EPositionAlreadyExists: u64 = 0;
const EPositionNotFound: u64 = 1;
const EInsufficientPosition: u64 = 2;
const EExpirySummaryHasOpenPositions: u64 = 3;

/// App witness that namespaces Predict's data slot on an `Account`. Only this
/// module can construct it, so only Predict can write its own slot.
public struct PredictApp() has drop;

/// Position key binding an order ID to the expiry market that minted it.
public struct PositionKey has copy, drop, store {
    expiry_market_id: ID,
    order_id: u256,
}

/// Per-position state stored under a `PositionKey`.
public struct Position has store {
    /// Root order ID, carried forward unchanged across partial-close replacements.
    root_id: u256,
    /// On-chain time (`clock.timestamp_ms()`) the position was opened, carried
    /// forward unchanged across partial-close replacements. A live redeem in the
    /// same timestamp is rejected, blocking an atomic mint -> oracle-update ->
    /// redeem in one transaction.
    opened_at_ms: u64,
}

/// Aggregate trading cash flow and open-position count for one expiry market.
public struct ExpiryTradingSummary has store {
    open_position_count: u64,
    trading_fees_paid: u64,
    gross_paid_to_expiry: u64,
    gross_received_from_expiry: u64,
}

/// Resolved trading-loss-rebate inputs for one fully-closed expiry: the fees the
/// account paid into the expiry and its realized gross profit, returned together
/// so the rebate flow reads them by name.
public struct ResolvedExpirySummary has drop {
    fees_paid: u64,
    gross_profit: u64,
}

/// Predict's per-account state, attached to an `Account` under `PredictApp`.
public struct PredictData has store {
    /// Open positions scoped by expiry market.
    positions: Table<PositionKey, Position>,
    /// Per-expiry aggregate trading cash flows and open position count.
    expiry_summaries: Table<ID, ExpiryTradingSummary>,
    /// DEEP staked and active for trading benefits, in raw units. Custody is
    /// pooled in `PoolVault`; this is this account's active share.
    active_stake: u64,
    /// DEEP staked this epoch, not yet active; rolls into `active_stake` on the
    /// first discount-bearing interaction in a later epoch (`roll_active_stake`).
    inactive_stake: u64,
    /// Epoch the active/inactive split was last reconciled in.
    stake_epoch: u64,
    /// Sticky builder-code attribution for future trades, if set.
    builder_code_id: Option<ID>,
}

// === Public Functions ===

/// Return whether this account holds an open position for an order in one expiry market.
public fun has_position(account: &Account, expiry_market_id: ID, order_id: u256): bool {
    if (!account.has_data<PredictApp>()) return false;
    data(account).positions.contains(position_key(expiry_market_id, order_id))
}

/// Return the open position row count for one expiry market.
public fun expiry_position_count(account: &Account, expiry_market_id: ID): u64 {
    if (!account.has_data<PredictApp>()) return 0;
    let d = data(account);
    if (d.expiry_summaries.contains(expiry_market_id)) {
        d.expiry_summaries[expiry_market_id].open_position_count
    } else {
        0
    }
}

/// Return aggregate pool trading fees this account paid for one expiry market.
public fun trading_fees_paid(account: &Account, expiry_market_id: ID): u64 {
    if (!account.has_data<PredictApp>()) return 0;
    let d = data(account);
    if (d.expiry_summaries.contains(expiry_market_id)) {
        d.expiry_summaries[expiry_market_id].trading_fees_paid
    } else {
        0
    }
}

/// Return active staked DEEP (the amount that earns benefits).
public fun active_stake(account: &Account): u64 {
    if (!account.has_data<PredictApp>()) return 0;
    data(account).active_stake
}

/// Return inactive staked DEEP (activates next epoch).
public fun inactive_stake(account: &Account): u64 {
    if (!account.has_data<PredictApp>()) return 0;
    data(account).inactive_stake
}

/// Return the sticky builder-code ID, if set.
public fun builder_code_id(account: &Account): Option<ID> {
    if (!account.has_data<PredictApp>()) return option::none();
    data(account).builder_code_id
}

/// Set sticky builder-code attribution for future trades. Consumes account owner
/// auth and attaches the Predict slot if the account has none.
public fun set_builder_code(
    wrapper: &mut AccountWrapper,
    auth: Auth,
    code: &BuilderCode,
    ctx: &mut TxContext,
) {
    let account = wrapper.load_account_mut(auth);
    let builder_code_id = code.id();
    data_mut(account, ctx).builder_code_id = option::some(builder_code_id);
    builder_code_events::emit_builder_code_set(
        account.account_id(),
        account.owner(),
        option::some(builder_code_id),
    );
}

/// Clear sticky builder-code attribution after consuming account owner auth.
public fun unset_builder_code(wrapper: &mut AccountWrapper, auth: Auth, ctx: &mut TxContext) {
    let account = wrapper.load_account_mut(auth);
    data_mut(account, ctx).builder_code_id = option::none();
    builder_code_events::emit_builder_code_set(
        account.account_id(),
        account.owner(),
        option::none(),
    );
}

// === Public-Package Functions ===

/// Generate Predict app authority through the account registry.
public(package) fun generate_auth_as_app(registry: &AccountRegistry): Auth {
    registry.generate_auth_as_app<PredictApp>(permit<PredictApp>())
}

/// Return the on-chain time (`clock.timestamp_ms()`) a held position was opened.
/// Carried forward unchanged across partial-close replacements.
public(package) fun position_opened_at_ms(
    account: &Account,
    expiry_market_id: ID,
    order_id: u256,
): u64 {
    let d = data(account);
    let key = position_key(expiry_market_id, order_id);
    assert!(d.positions.contains(key), EPositionNotFound);
    d.positions[key].opened_at_ms
}

/// Add an order position keyed to its root order ID. At mint the root equals the
/// order's own ID; a partial-close replacement passes the parent's root forward.
/// `opened_at_ms` is the original open time, also carried forward unchanged.
public(package) fun add_position(
    account: &mut Account,
    expiry_market_id: ID,
    order_id: u256,
    position_root_id: u256,
    opened_at_ms: u64,
    ctx: &mut TxContext,
) {
    let d = data_mut(account, ctx);
    let key = position_key(expiry_market_id, order_id);
    assert!(!d.positions.contains(key), EPositionAlreadyExists);
    d.positions.add(key, Position { root_id: position_root_id, opened_at_ms });
    d.ensure_summary(expiry_market_id);
    let summary = &mut d.expiry_summaries[expiry_market_id];
    summary.open_position_count = summary.open_position_count + 1;
}

/// Remove an order position and return its root order ID for event attribution.
public(package) fun remove_position(
    account: &mut Account,
    expiry_market_id: ID,
    order_id: u256,
    ctx: &mut TxContext,
): u256 {
    let d = data_mut(account, ctx);
    let key = position_key(expiry_market_id, order_id);
    assert!(d.positions.contains(key), EPositionNotFound);
    let Position { root_id, .. } = d.positions.remove(key);
    d.ensure_summary(expiry_market_id);
    let summary = &mut d.expiry_summaries[expiry_market_id];
    assert!(summary.open_position_count > 0, EInsufficientPosition);
    summary.open_position_count = summary.open_position_count - 1;
    root_id
}

/// Record pool trading fees paid by this account for one expiry market.
public(package) fun record_trading_fee_paid(
    account: &mut Account,
    expiry_market_id: ID,
    amount: u64,
    ctx: &mut TxContext,
) {
    if (amount == 0) return;
    let d = data_mut(account, ctx);
    d.ensure_summary(expiry_market_id);
    let summary = &mut d.expiry_summaries[expiry_market_id];
    summary.trading_fees_paid = summary.trading_fees_paid + amount;
}

/// Record DUSDC paid for positions in one expiry, excluding trading and builder fees.
public(package) fun record_gross_paid_to_expiry(
    account: &mut Account,
    expiry_market_id: ID,
    amount: u64,
    ctx: &mut TxContext,
) {
    if (amount == 0) return;
    let d = data_mut(account, ctx);
    d.ensure_summary(expiry_market_id);
    let summary = &mut d.expiry_summaries[expiry_market_id];
    summary.gross_paid_to_expiry = summary.gross_paid_to_expiry + amount;
}

/// Record gross DUSDC payout from one expiry before redeem fees are deducted.
public(package) fun record_gross_received_from_expiry(
    account: &mut Account,
    expiry_market_id: ID,
    amount: u64,
    ctx: &mut TxContext,
) {
    if (amount == 0) return;
    let d = data_mut(account, ctx);
    d.ensure_summary(expiry_market_id);
    let summary = &mut d.expiry_summaries[expiry_market_id];
    summary.gross_received_from_expiry = summary.gross_received_from_expiry + amount;
}

/// Remove and return the resolved trading-loss-rebate inputs once all positions close.
public(package) fun resolve_expiry_summary(
    account: &mut Account,
    expiry_market_id: ID,
): ResolvedExpirySummary {
    if (!account.has_data<PredictApp>()) {
        return ResolvedExpirySummary { fees_paid: 0, gross_profit: 0 }
    };
    let d = account.borrow_data_mut<PredictApp, PredictData>(permit<PredictApp>());
    if (!d.expiry_summaries.contains(expiry_market_id)) {
        return ResolvedExpirySummary { fees_paid: 0, gross_profit: 0 }
    };
    assert!(
        d.expiry_summaries[expiry_market_id].open_position_count == 0,
        EExpirySummaryHasOpenPositions,
    );
    let ExpiryTradingSummary {
        open_position_count: _,
        trading_fees_paid,
        gross_paid_to_expiry,
        gross_received_from_expiry,
    } = d.expiry_summaries.remove(expiry_market_id);
    let gross_profit = gross_received_from_expiry.saturating_sub(gross_paid_to_expiry);
    ResolvedExpirySummary { fees_paid: trading_fees_paid, gross_profit }
}

public(package) fun fees_paid(summary: &ResolvedExpirySummary): u64 {
    summary.fees_paid
}

public(package) fun gross_profit(summary: &ResolvedExpirySummary): u64 {
    summary.gross_profit
}

/// Roll inactive stake into active if needed, then return the active amount for
/// protocol execution paths that apply stake discounts.
public(package) fun roll_active_stake(account: &mut Account, ctx: &mut TxContext): u64 {
    let epoch = ctx.epoch();
    let d = data_mut(account, ctx);
    if (d.stake_epoch != epoch) {
        d.active_stake = d.active_stake + d.inactive_stake;
        d.inactive_stake = 0;
        d.stake_epoch = epoch;
    };
    d.active_stake
}

/// Add freshly staked DEEP as inactive; it activates next epoch.
public(package) fun add_inactive_stake(account: &mut Account, stake: u64, ctx: &mut TxContext) {
    let d = data_mut(account, ctx);
    d.inactive_stake = d.inactive_stake + stake;
}

/// Zero out active and inactive stake and return the combined amount.
public(package) fun remove_all_stake(account: &mut Account, ctx: &mut TxContext): u64 {
    let d = data_mut(account, ctx);
    let total = d.active_stake + d.inactive_stake;
    d.active_stake = 0;
    d.inactive_stake = 0;
    total
}

// === Private Functions ===

fun data(account: &Account): &PredictData {
    account.borrow_data<PredictApp, PredictData>()
}

fun data_mut(account: &mut Account, ctx: &mut TxContext): &mut PredictData {
    if (!account.has_data<PredictApp>()) {
        account.attach(permit<PredictApp>(), new_data(ctx));
    };
    account.borrow_data_mut<PredictApp, PredictData>(permit<PredictApp>())
}

fun new_data(ctx: &mut TxContext): PredictData {
    PredictData {
        positions: table::new(ctx),
        expiry_summaries: table::new(ctx),
        active_stake: 0,
        inactive_stake: 0,
        stake_epoch: ctx.epoch(),
        builder_code_id: option::none(),
    }
}

fun position_key(expiry_market_id: ID, order_id: u256): PositionKey {
    PositionKey { expiry_market_id, order_id }
}

fun ensure_summary(d: &mut PredictData, expiry_market_id: ID) {
    if (!d.expiry_summaries.contains(expiry_market_id)) {
        d
            .expiry_summaries
            .add(
                expiry_market_id,
                ExpiryTradingSummary {
                    open_position_count: 0,
                    trading_fees_paid: 0,
                    gross_paid_to_expiry: 0,
                    gross_received_from_expiry: 0,
                },
            );
    };
}
