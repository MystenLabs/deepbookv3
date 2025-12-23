// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
module deepbook::pool;

use deepbook::{
    account::Account,
    balance_manager::{
        Self,
        BalanceManager,
        TradeProof,
        DeepBookPoolReferral,
        DeepBookReferral,
        TradeCap,
        DepositCap,
        WithdrawCap
    },
    balances,
    big_vector::BigVector,
    book::{Self, Book},
    constants,
    deep_price::{Self, DeepPrice, OrderDeepPrice, emit_deep_price_added},
    ewma::{init_ewma_state, EWMAState},
    math,
    order::Order,
    order_info::{Self, OrderInfo},
    registry::{DeepbookAdminCap, Registry},
    state::{Self, State},
    vault::{Self, Vault, FlashLoan}
};
use std::type_name;
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Self, Coin},
    dynamic_field as df,
    event,
    vec_set::{Self, VecSet},
    versioned::{Self, Versioned}
};
use token::deep::{DEEP, ProtectedTreasury};

use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
use fun df::borrow_mut as UID.borrow_mut;
use fun df::exists_ as UID.exists_;

// === Errors ===
const EInvalidFee: u64 = 1;
const ESameBaseAndQuote: u64 = 2;
const EInvalidTickSize: u64 = 3;
const EInvalidLotSize: u64 = 4;
const EInvalidMinSize: u64 = 5;
const EInvalidQuantityIn: u64 = 6;
const EIneligibleReferencePool: u64 = 7;
const EInvalidOrderBalanceManager: u64 = 9;
const EIneligibleTargetPool: u64 = 10;
const EPackageVersionDisabled: u64 = 11;
const EMinimumQuantityOutNotMet: u64 = 12;
const EInvalidStake: u64 = 13;
const EPoolNotRegistered: u64 = 14;
const EPoolCannotBeBothWhitelistedAndStable: u64 = 15;
const EInvalidReferralMultiplier: u64 = 16;
const EInvalidEWMAAlpha: u64 = 17;
const EInvalidZScoreThreshold: u64 = 18;
const EInvalidAdditionalTakerFee: u64 = 19;
const EWrongPoolReferral: u64 = 20;

// === Structs ===
public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
    id: UID,
    inner: Versioned,
}

public struct PoolInner<phantom BaseAsset, phantom QuoteAsset> has store {
    allowed_versions: VecSet<u64>,
    pool_id: ID,
    book: Book,
    state: State,
    vault: Vault<BaseAsset, QuoteAsset>,
    deep_price: DeepPrice,
    registered_pool: bool,
}

public struct PoolCreated<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    taker_fee: u64,
    maker_fee: u64,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    whitelisted_pool: bool,
    treasury_address: address,
}

public struct BookParamsUpdated<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    timestamp: u64,
}

public struct DeepBurned<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    deep_burned: u64,
}

public struct ReferralRewards<phantom BaseAsset, phantom QuoteAsset> has store {
    multiplier: u64,
    base: Balance<BaseAsset>,
    quote: Balance<QuoteAsset>,
    deep: Balance<DEEP>,
}

#[deprecated, allow(unused_field)]
public struct ReferralClaimedEvent<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    referral_id: ID,
    owner: address,
    base_amount: u64,
    quote_amount: u64,
    deep_amount: u64,
}

public struct ReferralClaimed has copy, drop, store {
    pool_id: ID,
    referral_id: ID,
    owner: address,
    base_amount: u64,
    quote_amount: u64,
    deep_amount: u64,
}

public struct ReferralFeeEvent has copy, drop, store {
    pool_id: ID,
    referral_id: ID,
    base_fee: u64,
    quote_fee: u64,
    deep_fee: u64,
}

// === Public-Mutative Functions * POOL CREATION * ===
/// Create a new pool. The pool is registered in the registry.
/// Checks are performed to ensure the tick size, lot size,
/// and min size are valid.
/// The creation fee is transferred to the treasury address.
/// Returns the id of the pool created
public fun create_permissionless_pool<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID {
    assert!(creation_fee.value() == constants::pool_creation_fee(), EInvalidFee);
    let base_type = type_name::with_defining_ids<BaseAsset>();
    let quote_type = type_name::with_defining_ids<QuoteAsset>();
    let whitelisted_pool = false;
    let stable_pool = registry.is_stablecoin(base_type) && registry.is_stablecoin(quote_type);

    create_pool<BaseAsset, QuoteAsset>(
        registry,
        tick_size,
        lot_size,
        min_size,
        creation_fee,
        whitelisted_pool,
        stable_pool,
        ctx,
    )
}

// === Public-Mutative Functions * EXCHANGE * ===
/// Place a limit order. Quantity is in base asset terms.
/// For current version pay_with_deep must be true, so the fee will be paid with
/// DEEP tokens.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
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
    self.place_order_int(
        balance_manager,
        trade_proof,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        clock,
        false,
        ctx,
    )
}

/// Place a market order. Quantity is in base asset terms. Calls
/// place_limit_order with
/// a price of MAX_PRICE for bids and MIN_PRICE for asks. Any quantity not
/// filled is cancelled.
public fun place_market_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
    ctx: &TxContext,
): OrderInfo {
    self.place_order_int(
        balance_manager,
        trade_proof,
        client_order_id,
        constants::immediate_or_cancel(),
        self_matching_option,
        if (is_bid) constants::max_price() else constants::min_price(),
        quantity,
        is_bid,
        pay_with_deep,
        clock.timestamp_ms(),
        clock,
        true,
        ctx,
    )
}

/// Swap exact base quantity without needing a `balance_manager`.
/// DEEP quantity can be overestimated. Returns three `Coin` objects:
/// base, quote, and deep. Some base quantity may be left over, if the
/// input quantity is not divisible by lot size.
public fun swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    deep_in: Coin<DEEP>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let quote_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        deep_in,
        min_quote_out,
        clock,
        ctx,
    )
}

/// Swap exact base for quote with a `balance_manager`.
/// Assumes fees are paid in DEEP. Assumes balance manager has enough DEEP for fees.
public fun swap_exact_base_for_quote_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: Coin<BaseAsset>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let quote_in = coin::zero(ctx);

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_quote_out,
        clock,
        ctx,
    )
}

