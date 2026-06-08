// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// PredictManager wraps a BalanceManager for Predict trading.
///
/// Users deposit DUSDC into the PredictManager. DUSDC custody is delegated to
/// BalanceManager, while positions are tracked by order IDs scoped to an
/// ExpiryMarket.
///
/// Authorization mirrors BalanceManager: the manager owner can act directly,
/// or grant `PredictTradeCap`, `PredictDepositCap`, and `PredictWithdrawCap`
/// to other addresses. `PredictTradeProof` is consumed by predict modules to
/// authorize a mint/redeem trade and to route the fee deposit/withdraw
/// through the manager's inner BalanceManager caps. The inner BalanceManager
/// `DepositCap` and `WithdrawCap` are held by PredictManager itself and never
/// exposed — all custody operations route through them so the inner
/// BalanceManager owner check never fires from a cap holder's call.
module deepbook_predict::predict_manager;

use deepbook::{
    balance_manager::{Self, BalanceManager, DepositCap, WithdrawCap, TradeCap},
    registry::Registry as DeepbookRegistry
};
use deepbook_predict::{account_events, builder_code::{Self, BuilderCode}, constants};
use dusdc::dusdc::DUSDC;
use sui::{coin::Coin, derived_object, table::{Self, Table}, vec_set::{Self, VecSet}};

const EInsufficientPosition: u64 = 0;
const ENotOwner: u64 = 1;
const EInvalidProof: u64 = 2;
const EInvalidCap: u64 = 3;
const EMaxCapsReached: u64 = 4;
const ECapNotInList: u64 = 5;
const EExpirySummaryHasOpenPositions: u64 = 6;
const EPositionAlreadyExists: u64 = 7;

/// Cap-count safety ceiling per manager. Mirrors BalanceManager's MAX_TRADE_CAPS.
const MAX_CAPS: u64 = 1000;

/// The key for deriving predict manager. u64 distinguishes managers per
/// address: index 0 is reserved for sender-owned managers (`new`), index 1
/// for self-owned managers (`new_self_owned`). Future indices may extend the
/// scheme if multiple managers per sender are added.
public struct PredictManagerKey(address, u64) has copy, drop, store;

/// Witness used to prove that calls into `balance_manager::new_with_custom_owner_caps_v2`
/// originate from this package. The deepbook `Registry` admin must authorize
/// `PredictApp` once via `authorize_app<PredictApp>` before `new_self_owned`
/// can succeed.
public struct PredictApp has drop {}

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
    /// Inner BalanceManager `DepositCap` used by PredictManager to credit the
    /// underlying balance without going through the BalanceManager owner check.
    deposit_cap: DepositCap,
    /// Inner BalanceManager `WithdrawCap` used by PredictManager to debit the
    /// underlying balance without going through the BalanceManager owner check.
    withdraw_cap: WithdrawCap,
    /// BalanceManager `TradeCap` returned by `new_with_custom_owner_caps_v2`.
    /// PredictManager doesn't trade on deepbook pools, so the cap is never
    /// consumed — we hold it because BalanceManager doesn't expose a public
    /// destroy. `option::none` on sender-owned managers (their constructor
    /// doesn't go through `_v2`).
    bm_trade_cap: Option<TradeCap>,
    /// IDs of PredictManager caps (PredictTradeCap / PredictDepositCap /
    /// PredictWithdrawCap) authorized to act on this manager. Revoking removes
    /// the ID from this set.
    allow_listed: VecSet<ID>,
    builder_code_id: Option<ID>,
    /// Open order positions scoped by expiry market. The value is the position's
    /// root order ID (the original mint's `order_id`), carried forward unchanged
    /// across partial-close replacements so an economic position has one handle.
    positions: Table<PositionKey, u256>,
    /// Per-expiry aggregate trading cash flows and open position count.
    expiry_summaries: Table<ID, ExpiryTradingSummary>,
    /// DEEP staked and active for trading benefits, in raw units. Custody lives
    /// in PoolVault; this mirrors this manager's share.
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
    /// DUSDC paid for positions, excluding trading and builder fees.
    gross_paid_to_expiry: u64,
    /// DUSDC payout before redeem trading and builder fees are deducted.
    gross_received_from_expiry: u64,
}

/// Owners of a `PredictTradeCap` can generate a `PredictTradeProof` to mint/redeem
/// positions on this manager. Risk of equivocation since `PredictTradeCap` is
/// an owned object — high-frequency callers should trade as the manager owner.
public struct PredictTradeCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `PredictDepositCap` is used to deposit funds into a PredictManager by a
/// non-owner.
public struct PredictDepositCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// `PredictWithdrawCap` is used to withdraw funds from a PredictManager by a
/// non-owner.
public struct PredictWithdrawCap has key, store {
    id: UID,
    predict_manager_id: ID,
}

