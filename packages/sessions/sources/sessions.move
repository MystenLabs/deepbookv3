// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns time-limited trading session grants attached to canonical Accounts.
/// Account owners grant and revoke sessions; an active session can only generate
/// app auth inside the Predict and DeepBook spot wrappers exposed here.
module deepbook_sessions::sessions;

use account::{account::{Self, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook::{order_info::OrderInfo, pool::Pool, registry::Registry};
use deepbook_core_account::deepbook_core_account;
use deepbook_predict::{
    expiry_market::ExpiryMarket,
    pricing::Pricer,
    protocol_config::ProtocolConfig
};
use std::internal::permit;
use sui::{accumulator::AccumulatorRoot, clock::Clock, event, vec_map::{Self, VecMap}};

// === Errors ===

const EInvalidSessionDuration: u64 = 0;
const ESessionNotAuthorized: u64 = 1;
const ESessionLimitExceeded: u64 = 2;

// === Constants ===

macro fun max_session_duration_ms(): u64 { 30 * 24 * 60 * 60 * 1000 }

macro fun max_sessions(): u64 { 20 }

// === Structs ===

/// App witness for Account registry authorization and per-account data namespacing.
public struct SessionsApp has drop {}

/// Session expiration timestamps keyed by transaction signer address.
public struct SessionsData has store {
    sessions: VecMap<address, u64>,
}

/// A session was authorized or reauthorized through `expires_at_ms`.
public struct SessionAuthorized has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}

/// An existing session grant was removed before or after its expiration.
public struct SessionRevoked has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}

// === Public Functions ===

/// Return a known session's expiration timestamp for SDK and devInspect reads.
public fun session_expiration_ms(wrapper: &AccountWrapper, session: address): Option<u64> {
    let account = wrapper.load_account();
    if (!account.has_data<SessionsApp>()) return option::none();
    let data = account.borrow_data<SessionsApp, SessionsData>();
    data.sessions.try_get(&session)
}

/// Authorize `session` from execution time for at most 30 days.
/// Accounts may store at most 20 addresses; reauthorization replaces in place.
public fun authorize_session(
    wrapper: &mut AccountWrapper,
    session: address,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(duration_ms > 0 && duration_ms <= max_session_duration_ms!(), EInvalidSessionDuration);
    let expires_at_ms = clock.timestamp_ms() + duration_ms;
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    let account_id = account.account_id();
    if (!account.has_data<SessionsApp>()) {
        account.attach(permit<SessionsApp>(), SessionsData { sessions: vec_map::empty() });
    };
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    if (data.sessions.contains(&session)) {
        *data.sessions.get_mut(&session) = expires_at_ms;
    } else {
        assert!(data.sessions.length() < max_sessions!(), ESessionLimitExceeded);
        data.sessions.insert(session, expires_at_ms);
    };
    event::emit(SessionAuthorized { account_id, session, expires_at_ms });
}

/// Revoke `session` if it is present. Only the Account owner may call this function.
public fun revoke_session(wrapper: &mut AccountWrapper, session: address, ctx: &mut TxContext) {
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    if (!account.has_data<SessionsApp>()) return;
    let account_id = account.account_id();
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    if (!data.sessions.contains(&session)) return;
    let (_, expires_at_ms) = data.sessions.remove(&session);
    event::emit(SessionRevoked { account_id, session, expires_at_ms });
}

/// Place a DeepBook spot limit order for an Account with an active session.
public fun place_limit_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    deepbook_core_account::place_limit_order(
        pool,
        deepbook_registry,
        wrapper,
        auth,
        client_order_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        pay_with_deep,
        expire_timestamp,
        root,
        clock,
        ctx,
    )
}

/// Place a DeepBook spot market order for an Account with an active session.
public fun place_market_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    deepbook_registry: &Registry,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    client_order_id: u64,
    self_matching_option: u8,
    quantity: u64,
    price_limit: u64,
    is_bid: bool,
    pay_with_deep: bool,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    deepbook_core_account::place_market_order(
        pool,
        deepbook_registry,
        wrapper,
        auth,
        client_order_id,
        self_matching_option,
        quantity,
        price_limit,
        is_bid,
        pay_with_deep,
        root,
        clock,
        ctx,
    )
}

/// Cancel a DeepBook spot order for an Account with an active session.
public fun cancel_live_order<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    order_id: u128,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    deepbook_core_account::cancel_live_order(pool, wrapper, auth, order_id, clock, ctx);
}

/// Cancel multiple DeepBook spot orders for an Account with an active session.
public fun cancel_live_orders<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    deepbook_core_account::cancel_live_orders(pool, wrapper, auth, order_ids, clock, ctx);
}

/// Sweep settled DeepBook spot proceeds into an Account with an active session.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    deepbook_core_account::withdraw_settled_amounts(pool, wrapper, auth, ctx);
}

/// Mint an exact Predict position quantity for an Account with an active session.
public fun mint_exact_quantity(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    market.mint_exact_quantity(
        wrapper,
        auth,
        config,
        pricer,
        lower_tick,
        higher_tick,
        quantity,
        max_cost,
        max_probability,
        root,
        clock,
        ctx,
    )
}

/// Mint a budget-sized Predict position for an Account with an active session.
public fun mint_exact_amount(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    market.mint_exact_amount(
        wrapper,
        auth,
        config,
        pricer,
        lower_tick,
        higher_tick,
        max_premium,
        min_quantity,
        max_cost,
        root,
        clock,
        ctx,
    )
}

/// Redeem a live Predict order for an Account with an active session.
public fun redeem_live(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order_id: u256,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    market.redeem_live(
        wrapper,
        auth,
        config,
        pricer,
        order_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}

/// Redeem a settled Predict order for an Account with an active session.
public fun redeem_settled(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    config: &ProtocolConfig,
    order_id: u256,
    close_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): (u256, Option<u256>) {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    market.redeem_settled(
        wrapper,
        auth,
        config,
        order_id,
        close_quantity,
        root,
        clock,
        ctx,
    )
}

// === Private Functions ===

fun generate_auth_as_session(
    account_registry: &AccountRegistry,
    wrapper: &AccountWrapper,
    clock: &Clock,
    ctx: &TxContext,
): Auth {
    let expiration = session_expiration_ms(wrapper, ctx.sender());
    assert!(expiration.is_some(), ESessionNotAuthorized);
    assert!(clock.timestamp_ms() < *expiration.borrow(), ESessionNotAuthorized);
    account_registry.generate_auth_as_app<SessionsApp>(permit<SessionsApp>())
}