/// Swap exact quote quantity without needing a `balance_manager`.
/// DEEP quantity can be overestimated. Returns three `Coin` objects:
/// base, quote, and deep. Some quote quantity may be left over if the
/// input quantity is not divisible by lot size.
public fun swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    deep_in: Coin<DEEP>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let base_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        deep_in,
        min_base_out,
        clock,
        ctx,
    )
}

/// Swap exact quote for base with a `balance_manager`.
/// Assumes fees are paid in DEEP. Assumes balance manager has enough DEEP for fees.
public fun swap_exact_quote_for_base_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    quote_in: Coin<QuoteAsset>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let base_in = coin::zero(ctx);

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_base_out,
        clock,
        ctx,
    )
}

/// Swap exact quantity without needing a balance_manager.
public fun swap_exact_quantity<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    quote_in: Coin<QuoteAsset>,
    deep_in: Coin<DEEP>,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let mut base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    let taker_fee = self.load_inner().state.governance().trade_params().taker_fee();
    let input_fee_rate = math::mul(
        taker_fee,
        constants::fee_penalty_multiplier(),
    );
    assert!((base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let pay_with_deep = deep_in.value() > 0;
    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (base_quantity, _, _) = if (pay_with_deep) {
            self.get_quantity_out(0, quote_quantity, clock)
        } else {
            self.get_quantity_out_input_fee(0, quote_quantity, clock)
        }
    } else {
        if (!pay_with_deep) {
            base_quantity =
                math::div(
                    base_quantity,
                    constants::float_scaling() + input_fee_rate,
                );
        }
    };
    base_quantity = base_quantity - base_quantity % self.load_inner().book.lot_size();
    if (base_quantity < self.load_inner().book.min_size()) {
        return (base_in, quote_in, deep_in)
    };

    let mut temp_balance_manager = balance_manager::new(ctx);
    let trade_proof = temp_balance_manager.generate_proof_as_owner(ctx);
    temp_balance_manager.deposit(base_in, ctx);
    temp_balance_manager.deposit(quote_in, ctx);
    temp_balance_manager.deposit(deep_in, ctx);

    self.place_market_order(
        &mut temp_balance_manager,
        &trade_proof,
        0,
        constants::self_matching_allowed(),
        base_quantity,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    let base_out = temp_balance_manager.withdraw_all<BaseAsset>(ctx);
    let quote_out = temp_balance_manager.withdraw_all<QuoteAsset>(ctx);
    let deep_out = temp_balance_manager.withdraw_all<DEEP>(ctx);

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    temp_balance_manager.delete();

    (base_out, quote_out, deep_out)
}

/// Swap exact quantity with a `balance_manager`.
/// Assumes fees are paid in DEEP. Assumes balance manager has enough DEEP for fees.
public fun swap_exact_quantity_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: Coin<BaseAsset>,
    quote_in: Coin<QuoteAsset>,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let mut adjusted_base_quantity = base_in.value();
    let base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    assert!((adjusted_base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (adjusted_base_quantity, _, _) = self.get_quantity_out(0, quote_quantity, clock)
    } else {
        adjusted_base_quantity =
            adjusted_base_quantity - adjusted_base_quantity % self.load_inner().book.lot_size();
    };
    if (adjusted_base_quantity < self.load_inner().book.min_size()) {
        return (base_in, quote_in)
    };

    balance_manager.deposit_with_cap(deposit_cap, base_in, ctx);
    balance_manager.deposit_with_cap(deposit_cap, quote_in, ctx);
    let trade_proof = balance_manager.generate_proof_as_trader(trade_cap, ctx);
    let order_info = self.place_market_order(
        balance_manager,
        &trade_proof,
        0,
        constants::self_matching_allowed(),
        adjusted_base_quantity,
        is_bid,
        true,
        clock,
        ctx,
    );

    let (base_out_quantity, quote_out_quantity) = if (is_bid) {
        let quote_left = quote_quantity - order_info.cumulative_quote_quantity();
        (order_info.executed_quantity(), quote_left)
    } else {
        let base_left = base_quantity - order_info.executed_quantity();
        (base_left, order_info.cumulative_quote_quantity())
    };

    let base_out = if (base_out_quantity > 0) {
        balance_manager.withdraw_with_cap(withdraw_cap, base_out_quantity, ctx)
    } else {
        coin::zero(ctx)
    };
    let quote_out = if (quote_out_quantity > 0) {
        balance_manager.withdraw_with_cap(withdraw_cap, quote_out_quantity, ctx)
    } else {
        coin::zero(ctx)
    };

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    (base_out, quote_out)
}

/// Modifies an order given order_id and new_quantity.
/// New quantity must be less than the original quantity and more
/// than the filled quantity. Order must not have already expired.
public fun modify_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    new_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let previous_quantity = self.get_order(order_id).quantity();

    let self = self.load_inner_mut();
    let (cancel_quantity, order) = self
        .book
        .modify_order(order_id, new_quantity, clock.timestamp_ms());
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_modify(
            balance_manager.id(),
            cancel_quantity,
            order,
            self.pool_id,
            ctx,
        );
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);

    order.emit_order_modified(
        self.pool_id,
        previous_quantity,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

/// Cancel an order. The order must be owned by the balance_manager.
/// The order is removed from the book and the balance_manager's open orders.
/// The balance_manager's balance is updated with the order's remaining
/// quantity.
/// Order canceled event is emitted.
public fun cancel_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u128,
    clock: &Clock,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    let mut order = self.book.cancel_order(order_id);
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_cancel(&mut order, balance_manager.id(), self.pool_id, ctx);
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);

    order.emit_order_canceled(
        self.pool_id,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

/// Cancel multiple orders within a vector. The orders must be owned by the
/// balance_manager.
/// The orders are removed from the book and the balance_manager's open orders.
/// Order canceled events are emitted.
/// If any order fails to cancel, no orders will be cancelled.
public fun cancel_orders<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        self.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
        i = i + 1;
    }
}