/// Manager owner and `PredictTradeCap` holders can generate a `PredictTradeProof`.
/// Predict modules consume the proof to authorize the trade and to route
/// deposit / withdraw through the manager's inner BalanceManager caps.
public struct PredictTradeProof has drop {
    predict_manager_id: ID,
    trader: address,
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

/// Return the BalanceManager owner for this PredictManager.
public fun owner(self: &PredictManager): address {
    self.balance_manager.owner()
}

/// Return the inner BalanceManager object ID that holds this manager's DUSDC.
public fun balance_manager_id(self: &PredictManager): ID {
    self.balance_manager.id()
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
    account_events::emit_builder_code_set(
        self.id(),
        self.owner(),
        option::some(builder_code_id),
    );
}

/// Clear sticky builder-code attribution for future trades.
public fun unset_builder_code(self: &mut PredictManager, ctx: &TxContext) {
    self.assert_owner(ctx);
    self.builder_code_id = option::none();
    account_events::emit_builder_code_set(self.id(), self.owner(), option::none());
}

/// Mint a `PredictTradeCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_trade_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictTradeCap {
    self.assert_owner(ctx);
    let manager_id = self.id();
    self.mint_trade_cap_internal(manager_id, ctx)
}

/// Mint a `PredictDepositCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_deposit_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictDepositCap {
    self.assert_owner(ctx);
    let manager_id = self.id();
    self.mint_deposit_cap_internal(manager_id, ctx)
}

/// Mint a `PredictWithdrawCap`. Only the manager owner can mint. Unreachable
/// on self-owned managers; all caps for those are minted by `new_self_owned`.
public fun mint_withdraw_cap(self: &mut PredictManager, ctx: &mut TxContext): PredictWithdrawCap {
    self.assert_owner(ctx);
    let manager_id = self.id();
    self.mint_withdraw_cap_internal(manager_id, ctx)
}

/// Revoke a previously minted cap. Only the manager owner can revoke. Works
/// for any of `PredictTradeCap`, `PredictDepositCap`, or `PredictWithdrawCap`
/// since they all live in the same `allow_listed` set.
public fun revoke_cap(self: &mut PredictManager, cap_id: &ID, ctx: &TxContext) {
    self.assert_owner(ctx);
    assert!(self.allow_listed.contains(cap_id), ECapNotInList);
    self.allow_listed.remove(cap_id);
}

