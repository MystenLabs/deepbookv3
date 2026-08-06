// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns time-limited Predict session grants attached to canonical Accounts.
/// Account owners grant and revoke sessions; an active session can only generate
/// app auth inside the four Predict wrappers exposed here.
module deepbook_sessions::sessions;

use account::{account::{Self, Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook_predict::{
    expiry_market::{Self as expiry_market, ExpiryMarket},
    pricing::Pricer,
    protocol_config::ProtocolConfig
};
use std::internal::permit;
use sui::{accumulator::AccumulatorRoot, clock::Clock, table::{Self, Table}};

// === Errors ===

const EInvalidSessionDuration: u64 = 0;
const ESessionNotAuthorized: u64 = 1;

// === Constants ===

macro fun max_session_duration_ms(): u64 { 30 * 24 * 60 * 60 * 1000 }

// === Structs ===

/// App witness for Account registry authorization and per-account data namespacing.
public struct SessionsApp has drop {}

/// Session expiration timestamps keyed by transaction signer address.
public struct SessionsData has store {
    sessions: Table<address, u64>,
}

// === Public Functions ===

/// Return a known session's expiration timestamp for SDK and devInspect reads.
public fun session_expiration_ms(account: &Account, session: address): Option<u64> {
    if (!account.has_data<SessionsApp>()) return option::none();
    let data = account.borrow_data<SessionsApp, SessionsData>();
    if (!data.sessions.contains(session)) {
        option::none()
    } else {
        option::some(*data.sessions.borrow(session))
    }
}

/// Authorize `session` from execution time for at most 30 days.
/// Reauthorizing an existing address replaces its expiration timestamp.
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
    if (!account.has_data<SessionsApp>()) {
        account.attach(permit<SessionsApp>(), SessionsData { sessions: table::new(ctx) });
    };
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    if (data.sessions.contains(session)) {
        *data.sessions.borrow_mut(session) = expires_at_ms;
    } else {
        data.sessions.add(session, expires_at_ms);
    };
}

/// Revoke `session` if it is present. Only the Account owner may call this function.
public fun revoke_session(wrapper: &mut AccountWrapper, session: address, ctx: &mut TxContext) {
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    if (!account.has_data<SessionsApp>()) return;
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    if (data.sessions.contains(session)) {
        data.sessions.remove(session);
    };
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
    leverage: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    expiry_market::mint_exact_quantity(
        market,
        wrapper,
        auth,
        config,
        pricer,
        lower_tick,
        higher_tick,
        quantity,
        leverage,
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
    leverage: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let auth = generate_auth_as_session(account_registry, wrapper, clock, ctx);
    expiry_market::mint_exact_amount(
        market,
        wrapper,
        auth,
        config,
        pricer,
        lower_tick,
        higher_tick,
        max_premium,
        min_quantity,
        leverage,
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
    expiry_market::redeem_live(
        market,
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
    expiry_market::redeem_settled(
        market,
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
    let expiration = session_expiration_ms(wrapper.load_account(), ctx.sender());
    assert!(expiration.is_some(), ESessionNotAuthorized);
    assert!(clock.timestamp_ms() < *expiration.borrow(), ESessionNotAuthorized);
    account_registry.generate_auth_as_app<SessionsApp>(permit<SessionsApp>())
}