/// Cancel all open orders placed by the balance manager in the pool.
public fun cancel_all_orders<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &TxContext,
) {
    let inner = self.load_inner_mut();
    let mut open_orders = vector[];
    if (inner.state.account_exists(balance_manager.id())) {
        open_orders = inner.state.account(balance_manager.id()).open_orders().into_keys();
    };

    let mut i = 0;
    let num_orders = open_orders.length();
    while (i < num_orders) {
        let order_id = open_orders[i];
        self.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
        i = i + 1;
    }
}

/// Withdraw settled amounts to the `balance_manager`.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Withdraw settled amounts permissionlessly to the `balance_manager`.
public fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager_permissionless(settled, owed, balance_manager);
}

// === Public-Mutative Functions * GOVERNANCE * ===
/// Stake DEEP tokens to the pool. The balance_manager must have enough DEEP
/// tokens.
/// The balance_manager's data is updated with the staked amount.
public fun stake<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    amount: u64,
    ctx: &TxContext,
) {
    assert!(amount > 0, EInvalidStake);
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.process_stake(self.pool_id, balance_manager.id(), amount, ctx);
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Unstake DEEP tokens from the pool. The balance_manager must have enough
/// staked DEEP tokens.
/// The balance_manager's data is updated with the unstaked amount.
/// Balance is transferred to the balance_manager immediately.
public fun unstake<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.process_unstake(self.pool_id, balance_manager.id(), ctx);
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

/// Submit a proposal to change the taker fee, maker fee, and stake required.
/// The balance_manager must have enough staked DEEP tokens to participate.
/// Each balance_manager can only submit one proposal per epoch.
/// If the maximum proposal is reached, the proposal with the lowest vote is
/// removed.
/// If the balance_manager has less voting power than the lowest voted proposal,
/// the proposal is not added.
public fun submit_proposal<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    taker_fee: u64,
    maker_fee: u64,
    stake_required: u64,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    balance_manager.validate_proof(trade_proof);
    self
        .state
        .process_proposal(
            self.pool_id,
            balance_manager.id(),
            taker_fee,
            maker_fee,
            stake_required,
            ctx,
        );
}

/// Vote on a proposal. The balance_manager must have enough staked DEEP tokens
/// to participate.
/// Full voting power of the balance_manager is used.
/// Voting for a new proposal will remove the vote from the previous proposal.
public fun vote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    proposal_id: ID,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    balance_manager.validate_proof(trade_proof);
    self.state.process_vote(self.pool_id, balance_manager.id(), proposal_id, ctx);
}

/// Claim the rewards for the balance_manager. The balance_manager must have
/// rewards to claim.
/// The balance_manager's data is updated with the claimed rewards.
public fun claim_rebates<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self
        .state
        .process_claim_rebates<BaseAsset, QuoteAsset>(
            self.pool_id,
            balance_manager,
            ctx,
        );
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
}

// === Public-Mutative Functions * FLASHLOAN * ===
/// Borrow base assets from the Pool. A hot potato is returned,
/// forcing the borrower to return the assets within the same transaction.
public fun borrow_flashloan_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_amount: u64,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, FlashLoan) {
    let self = self.load_inner_mut();
    self.vault.borrow_flashloan_base(self.pool_id, base_amount, ctx)
}

/// Borrow quote assets from the Pool. A hot potato is returned,
/// forcing the borrower to return the assets within the same transaction.
public fun borrow_flashloan_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    quote_amount: u64,
    ctx: &mut TxContext,
): (Coin<QuoteAsset>, FlashLoan) {
    let self = self.load_inner_mut();
    self.vault.borrow_flashloan_quote(self.pool_id, quote_amount, ctx)
}

/// Return the flashloaned base assets to the Pool.
/// FlashLoan object will only be unwrapped if the assets are returned,
/// otherwise the transaction will fail.
public fun return_flashloan_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    coin: Coin<BaseAsset>,
    flash_loan: FlashLoan,
) {
    let self = self.load_inner_mut();
    self.vault.return_flashloan_base(self.pool_id, coin, flash_loan);
}

/// Return the flashloaned quote assets to the Pool.
/// FlashLoan object will only be unwrapped if the assets are returned,
/// otherwise the transaction will fail.
public fun return_flashloan_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    coin: Coin<QuoteAsset>,
    flash_loan: FlashLoan,
) {
    let self = self.load_inner_mut();
    self.vault.return_flashloan_quote(self.pool_id, coin, flash_loan);
}

// === Public-Mutative Functions * OPERATIONAL * ===

/// Adds a price point along with a timestamp to the deep price.
/// Allows for the calculation of deep price per base asset.
public fun add_deep_price_point<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
    target_pool: &mut Pool<BaseAsset, QuoteAsset>,
    reference_pool: &Pool<ReferenceBaseAsset, ReferenceQuoteAsset>,
    clock: &Clock,
) {
    assert!(
        reference_pool.whitelisted() && reference_pool.registered_pool(),
        EIneligibleReferencePool,
    );
    let reference_pool_price = reference_pool.mid_price(clock);

    let target_pool = target_pool.load_inner_mut();
    let reference_base_type = type_name::with_defining_ids<ReferenceBaseAsset>();
    let reference_quote_type = type_name::with_defining_ids<ReferenceQuoteAsset>();
    let target_base_type = type_name::with_defining_ids<BaseAsset>();
    let target_quote_type = type_name::with_defining_ids<QuoteAsset>();
    let deep_type = type_name::with_defining_ids<DEEP>();
    let timestamp = clock.timestamp_ms();

    assert!(
        reference_base_type == deep_type || reference_quote_type == deep_type,
        EIneligibleTargetPool,
    );

    let reference_deep_is_base = reference_base_type == deep_type;
    let reference_other_type = if (reference_deep_is_base) {
        reference_quote_type
    } else {
        reference_base_type
    };
    let reference_other_is_target_base = reference_other_type == target_base_type;
    let reference_other_is_target_quote = reference_other_type == target_quote_type;
    assert!(
        reference_other_is_target_base || reference_other_is_target_quote,
        EIneligibleTargetPool,
    );

    // For DEEP/USDC pool, reference_deep_is_base is true, DEEP per USDC is
    // reference_pool_price
    // For USDC/DEEP pool, reference_deep_is_base is false, USDC per DEEP is
    // reference_pool_price
    let deep_per_reference_other_price = if (reference_deep_is_base) {
        math::div(1_000_000_000, reference_pool_price)
    } else {
        reference_pool_price
    };

    // For USDC/SUI pool, reference_other_is_target_base is true, add price
    // point to deep per base
    // For SUI/USDC pool, reference_other_is_target_base is false, add price
    // point to deep per quote
    target_pool
        .deep_price
        .add_price_point(
            deep_per_reference_other_price,
            timestamp,
            reference_other_is_target_base,
        );
    emit_deep_price_added(
        deep_per_reference_other_price,
        timestamp,
        reference_other_is_target_base,
        reference_pool.load_inner().pool_id,
        target_pool.pool_id,
    );
}