/// Generate a `PredictTradeProof` as the manager owner. No equivocation risk.
public fun generate_proof_as_owner(self: &PredictManager, ctx: &TxContext): PredictTradeProof {
    self.assert_owner(ctx);
    PredictTradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Generate a `PredictTradeProof` using a `PredictTradeCap`. Cap is an owned object
/// so the holder risks equivocation when generating proofs in concurrent PTBs.
public fun generate_proof_as_trader(
    self: &PredictManager,
    trade_cap: &PredictTradeCap,
    ctx: &TxContext,
): PredictTradeProof {
    self.validate_trader(trade_cap);
    PredictTradeProof { predict_manager_id: self.id(), trader: ctx.sender() }
}

/// Abort unless the proof was generated for this manager.
public fun validate_proof(self: &PredictManager, proof: &PredictTradeProof) {
    assert!(self.id() == proof.predict_manager_id, EInvalidProof);
}

/// Deposit DUSDC into the manager. Only the manager owner may call.
public fun deposit(self: &mut PredictManager, coin: Coin<DUSDC>, ctx: &mut TxContext) {
    self.assert_owner(ctx);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC from the manager. Only the manager owner may call.
public fun withdraw(self: &mut PredictManager, amount: u64, ctx: &mut TxContext): Coin<DUSDC> {
    self.assert_owner(ctx);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

/// Deposit DUSDC using a `PredictDepositCap`.
public fun deposit_with_cap(
    self: &mut PredictManager,
    cap: &PredictDepositCap,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_depositor(cap);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC using a `PredictWithdrawCap`.
public fun withdraw_with_cap(
    self: &mut PredictManager,
    cap: &PredictWithdrawCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    self.validate_withdrawer(cap);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

// === Public-Package Functions ===

/// Create a sender-owned PredictManager. The sender is the BalanceManager
/// owner and can act directly on the manager without holding any cap.
public(package) fun new(registry_uid: &mut UID, ctx: &mut TxContext): PredictManager {
    let id = derived_object::claim(
        registry_uid,
        PredictManagerKey(ctx.sender(), constants::sender_owned_manager_slot!()),
    );
    let mut balance_manager = balance_manager::new(ctx);
    let deposit_cap = balance_manager.mint_deposit_cap(ctx);
    let withdraw_cap = balance_manager.mint_withdraw_cap(ctx);

    let manager = PredictManager {
        id,
        balance_manager,
        deposit_cap,
        withdraw_cap,
        bm_trade_cap: option::none(),
        allow_listed: vec_set::empty(),
        builder_code_id: option::none(),
        positions: table::new(ctx),
        expiry_summaries: table::new(ctx),
        active_stake: 0,
        inactive_stake: 0,
        stake_epoch: ctx.epoch(),
    };
    account_events::emit_predict_manager_created(
        manager.id(),
        manager.balance_manager_id(),
        manager.owner(),
    );
    manager
}

/// Create a PredictManager that owns itself: the inner BalanceManager's owner
/// is set to the PredictManager's own ID-as-address, which no transaction
/// sender can ever match. The owner-direct deposit/withdraw and `mint_*_cap`
/// paths are permanently unreachable, so the caps minted here are the only
/// authority that will ever exist on this manager.
///
/// Intended for contracts (vaults, custodial products) that don't want a
/// deployer-key trust anchor. The caller receives one cap of each kind and
/// is expected to install them inside its own contract object.
///
/// Requires `PredictApp` to be authorized on the deepbook `Registry` via
/// `deepbook::registry::authorize_app<PredictApp>` — a one-time admin tx on
/// the deepbook side.
public(package) fun new_self_owned(
    registry_uid: &mut UID,
    deepbook_registry: &DeepbookRegistry,
    ctx: &mut TxContext,
): (PredictManager, PredictDepositCap, PredictWithdrawCap, PredictTradeCap) {
    let id = derived_object::claim(
        registry_uid,
        PredictManagerKey(ctx.sender(), constants::self_owned_manager_slot!()),
    );
    let owner_address = id.to_inner().to_address();

    let (
        balance_manager,
        bm_deposit_cap,
        bm_withdraw_cap,
        bm_trade_cap,
    ) = balance_manager::new_with_custom_owner_caps_v2(
        PredictApp {},
        deepbook_registry,
        owner_address,
        ctx,
    );

    let mut manager = PredictManager {
        id,
        balance_manager,
        deposit_cap: bm_deposit_cap,
        withdraw_cap: bm_withdraw_cap,
        bm_trade_cap: option::some(bm_trade_cap),
        allow_listed: vec_set::empty(),
        builder_code_id: option::none(),
        positions: table::new(ctx),
        expiry_summaries: table::new(ctx),
        active_stake: 0,
        inactive_stake: 0,
        stake_epoch: ctx.epoch(),
    };
    let manager_id = manager.id();
    account_events::emit_predict_manager_created(
        manager_id,
        manager.balance_manager_id(),
        manager.owner(),
    );

    let predict_trade_cap = manager.mint_trade_cap_internal(manager_id, ctx);
    let predict_deposit_cap = manager.mint_deposit_cap_internal(manager_id, ctx);
    let predict_withdraw_cap = manager.mint_withdraw_cap_internal(manager_id, ctx);

    (manager, predict_deposit_cap, predict_withdraw_cap, predict_trade_cap)
}

/// Abort unless the transaction sender owns this manager.
public(package) fun assert_owner(self: &PredictManager, ctx: &TxContext) {
    assert!(ctx.sender() == self.balance_manager.owner(), ENotOwner);
}

/// Deposit protocol payouts without requiring any authorization. Used for
/// settled redemptions, which any caller may trigger.
public(package) fun deposit_permissionless(
    self: &mut PredictManager,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Deposit DUSDC into the manager using a validated `PredictTradeProof`.
public(package) fun deposit_with_proof(
    self: &mut PredictManager,
    proof: &PredictTradeProof,
    coin: Coin<DUSDC>,
    ctx: &TxContext,
) {
    self.validate_proof(proof);
    self.balance_manager.deposit_with_cap(&self.deposit_cap, coin, ctx);
}

/// Withdraw DUSDC from the manager using a validated `PredictTradeProof`.
public(package) fun withdraw_with_proof(
    self: &mut PredictManager,
    proof: &PredictTradeProof,
    amount: u64,
    ctx: &mut TxContext,
): Coin<DUSDC> {
    self.validate_proof(proof);
    self.balance_manager.withdraw_with_cap(&self.withdraw_cap, amount, ctx)
}

/// Add an order position keyed to its root order ID. At mint the root equals the
/// order's own ID; a partial-close replacement passes the parent's root forward.
public(package) fun add_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
    position_root_id: u256,
) {
    let key = position_key(expiry_market_id, order_id);
    assert!(!self.positions.contains(key), EPositionAlreadyExists);
    self.positions.add(key, position_root_id);
    let summary = self.summary_mut(expiry_market_id);
    summary.open_position_count = summary.open_position_count + 1;
}

/// Remove an order position and return its root order ID for event attribution.
public(package) fun remove_position(
    self: &mut PredictManager,
    expiry_market_id: ID,
    order_id: u256,
): u256 {
    let key = position_key(expiry_market_id, order_id);
    assert!(self.positions.contains(key), EInsufficientPosition);
    let position_root_id = self.positions.remove(key);
    let summary = self.summary_mut(expiry_market_id);
    assert!(summary.open_position_count > 0, EInsufficientPosition);
    summary.open_position_count = summary.open_position_count - 1;
    position_root_id
}

/// Record DUSDC paid for positions in an expiry market, excluding fees.
public(package) fun record_gross_paid_to_expiry(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    let summary = self.summary_mut(expiry_market_id);
    summary.gross_paid_to_expiry = summary.gross_paid_to_expiry + amount;
}

/// Record gross DUSDC payout from an expiry market before fee deductions.
public(package) fun record_gross_received_from_expiry(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    let summary = self.summary_mut(expiry_market_id);
    summary.gross_received_from_expiry = summary.gross_received_from_expiry + amount;
}

/// Record pool trading fees paid by this manager for one expiry market.
public(package) fun record_trading_fee_paid(
    self: &mut PredictManager,
    expiry_market_id: ID,
    amount: u64,
) {
    if (amount == 0) return;
    let summary = self.summary_mut(expiry_market_id);
    summary.trading_fees_paid = summary.trading_fees_paid + amount;
}

/// Remove and return aggregate fees and gross profit once all expiry positions are closed.
public(package) fun resolve_expiry_summary(
    self: &mut PredictManager,
    expiry_market_id: ID,
): (u64, u64) {
    if (!self.expiry_summaries.contains(expiry_market_id)) return (0, 0);

    assert!(
        self.expiry_summaries[expiry_market_id].open_position_count == 0,
        EExpirySummaryHasOpenPositions,
    );
    let ExpiryTradingSummary {
        open_position_count: _,
        trading_fees_paid,
        gross_paid_to_expiry,
        gross_received_from_expiry,
    } = self.expiry_summaries.remove(expiry_market_id);
    let gross_profit = if (gross_received_from_expiry > gross_paid_to_expiry) {
        gross_received_from_expiry - gross_paid_to_expiry
    } else {
        0
    };
    (trading_fees_paid, gross_profit)
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

// === Private Functions ===

fun summary_mut(self: &mut PredictManager, expiry_market_id: ID): &mut ExpiryTradingSummary {
    if (!self.expiry_summaries.contains(expiry_market_id)) {
        let summary = ExpiryTradingSummary {
            open_position_count: 0,
            trading_fees_paid: 0,
            gross_paid_to_expiry: 0,
            gross_received_from_expiry: 0,
        };
        self.expiry_summaries.add(expiry_market_id, summary);
    };
    &mut self.expiry_summaries[expiry_market_id]
}

fun position_key(expiry_market_id: ID, order_id: u256): PositionKey {
    PositionKey { expiry_market_id, order_id }
}

fun assert_caps_capacity(self: &PredictManager) {
    assert!(self.allow_listed.length() < MAX_CAPS, EMaxCapsReached);
}

fun validate_trader(self: &PredictManager, trade_cap: &PredictTradeCap) {
    assert!(self.allow_listed.contains(object::borrow_id(trade_cap)), EInvalidCap);
}

fun validate_depositor(self: &PredictManager, deposit_cap: &PredictDepositCap) {
    assert!(self.allow_listed.contains(object::borrow_id(deposit_cap)), EInvalidCap);
}

fun validate_withdrawer(self: &PredictManager, withdraw_cap: &PredictWithdrawCap) {
    assert!(self.allow_listed.contains(object::borrow_id(withdraw_cap)), EInvalidCap);
}

/// Allow-list and emit for a new `PredictTradeCap`. Shared by the owner-gated
/// `mint_trade_cap` and the `new_self_owned` constructor, so it carries no
/// owner check of its own.
fun mint_trade_cap_internal(
    self: &mut PredictManager,
    manager_id: ID,
    ctx: &mut TxContext,
): PredictTradeCap {
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    account_events::emit_predict_trade_cap_minted(manager_id, cap_id);
    PredictTradeCap { id, predict_manager_id: manager_id }
}

fun mint_deposit_cap_internal(
    self: &mut PredictManager,
    manager_id: ID,
    ctx: &mut TxContext,
): PredictDepositCap {
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    account_events::emit_predict_deposit_cap_minted(manager_id, cap_id);
    PredictDepositCap { id, predict_manager_id: manager_id }
}

fun mint_withdraw_cap_internal(
    self: &mut PredictManager,
    manager_id: ID,
    ctx: &mut TxContext,
): PredictWithdrawCap {
    self.assert_caps_capacity();
    let id = object::new(ctx);
    let cap_id = id.to_inner();
    self.allow_listed.insert(cap_id);
    account_events::emit_predict_withdraw_cap_minted(manager_id, cap_id);
    PredictWithdrawCap { id, predict_manager_id: manager_id }
}