/// Burns DEEP tokens from the pool. Amount to burn is within history
public fun burn_deep<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    treasury_cap: &mut ProtectedTreasury,
    ctx: &mut TxContext,
): u64 {
    let self = self.load_inner_mut();
    let balance_to_burn = self.state.history_mut().reset_balance_to_burn();
    let deep_to_burn = self.vault.withdraw_deep_to_burn(balance_to_burn).into_coin(ctx);
    let amount_burned = deep_to_burn.value();
    token::deep::burn(treasury_cap, deep_to_burn);

    event::emit(DeepBurned<BaseAsset, QuoteAsset> {
        pool_id: self.pool_id,
        deep_burned: amount_burned,
    });

    amount_burned
}

/// Mint a DeepBookReferral and set the additional bps for the referral.
public fun mint_referral<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    multiplier: u64,
    ctx: &mut TxContext,
): ID {
    assert!(multiplier <= constants::referral_max_multiplier(), EInvalidReferralMultiplier);
    assert!(multiplier % constants::referral_multiplier() == 0, EInvalidReferralMultiplier);
    let _ = self.load_inner();
    let referral_id = balance_manager::mint_referral(self.id(), ctx);
    self
        .id
        .add(
            referral_id,
            ReferralRewards<BaseAsset, QuoteAsset> {
                multiplier,
                base: balance::zero(),
                quote: balance::zero(),
                deep: balance::zero(),
            },
        );

    referral_id
}

#[
    deprecated(
        note = b"This function is deprecated, use `update_deepbook_referral_multiplier` instead.",
    ),
]
public fun update_referral_multiplier<BaseAsset, QuoteAsset>(
    _self: &mut Pool<BaseAsset, QuoteAsset>,
    _referral: &DeepBookReferral,
    _multiplier: u64,
) {
    abort 1337
}

#[deprecated(note = b"This function is deprecated, use `update_pool_referral_multiplier` instead.")]
public fun update_deepbook_referral_multiplier<BaseAsset, QuoteAsset>(
    _self: &mut Pool<BaseAsset, QuoteAsset>,
    _referral: &DeepBookReferral,
    _multiplier: u64,
    _ctx: &TxContext,
) {
    abort
}

/// Update the multiplier for the referral.
public fun update_pool_referral_multiplier<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    referral: &DeepBookPoolReferral,
    multiplier: u64,
    ctx: &TxContext,
) {
    let _ = self.load_inner();
    referral.assert_referral_owner(ctx);
    assert!(multiplier <= constants::referral_max_multiplier(), EInvalidReferralMultiplier);
    assert!(multiplier % constants::referral_multiplier() == 0, EInvalidReferralMultiplier);
    let referral_id = object::id(referral);
    let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
        .id
        .borrow_mut(referral_id);
    referral_rewards.multiplier = multiplier;
}

#[deprecated(note = b"This function is deprecated, use `claim_pool_referral_rewards` instead.")]
public fun claim_referral_rewards<BaseAsset, QuoteAsset>(
    _self: &mut Pool<BaseAsset, QuoteAsset>,
    _referral: &DeepBookReferral,
    _ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    abort
}

/// Claim the rewards for the referral.
public fun claim_pool_referral_rewards<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    referral: &DeepBookPoolReferral,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<DEEP>) {
    let _ = self.load_inner();
    referral.assert_referral_owner(ctx);
    let referral_id = object::id(referral);
    let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
        .id
        .borrow_mut(referral_id);
    let base = referral_rewards.base.withdraw_all().into_coin(ctx);
    let quote = referral_rewards.quote.withdraw_all().into_coin(ctx);
    let deep = referral_rewards.deep.withdraw_all().into_coin(ctx);

    event::emit(ReferralClaimed {
        pool_id: self.id(),
        referral_id,
        owner: ctx.sender(),
        base_amount: base.value(),
        quote_amount: quote.value(),
        deep_amount: deep.value(),
    });

    (base, quote, deep)
}

// === Public-Mutative Functions * ADMIN * ===
/// Create a new pool. The pool is registered in the registry.
/// Checks are performed to ensure the tick size, lot size, and min size are
/// valid.
/// Returns the id of the pool created
public fun create_pool_admin<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    whitelisted_pool: bool,
    stable_pool: bool,
    _cap: &DeepbookAdminCap,
    ctx: &mut TxContext,
): ID {
    let creation_fee = coin::zero(ctx);
    create_pool<BaseAsset, QuoteAsset>(
        registry,
        tick_size,
        lot_size,
        min_size,
        creation_fee,
        whitelisted_pool,
        stable_pool,
        ctx,
    )
}

/// Unregister a pool in case it needs to be redeployed.
public fun unregister_pool_admin<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &mut Registry,
    _cap: &DeepbookAdminCap,
) {
    let self = self.load_inner_mut();
    assert!(self.registered_pool, EPoolNotRegistered);
    self.registered_pool = false;
    registry.unregister_pool<BaseAsset, QuoteAsset>();
}

/// Takes the registry and updates the allowed version within pool
/// Only admin can update the allowed versions
/// This function does not have version restrictions
public fun update_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
    _cap: &DeepbookAdminCap,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Takes the registry and updates the allowed version within pool
/// Permissionless equivalent of `update_allowed_versions`
/// This function does not have version restrictions
public fun update_pool_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Adjust the tick size of the pool. Only admin can adjust the tick size.
public fun adjust_tick_size_admin<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    new_tick_size: u64,
    _cap: &DeepbookAdminCap,
    clock: &Clock,
) {
    let self = self.load_inner_mut();
    assert!(new_tick_size > 0, EInvalidTickSize);
    assert!(math::is_power_of_ten(new_tick_size), EInvalidTickSize);
    self.book.set_tick_size(new_tick_size);

    event::emit(BookParamsUpdated<BaseAsset, QuoteAsset> {
        pool_id: self.pool_id,
        tick_size: self.book.tick_size(),
        lot_size: self.book.lot_size(),
        min_size: self.book.min_size(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Adjust and lot size and min size of the pool. New lot size must be smaller
/// than current lot size. Only admin can adjust the min size and lot size.
public fun adjust_min_lot_size_admin<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    new_lot_size: u64,
    new_min_size: u64,
    _cap: &DeepbookAdminCap,
    clock: &Clock,
) {
    let self = self.load_inner_mut();
    let lot_size = self.book.lot_size();
    assert!(new_lot_size > 0, EInvalidLotSize);
    assert!(lot_size % new_lot_size == 0, EInvalidLotSize);
    assert!(math::is_power_of_ten(new_lot_size), EInvalidLotSize);
    assert!(new_min_size > 0, EInvalidMinSize);
    assert!(new_min_size % new_lot_size == 0, EInvalidMinSize);
    assert!(math::is_power_of_ten(new_min_size), EInvalidMinSize);
    self.book.set_lot_size(new_lot_size);
    self.book.set_min_size(new_min_size);

    event::emit(BookParamsUpdated<BaseAsset, QuoteAsset> {
        pool_id: self.pool_id,
        tick_size: self.book.tick_size(),
        lot_size: self.book.lot_size(),
        min_size: self.book.min_size(),
        timestamp: clock.timestamp_ms(),
    });
}

/// Enable the EWMA state for the pool. This allows the pool to use
/// the EWMA state for volatility calculations and additional taker fees.
public fun enable_ewma_state<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    _cap: &DeepbookAdminCap,
    enable: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let _ = self.load_inner_mut();
    let ewma_state = self.update_ewma_state(clock, ctx);
    if (enable) {
        ewma_state.enable();
    } else {
        ewma_state.disable();
    }
}

/// Set the EWMA parameters for the pool.
/// Only admin can set the parameters.
public fun set_ewma_params<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    _cap: &DeepbookAdminCap,
    alpha: u64,
    z_score_threshold: u64,
    additional_taker_fee: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(alpha <= constants::max_ewma_alpha(), EInvalidEWMAAlpha);
    assert!(z_score_threshold <= constants::max_z_score_threshold(), EInvalidZScoreThreshold);
    assert!(
        additional_taker_fee <= constants::max_additional_taker_fee(),
        EInvalidAdditionalTakerFee,
    );
    let _ = self.load_inner_mut();
    let ewma_state = self.update_ewma_state(clock, ctx);
    ewma_state.set_alpha(alpha);
    ewma_state.set_z_score_threshold(z_score_threshold);
    ewma_state.set_additional_taker_fee(additional_taker_fee);
}

// === Public-View Functions ===
/// Accessor to check if the pool is whitelisted.
public fun whitelisted<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().state.governance().whitelisted()
}

/// Accessor to check if the pool is a stablecoin pool.
public fun stable_pool<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().state.governance().stable()
}

public fun registered_pool<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().registered_pool
}

/// Dry run to determine the quote quantity out for a given base quantity.
/// Uses DEEP token as fee.
public fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(base_quantity, 0, clock)
}

/// Dry run to determine the base quantity out for a given quote quantity.
/// Uses DEEP token as fee.
public fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out(0, quote_quantity, clock)
}

/// Dry run to determine the quote quantity out for a given base quantity.
/// Uses input token as fee.
public fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, 0, clock)
}

/// Dry run to determine the base quantity out for a given quote quantity.
/// Uses input token as fee.
public fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    self.get_quantity_out_input_fee(0, quote_quantity, clock)
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out, deep_quantity_required)
/// Uses DEEP token as fee.
public fun get_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    let whitelist = self.whitelisted();
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let deep_price = self.deep_price.get_order_deep_price(whitelist);
    self
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            taker_fee,
            deep_price,
            self.book.lot_size(),
            true,
            clock.timestamp_ms(),
        )
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out, deep_quantity_required)
/// Uses input token as fee.
public fun get_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64, u64) {
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let deep_price = self.deep_price.empty_deep_price();
    self
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            taker_fee,
            deep_price,
            self.book.lot_size(),
            false,
            clock.timestamp_ms(),
        )
}

/// Dry run to determine the base quantity needed to sell to receive a target quote quantity.
/// Returns (base_quantity_in, actual_quote_quantity_out, deep_quantity_required)
/// Returns (0, 0, 0) if insufficient liquidity or if result would be below min_size.
public fun get_base_quantity_in<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    target_quote_quantity: u64,
    pay_with_deep: bool,
    clock: &Clock,
): (u64, u64, u64) {
    let whitelist = self.whitelisted();
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let deep_price = if (pay_with_deep) {
        self.deep_price.get_order_deep_price(whitelist)
    } else {
        self.deep_price.empty_deep_price()
    };
    self
        .book
        .get_base_quantity_in(
            target_quote_quantity,
            taker_fee,
            deep_price,
            pay_with_deep,
            clock.timestamp_ms(),
        )
}

/// Dry run to determine the quote quantity needed to buy a target base quantity.
/// Returns (actual_base_quantity_out, quote_quantity_in, deep_quantity_required)
/// Returns (0, 0, 0) if insufficient liquidity or if result would be below min_size.
public fun get_quote_quantity_in<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    target_base_quantity: u64,
    pay_with_deep: bool,
    clock: &Clock,
): (u64, u64, u64) {
    let whitelist = self.whitelisted();
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let deep_price = if (pay_with_deep) {
        self.deep_price.get_order_deep_price(whitelist)
    } else {
        self.deep_price.empty_deep_price()
    };
    self
        .book
        .get_quote_quantity_in(
            target_base_quantity,
            taker_fee,
            deep_price,
            pay_with_deep,
            clock.timestamp_ms(),
        )
}

/// Returns the mid price of the pool.
public fun mid_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
): u64 {
    self.load_inner().book.mid_price(clock.timestamp_ms())
}

/// Returns the order_id for all open order for the balance_manager in the pool.
public fun account_open_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): VecSet<u128> {
    let self = self.load_inner();

    if (!self.state.account_exists(balance_manager.id())) {
        return vec_set::empty()
    };

    self.state.account(balance_manager.id()).open_orders()
}

/// Returns the (price_vec, quantity_vec) for the level2 order book.
/// The price_low and price_high are inclusive, all orders within the range are
/// returned.
/// is_bid is true for bids and false for asks.
public fun get_level2_range<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
    clock: &Clock,
): (vector<u64>, vector<u64>) {
    self
        .load_inner()
        .book
        .get_level2_range_and_ticks(
            price_low,
            price_high,
            constants::max_u64(),
            is_bid,
            clock.timestamp_ms(),
        )
}

/// Returns the (price_vec, quantity_vec) for the level2 order book.
/// Ticks are the maximum number of ticks to return starting from best bid and
/// best ask.
/// (bid_price, bid_quantity, ask_price, ask_quantity) are returned as 4
/// vectors.
/// The price vectors are sorted in descending order for bids and ascending
/// order for asks.
public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    ticks: u64,
    clock: &Clock,
): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
    let self = self.load_inner();
    let (bid_price, bid_quantity) = self
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            true,
            clock.timestamp_ms(),
        );
    let (ask_price, ask_quantity) = self
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            false,
            clock.timestamp_ms(),
        );

    (bid_price, bid_quantity, ask_price, ask_quantity)
}

/// Get all balances held in this pool.
public fun vault_balances<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    self.load_inner().vault.balances()
}

/// Get the ID of the pool given the asset types.
public fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(registry: &Registry): ID {
    registry.get_pool_id<BaseAsset, QuoteAsset>()
}

/// Get the Order struct
public fun get_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_id: u128,
): Order {
    self.load_inner().book.get_order(order_id)
}

/// Get multiple orders given a vector of order_ids.
public fun get_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_ids: vector<u128>,
): vector<Order> {
    let mut orders = vector[];
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        orders.push_back(self.get_order(order_id));
        i = i + 1;
    };

    orders
}

/// Return a copy of all orders that are in the book for this account.
public fun get_account_order_details<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): vector<Order> {
    let acct_open_orders = self.account_open_orders(balance_manager).into_keys();

    self.get_orders(acct_open_orders)
}

/// Return the DEEP price for the pool.
public fun get_order_deep_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): OrderDeepPrice {
    let whitelist = self.whitelisted();
    let self = self.load_inner();

    self.deep_price.get_order_deep_price(whitelist)
}

/// Returns the deep required for an order if it's taker or maker given quantity
/// and price
/// Does not account for discounted taker fees
/// Returns (deep_required_taker, deep_required_maker)
public fun get_order_deep_required<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    price: u64,
): (u64, u64) {
    let order_deep_price = self.get_order_deep_price();
    let self = self.load_inner();
    let maker_fee = self.state.governance().trade_params().maker_fee();
    let taker_fee = self.state.governance().trade_params().taker_fee();
    let deep_quantity = order_deep_price
        .fee_quantity(
            base_quantity,
            math::mul(base_quantity, price),
            true,
        )
        .deep();

    (math::mul(taker_fee, deep_quantity), math::mul(maker_fee, deep_quantity))
}

/// Returns the locked balance for the balance_manager in the pool
/// Returns (base_quantity, quote_quantity, deep_quantity)
public fun locked_balance<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let account_orders = self.get_account_order_details(balance_manager);
    let self = self.load_inner();
    if (!self.state.account_exists(balance_manager.id())) {
        return (0, 0, 0)
    };

    let mut base_quantity = 0;
    let mut quote_quantity = 0;
    let mut deep_quantity = 0;

    account_orders.do_ref!(|order| {
        let maker_fee = self.state.history().historic_maker_fee(order.epoch());
        let locked_balance = order.locked_balance(maker_fee);
        base_quantity = base_quantity + locked_balance.base();
        quote_quantity = quote_quantity + locked_balance.quote();
        deep_quantity = deep_quantity + locked_balance.deep();
    });

    let settled_balances = self.state.account(balance_manager.id()).settled_balances();
    base_quantity = base_quantity + settled_balances.base();
    quote_quantity = quote_quantity + settled_balances.quote();
    deep_quantity = deep_quantity + settled_balances.deep();

    (base_quantity, quote_quantity, deep_quantity)
}

/// Check if a limit order can be placed based on balance manager balances.
/// Returns true if the balance manager has sufficient balance (accounting for fees) to place the order, false otherwise.
/// Assumes the limit order is a taker order as a worst case scenario.
public fun can_place_limit_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
): bool {
    let whitelist = self.whitelisted();
    let pool_inner = self.load_inner();

    if (
        !self.check_limit_order_params(
            price,
            quantity,
            expire_timestamp,
            clock,
        )
    ) {
        return false
    };

    let order_deep_price = if (pay_with_deep) {
        pool_inner.deep_price.get_order_deep_price(whitelist)
    } else {
        pool_inner.deep_price.empty_deep_price()
    };

    let quote_quantity = math::mul(quantity, price);

    // Calculate fee quantity using taker fee (worst case for limit orders)
    let taker_fee = pool_inner.state.governance().trade_params().taker_fee();
    let fee_balances = order_deep_price.fee_quantity(quantity, quote_quantity, is_bid);

    // Calculate required balances
    let mut required_base = 0;
    let mut required_quote = 0;
    let mut required_deep = 0;

    if (is_bid) {
        required_quote = quote_quantity;
        if (pay_with_deep) {
            required_deep = math::mul(fee_balances.deep(), taker_fee);
        } else {
            let fee_quote = math::mul(fee_balances.quote(), taker_fee);
            required_quote = required_quote + fee_quote;
        };
    } else {
        required_base = quantity;
        if (pay_with_deep) {
            required_deep = math::mul(fee_balances.deep(), taker_fee);
        } else {
            let fee_base = math::mul(fee_balances.base(), taker_fee);
            required_base = required_base + fee_base;
        };
    };

    // Get current balances from balance manager. Accounts for settled balances.
    let settled_balances = if (!self.account_exists(balance_manager)) {
        balances::empty()
    } else {
        self.account(balance_manager).settled_balances()
    };
    let available_base = balance_manager.balance<BaseAsset>() + settled_balances.base();
    let available_quote = balance_manager.balance<QuoteAsset>() + settled_balances.quote();
    let available_deep = balance_manager.balance<DEEP>() + settled_balances.deep();

    // Check if available balances are sufficient
    (available_base >= required_base) && (available_quote >= required_quote) && (available_deep >= required_deep)
}

/// Check if a market order can be placed based on balance manager balances.
/// Returns true if the balance manager has sufficient balance (accounting for fees) to place the order, false otherwise.
/// Does not account for discounted taker fees
public fun can_place_market_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    clock: &Clock,
): bool {
    // Validate order parameters against pool book params
    if (!self.check_market_order_params(quantity)) {
        return false
    };

    let mut required_base = 0;
    let mut required_deep = 0;

    // Get current balances from balance manager. Accounts for settled balances.
    let settled_balances = if (!self.account_exists(balance_manager)) {
        balances::empty()
    } else {
        self.account(balance_manager).settled_balances()
    };
    let available_base = balance_manager.balance<BaseAsset>() + settled_balances.base();
    let available_quote = balance_manager.balance<QuoteAsset>() + settled_balances.quote();
    let available_deep = balance_manager.balance<DEEP>() + settled_balances.deep();

    if (is_bid) {
        // For bid orders: calculate quote needed to acquire desired base quantity
        // get_quote_quantity_in returns (base_out, quote_needed, deep_required)
        let (base_out, quote_needed, deep_required) = self.get_quote_quantity_in(
            quantity,
            pay_with_deep,
            clock,
        );

        // Not enough liquidity or available quote for the base quantity
        if (base_out < quantity || available_quote < quote_needed) {
            return false
        };

        if (pay_with_deep) {
            required_deep = deep_required;
        };
    } else {
        // For ask orders: if paying fees in input token (base), need quantity + fees
        // get_quantity_out_input_fee accounts for fees, so we need to check if we have enough base
        // including fees that will be deducted
        let (_, _, deep_required) = if (pay_with_deep) {
            self.get_quantity_out(quantity, 0, clock)
        } else {
            self.get_quantity_out_input_fee(quantity, 0, clock)
        };

        // If paying fees in base asset, need quantity + fees
        required_base = if (pay_with_deep) {
            quantity
        } else {
            // Fees are deducted from base, so need more base to account for fees
            let (taker_fee, _, _) = self.pool_trade_params();
            let input_fee_rate = math::mul(taker_fee, constants::fee_penalty_multiplier());
            math::mul(quantity, constants::float_scaling() + input_fee_rate)
        };

        if (pay_with_deep) {
            required_deep = deep_required;
        };
    };

    // Check if available balances are sufficient
    (available_base >= required_base) && (available_deep >= required_deep)
}

/// Check if a market order can be placed based on pool book params.
/// Returns true if the order parameters are valid, false otherwise.
public fun check_market_order_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quantity: u64,
): bool {
    let pool_inner = self.load_inner();
    pool_inner.book.check_market_order_params(quantity)
}

/// Check if a limit order can be placed based on pool book params.
/// Returns true if the order parameters are valid, false otherwise.
public fun check_limit_order_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    price: u64,
    quantity: u64,
    expire_timestamp: u64,
    clock: &Clock,
): bool {
    let pool_inner = self.load_inner();
    pool_inner
        .book
        .check_limit_order_params(price, quantity, expire_timestamp, clock.timestamp_ms())
}

/// Returns the trade params for the pool.
/// Returns (taker_fee, maker_fee, stake_required)
public fun pool_trade_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let trade_params = self.state.governance().trade_params();
    let taker_fee = trade_params.taker_fee();
    let maker_fee = trade_params.maker_fee();
    let stake_required = trade_params.stake_required();

    (taker_fee, maker_fee, stake_required)
}

/// Returns the currently leading trade params for the next epoch for the pool
public fun pool_trade_params_next<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let trade_params = self.state.governance().next_trade_params();
    let taker_fee = trade_params.taker_fee();
    let maker_fee = trade_params.maker_fee();
    let stake_required = trade_params.stake_required();

    (taker_fee, maker_fee, stake_required)
}

/// Returns the tick size, lot size, and min size for the pool.
public fun pool_book_params<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    let self = self.load_inner();
    let tick_size = self.book.tick_size();
    let lot_size = self.book.lot_size();
    let min_size = self.book.min_size();

    (tick_size, lot_size, min_size)
}

public fun account_exists<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): bool {
    let self = self.load_inner();
    self.state.account_exists(balance_manager.id())
}

public fun account<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): Account {
    let self = self.load_inner();

    *self.state.account(balance_manager.id())
}

/// Returns the quorum needed to pass proposal in the current epoch
public fun quorum<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
    self.load_inner().state.governance().quorum()
}

public fun id<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): ID {
    self.load_inner().pool_id
}

#[deprecated(note = b"This function is deprecated, use `get_pool_referral_balances` instead.")]
public fun get_referral_balances<BaseAsset, QuoteAsset>(
    _self: &Pool<BaseAsset, QuoteAsset>,
    _referral: &DeepBookReferral,
): (u64, u64, u64) {
    abort
}

public fun get_pool_referral_balances<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    referral: &DeepBookPoolReferral,
): (u64, u64, u64) {
    let _ = self.load_inner();
    assert!(referral.balance_manager_referral_pool_id() == self.id(), EWrongPoolReferral);
    let referral_rewards: &ReferralRewards<BaseAsset, QuoteAsset> = self
        .id
        .borrow(object::id(referral));
    let base = referral_rewards.base.value();
    let quote = referral_rewards.quote.value();
    let deep = referral_rewards.deep.value();

    (base, quote, deep)
}

public fun pool_referral_multiplier<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    referral: &DeepBookPoolReferral,
): u64 {
    let _ = self.load_inner();
    assert!(referral.balance_manager_referral_pool_id() == self.id(), EWrongPoolReferral);
    let referral_rewards: &ReferralRewards<BaseAsset, QuoteAsset> = self
        .id
        .borrow(object::id(referral));

    referral_rewards.multiplier
}

// === Public-Package Functions ===
public(package) fun create_pool<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    creation_fee: Coin<DEEP>,
    whitelisted_pool: bool,
    stable_pool: bool,
    ctx: &mut TxContext,
): ID {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(math::is_power_of_ten(tick_size), EInvalidTickSize);
    assert!(lot_size >= 1000, EInvalidLotSize);
    assert!(math::is_power_of_ten(lot_size), EInvalidLotSize);
    assert!(min_size > 0, EInvalidMinSize);
    assert!(min_size % lot_size == 0, EInvalidMinSize);
    assert!(math::is_power_of_ten(min_size), EInvalidMinSize);
    assert!(!(whitelisted_pool && stable_pool), EPoolCannotBeBothWhitelistedAndStable);
    assert!(
        type_name::with_defining_ids<BaseAsset>() != type_name::with_defining_ids<QuoteAsset>(),
        ESameBaseAndQuote,
    );

    let pool_id = object::new(ctx);
    let pool_inner = PoolInner<BaseAsset, QuoteAsset> {
        allowed_versions: registry.allowed_versions(),
        pool_id: pool_id.to_inner(),
        book: book::empty(tick_size, lot_size, min_size, ctx),
        state: state::empty(whitelisted_pool, stable_pool, ctx),
        vault: vault::empty(),
        deep_price: deep_price::empty(),
        registered_pool: true,
    };
    let params = pool_inner.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let maker_fee = params.maker_fee();
    let treasury_address = registry.treasury_address();
    let pool = Pool<BaseAsset, QuoteAsset> {
        id: pool_id,
        inner: versioned::create(constants::current_version(), pool_inner, ctx),
    };
    let pool_id = object::id(&pool);
    registry.register_pool<BaseAsset, QuoteAsset>(pool_id);
    event::emit(PoolCreated<BaseAsset, QuoteAsset> {
        pool_id,
        taker_fee,
        maker_fee,
        tick_size,
        lot_size,
        min_size,
        whitelisted_pool,
        treasury_address,
    });

    transfer::public_transfer(creation_fee, treasury_address);
    transfer::share_object(pool);

    pool_id
}

public(package) fun bids<BaseAsset, QuoteAsset>(
    self: &PoolInner<BaseAsset, QuoteAsset>,
): &BigVector<Order> {
    self.book.bids()
}

public(package) fun asks<BaseAsset, QuoteAsset>(
    self: &PoolInner<BaseAsset, QuoteAsset>,
): &BigVector<Order> {
    self.book.asks()
}

public(package) fun load_inner<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): &PoolInner<BaseAsset, QuoteAsset> {
    let inner: &PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

public(package) fun load_inner_mut<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
): &mut PoolInner<BaseAsset, QuoteAsset> {
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

public(package) fun load_ewma_state<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): EWMAState {
    *self.id.borrow(constants::ewma_df_key())
}

// === Private Functions ===
fun place_order_int<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    market_order: bool,
    ctx: &TxContext,
): OrderInfo {
    let whitelist = self.whitelisted();
    self.update_ewma_state(clock, ctx);
    let ewma_state = self.load_ewma_state();
    let order_info = {
        let pool_inner = self.load_inner_mut();

        let order_deep_price = if (pay_with_deep) {
            pool_inner.deep_price.get_order_deep_price(whitelist)
        } else {
            pool_inner.deep_price.empty_deep_price()
        };

        let mut order_info = order_info::new(
            pool_inner.pool_id,
            balance_manager.id(),
            client_order_id,
            ctx.sender(),
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            ctx.epoch(),
            expire_timestamp,
            order_deep_price,
            market_order,
            clock.timestamp_ms(),
        );
        pool_inner.book.create_order(&mut order_info, clock.timestamp_ms());
        let (settled, owed) = pool_inner
            .state
            .process_create(
                &mut order_info,
                &ewma_state,
                pool_inner.pool_id,
                ctx,
            );
        pool_inner.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
        order_info.emit_order_info();
        order_info.emit_orders_filled(clock.timestamp_ms());
        order_info.emit_order_fully_filled_if_filled(clock.timestamp_ms());

        order_info
    };

    self.process_referral_fees<BaseAsset, QuoteAsset>(
        &order_info,
        balance_manager,
        trade_proof,
    );

    order_info
}

fun process_referral_fees<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    order_info: &OrderInfo,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
) {
    let referral_id = balance_manager.get_balance_manager_referral_id(self.id());
    if (referral_id.is_some()) {
        let referral_id = referral_id.destroy_some();
        let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
            .id
            .borrow_mut(referral_id);
        let referral_multiplier = referral_rewards.multiplier;
        let referral_fee = math::mul(order_info.paid_fees(), referral_multiplier);
        if (referral_fee == 0) {
            return
        };
        let mut base_fee = 0;
        let mut quote_fee = 0;
        let mut deep_fee = 0;
        if (order_info.fee_is_deep()) {
            referral_rewards
                .deep
                .join(balance_manager.withdraw_with_proof(trade_proof, referral_fee, false));
            deep_fee = referral_fee;
        } else if (!order_info.is_bid()) {
            referral_rewards
                .base
                .join(balance_manager.withdraw_with_proof(trade_proof, referral_fee, false));
            base_fee = referral_fee;
        } else {
            referral_rewards
                .quote
                .join(balance_manager.withdraw_with_proof(trade_proof, referral_fee, false));
            quote_fee = referral_fee;
        };

        event::emit(ReferralFeeEvent {
            pool_id: self.id(),
            referral_id,
            base_fee,
            quote_fee,
            deep_fee,
        });
    };
}

fun update_ewma_state<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
    ctx: &TxContext,
): &mut EWMAState {
    let pool_id = self.id();
    if (!self.id.exists_(constants::ewma_df_key())) {
        self.id.add(constants::ewma_df_key(), init_ewma_state(ctx));
    };

    let ewma_state: &mut EWMAState = self
        .id
        .borrow_mut(
            constants::ewma_df_key(),
        );
    ewma_state.update(pool_id, clock, ctx);

    ewma_state
}
