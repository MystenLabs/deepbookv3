// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns time-limited trading session grants attached to canonical Accounts.
/// Account owners grant and revoke sessions; an active session can only generate
/// app auth inside the Predict and DeepBook spot wrappers exposed here.
///
/// A session-key trade that names a Predict builder code pays that builder a fee
/// the session holder picks, so the owner approves one code and a maximum fee per
/// session (`approve_session_builder`), and the `_with_builder` wrappers accept
/// only that code at or below that fee.
module deepbook_sessions::sessions;

use account::{account::{Self, Account, AccountWrapper, Auth}, account_registry::AccountRegistry};
use deepbook::{order_info::OrderInfo, pool::Pool, registry::Registry};
use deepbook_core_account::deepbook_core_account;
use deepbook_predict::{
    builder_code::BuilderCode,
    expiry_market::ExpiryMarket,
    pricing::Pricer,
    protocol_config::ProtocolConfig
};
use deepbook_predict_orders::{desk::OrderDesk, queue::MarketQueue};
use deepbook_sessions::session_config::{Self, SessionsConfig};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::OracleRegistry
};
use std::internal::permit;
use sui::{accumulator::AccumulatorRoot, clock::Clock, event, vec_map::{Self, VecMap}};

// === Errors ===

const EInvalidSessionDuration: u64 = 0;
const ESessionNotAuthorized: u64 = 1;
const ESessionLimitExceeded: u64 = 2;
const EBuilderNotApproved: u64 = 3;
const EBuilderFeeAboveApproved: u64 = 4;
const EBuilderApprovalsNotEnabled: u64 = 5;

// === Constants ===

macro fun max_session_duration_ms(): u64 { 30 * 24 * 60 * 60 * 1000 }

macro fun max_sessions(): u64 { 20 }

/// The Sessions version floor at which builder approvals open: the first version
/// whose `authorize_session` clears an approval left on a new grant. An older
/// `authorize_session` would keep it, so approvals wait until the watermark
/// retires every older version.
macro fun builder_approval_version(): u64 { 4 }

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

/// Data-slot witness for the builder approvals. `SessionsData` was published
/// without them, so they live in a slot of their own.
public struct SessionBuildersApp has drop {}

/// Each session's approved builder, keyed by session address. `revoke_session`
/// removes an entry. The pre-upgrade `revoke_session` can leave one behind for a
/// session no longer in `SessionsData`; no trade can use it, and a new grant of
/// that address or another `revoke_session` clears it.
public struct SessionBuilders has store {
    approvals: VecMap<address, SessionBuilder>,
}

/// The builder code a session's trades may name and the most they may charge per
/// contract, in FLOAT_SCALING of a Predict contract's $1 payout.
public struct SessionBuilder has copy, drop, store {
    code_id: ID,
    max_fee_per_contract: u64,
}

/// A session's builder was approved or replaced.
public struct SessionBuilderApproved has copy, drop {
    account_id: ID,
    session: address,
    code_id: ID,
    max_fee_per_contract: u64,
}

/// A session's builder approval was removed: by `revoke_session`, or by a new
/// grant for an address whose approval outlived its session.
public struct SessionBuilderCleared has copy, drop {
    account_id: ID,
    session: address,
}

// === Public Functions ===

/// Return a known session's expiration timestamp for SDK and devInspect reads.
public fun session_expiration_ms(wrapper: &AccountWrapper, session: address): Option<u64> {
    let account = wrapper.load_account();
    if (!account.has_data<SessionsApp>()) return option::none();
    let data = account.borrow_data<SessionsApp, SessionsData>();
    data.sessions.try_get(&session)
}

/// Return a session's approved builder, or `none`, for SDK and devInspect reads.
public fun session_builder(wrapper: &AccountWrapper, session: address): Option<SessionBuilder> {
    let account = wrapper.load_account();
    if (!account.has_data<SessionBuildersApp>()) return option::none();
    let data = account.borrow_data<SessionBuildersApp, SessionBuilders>();
    data.approvals.try_get(&session)
}

/// Return the builder code an approval allows, for SDK and devInspect reads.
public fun approved_code_id(builder: &SessionBuilder): ID {
    builder.code_id
}

/// Return the most an approval allows per contract, for SDK and devInspect reads.
public fun approved_max_fee_per_contract(builder: &SessionBuilder): u64 {
    builder.max_fee_per_contract
}

/// Authorize `session` from execution time for at most 30 days.
/// Accounts may store at most 20 addresses; reauthorization replaces in place
/// and keeps the session's builder approval, while a new grant starts without
/// one. A session that expired but was never revoked is still stored, so
/// granting it again is a reauthorization and keeps its approval.
public fun authorize_session(
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    session: address,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    sessions_config.assert_version();
    assert!(duration_ms > 0 && duration_ms <= max_session_duration_ms!(), EInvalidSessionDuration);
    let expires_at_ms = clock.timestamp_ms() + duration_ms;
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    let account_id = account.account_id();
    if (!account.has_data<SessionsApp>()) {
        account.attach(permit<SessionsApp>(), SessionsData { sessions: vec_map::empty() });
    };
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    let is_new = !data.sessions.contains(&session);
    if (is_new) {
        assert!(data.sessions.length() < max_sessions!(), ESessionLimitExceeded);
        data.sessions.insert(session, expires_at_ms);
    } else {
        *data.sessions.get_mut(&session) = expires_at_ms;
    };
    // The pre-upgrade `revoke_session` removes a session but not its builder
    // approval, so a new grant starts without one.
    if (is_new) clear_builder(account, account_id, session);
    event::emit(SessionAuthorized { account_id, session, expires_at_ms });
}

/// Approve the builder code `session`'s trades may name, and the most they may
/// charge per contract (`max_fee_per_contract`, in FLOAT_SCALING of the $1
/// payout), replacing any earlier approval. Only the Account owner may call this,
/// and only for a session already authorized (`ESessionNotAuthorized`), so an app
/// calls it right after `authorize_session` in the same transaction. The
/// approval lasts until `revoke_session`; re-authorizing the session keeps it.
/// Aborts `EBuilderApprovalsNotEnabled` until the `SessionsConfig` watermark
/// reaches the first version that clears stale approvals.
public fun approve_session_builder(
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    session: address,
    code_id: ID,
    max_fee_per_contract: u64,
    ctx: &mut TxContext,
) {
    sessions_config.assert_version();
    assert!(
        sessions_config.version_watermark() >= builder_approval_version!(),
        EBuilderApprovalsNotEnabled,
    );
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    assert!(
        account.has_data<SessionsApp>()
            && account.borrow_data<SessionsApp, SessionsData>().sessions.contains(&session),
        ESessionNotAuthorized,
    );
    let account_id = account.account_id();
    if (!account.has_data<SessionBuildersApp>()) {
        account.attach(
            permit<SessionBuildersApp>(),
            SessionBuilders { approvals: vec_map::empty() },
        );
    };
    let data = account.borrow_data_mut<SessionBuildersApp, SessionBuilders>(
        permit<SessionBuildersApp>(),
    );
    let approval = SessionBuilder { code_id, max_fee_per_contract };
    if (data.approvals.contains(&session)) {
        *data.approvals.get_mut(&session) = approval;
    } else {
        data.approvals.insert(session, approval);
    };
    event::emit(SessionBuilderApproved { account_id, session, code_id, max_fee_per_contract });
}

/// Revoke `session` and its builder approval if present. Only the Account owner
/// may call this function.
public fun revoke_session(wrapper: &mut AccountWrapper, session: address, ctx: &mut TxContext) {
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    let account_id = account.account_id();
    clear_builder(account, account_id, session);
    if (!account.has_data<SessionsApp>()) return;
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
    sessions_config: &SessionsConfig,
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
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
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
    sessions_config: &SessionsConfig,
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
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
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
    sessions_config: &SessionsConfig,
    order_id: u128,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    deepbook_core_account::cancel_live_order(pool, wrapper, auth, order_id, clock, ctx);
}

/// Cancel multiple DeepBook spot orders for an Account with an active session.
public fun cancel_live_orders<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    order_ids: vector<u128>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    deepbook_core_account::cancel_live_orders(pool, wrapper, auth, order_ids, clock, ctx);
}

/// Sweep settled DeepBook spot proceeds into an Account with an active session.
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    deepbook_core_account::withdraw_settled_amounts(pool, wrapper, auth, ctx);
}

/// Mint an exact Predict position quantity for an Account with an active session.
/// Always aborts through Predict, whose immediate mints are retired; use
/// `enqueue_exact_quantity`.
public fun mint_exact_quantity(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
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
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
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
/// Always aborts through Predict, whose immediate mints are retired; use
/// `enqueue_exact_amount`.
public fun mint_exact_amount(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
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
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
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

/// Mint a Predict position sized to an all-in cost for an Account with an active
/// session. Always aborts through Predict, whose immediate mints are retired; use
/// `enqueue_exact_cost`.
public fun mint_exact_cost(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    config: &ProtocolConfig,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u256 {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    market.mint_exact_cost(
        wrapper,
        auth,
        config,
        pricer,
        lower_tick,
        higher_tick,
        max_cost,
        min_quantity,
        root,
        clock,
        ctx,
    )
}

/// Redeem a live Predict order for an Account with an active session. Always
/// aborts through Predict, whose live redeem is retired. Early sells of queued
/// positions go through `enqueue_redeem_open`.
public fun redeem_live(
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    config: &ProtocolConfig,
    pricer: &Pricer,
    order_id: u256,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<u256> {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
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
    sessions_config: &SessionsConfig,
    config: &ProtocolConfig,
    order_id: u256,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    market.redeem_settled(
        wrapper,
        auth,
        config,
        order_id,
        root,
        clock,
        ctx,
    )
}

/// Queue an exact-quantity Predict mint in `market`'s order-flow queue for an
/// Account with an active session. Returns the queue record ID.
public fun enqueue_exact_quantity(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    queue.enqueue_exact_quantity(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
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

/// `enqueue_exact_quantity` for a session-key mint that names a builder: `code` and
/// `builder_fee_per_contract` must be the session's approved code and at most its
/// approved fee (`EBuilderNotApproved`, `EBuilderFeeAboveApproved`), after the
/// session checks. Returns the new queue record ID.
public fun enqueue_exact_quantity_with_builder(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    code: &BuilderCode,
    builder_fee_per_contract: u64,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    max_cost: u64,
    max_probability: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = session_auth_with_builder(
        sessions_config,
        account_registry,
        wrapper,
        code,
        builder_fee_per_contract,
        clock,
        ctx,
    );
    queue.enqueue_exact_quantity_with_builder(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        code,
        builder_fee_per_contract,
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

/// Queue a premium-budget Predict mint in `market`'s order-flow queue for an
/// Account with an active session. Returns the queue record ID.
public fun enqueue_exact_amount(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    queue.enqueue_exact_amount(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
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

/// `enqueue_exact_amount` for a session-key mint that names a builder: `code` and
/// `builder_fee_per_contract` must be the session's approved code and at most its
/// approved fee (`EBuilderNotApproved`, `EBuilderFeeAboveApproved`), after the
/// session checks. Returns the new queue record ID.
public fun enqueue_exact_amount_with_builder(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    code: &BuilderCode,
    builder_fee_per_contract: u64,
    lower_tick: u64,
    higher_tick: u64,
    max_premium: u64,
    min_quantity: u64,
    max_cost: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = session_auth_with_builder(
        sessions_config,
        account_registry,
        wrapper,
        code,
        builder_fee_per_contract,
        clock,
        ctx,
    );
    queue.enqueue_exact_amount_with_builder(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        code,
        builder_fee_per_contract,
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

/// Queue an all-in-budget Predict mint in `market`'s order-flow queue for an
/// Account with an active session. Returns the queue record ID.
public fun enqueue_exact_cost(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    queue.enqueue_exact_cost(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        lower_tick,
        higher_tick,
        max_cost,
        min_quantity,
        root,
        clock,
        ctx,
    )
}

/// `enqueue_exact_cost` for a session-key mint that names a builder: `code` and
/// `builder_fee_per_contract` must be the session's approved code and at most its
/// approved fee (`EBuilderNotApproved`, `EBuilderFeeAboveApproved`), after the
/// session checks. Returns the new queue record ID.
public fun enqueue_exact_cost_with_builder(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    code: &BuilderCode,
    builder_fee_per_contract: u64,
    lower_tick: u64,
    higher_tick: u64,
    max_cost: u64,
    min_quantity: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = session_auth_with_builder(
        sessions_config,
        account_registry,
        wrapper,
        code,
        builder_fee_per_contract,
        clock,
        ctx,
    );
    queue.enqueue_exact_cost_with_builder(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        code,
        builder_fee_per_contract,
        lower_tick,
        higher_tick,
        max_cost,
        min_quantity,
        root,
        clock,
        ctx,
    )
}

/// Queue an early sell of an Open order-flow queue record for an Account with
/// an active session. Returns the new queue record ID.
public fun enqueue_redeem_open(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    queue.enqueue_redeem_open(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}

/// `enqueue_redeem_open` for a session-key sell that names a builder: `code` and
/// `builder_fee_per_contract` must be the session's approved code and at most its
/// approved fee (`EBuilderNotApproved`, `EBuilderFeeAboveApproved`), after the
/// session checks. Returns the new queue record ID.
public fun enqueue_redeem_open_with_builder(
    queue: &mut MarketQueue,
    market: &mut ExpiryMarket,
    account_registry: &AccountRegistry,
    wrapper: &mut AccountWrapper,
    sessions_config: &SessionsConfig,
    desk: &OrderDesk,
    config: &ProtocolConfig,
    propbook_registry: &OracleRegistry,
    pyth: &PythFeed,
    bs_values: &BlockScholesValueStore,
    bs_svi: &BlockScholesSVIStore,
    code: &BuilderCode,
    builder_fee_per_contract: u64,
    record_id: u64,
    close_quantity: u64,
    min_probability: u64,
    min_proceeds: u64,
    root: &AccumulatorRoot,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let auth = session_auth_with_builder(
        sessions_config,
        account_registry,
        wrapper,
        code,
        builder_fee_per_contract,
        clock,
        ctx,
    );
    queue.enqueue_redeem_open_with_builder(
        market,
        wrapper,
        auth,
        desk,
        config,
        propbook_registry,
        pyth,
        bs_values,
        bs_svi,
        code,
        builder_fee_per_contract,
        record_id,
        close_quantity,
        min_probability,
        min_proceeds,
        root,
        clock,
        ctx,
    )
}

// === Private Functions ===

fun generate_auth_as_session(
    sessions_config: &SessionsConfig,
    account_registry: &AccountRegistry,
    wrapper: &AccountWrapper,
    clock: &Clock,
    ctx: &TxContext,
): Auth {
    sessions_config.assert_version();
    let expiration = session_expiration_ms(wrapper, ctx.sender());
    assert!(expiration.is_some(), ESessionNotAuthorized);
    assert!(clock.timestamp_ms() < *expiration.borrow(), ESessionNotAuthorized);
    account_registry.generate_auth_as_app<SessionsApp>(permit<SessionsApp>())
}

/// `generate_auth_as_session` for a session-key trade that names a builder: after
/// the session checks, the session's approval must name `code`
/// (`EBuilderNotApproved`) and allow at least `builder_fee_per_contract`
/// (`EBuilderFeeAboveApproved`).
fun session_auth_with_builder(
    sessions_config: &SessionsConfig,
    account_registry: &AccountRegistry,
    wrapper: &AccountWrapper,
    code: &BuilderCode,
    builder_fee_per_contract: u64,
    clock: &Clock,
    ctx: &TxContext,
): Auth {
    let auth = generate_auth_as_session(sessions_config, account_registry, wrapper, clock, ctx);
    let approval = session_builder(wrapper, ctx.sender());
    assert!(approval.is_some() && approval.borrow().code_id == code.id(), EBuilderNotApproved);
    assert!(
        builder_fee_per_contract <= approval.borrow().max_fee_per_contract,
        EBuilderFeeAboveApproved,
    );
    auth
}

/// Remove `session`'s builder approval, if any, and emit `SessionBuilderCleared`.
/// Every removal goes through here, so the event stream tracks approvals.
fun clear_builder(account: &mut Account, account_id: ID, session: address) {
    if (!account.has_data<SessionBuildersApp>()) return;
    let builders = account.borrow_data_mut<SessionBuildersApp, SessionBuilders>(
        permit<SessionBuildersApp>(),
    );
    if (!builders.approvals.contains(&session)) return;
    let (_, _) = builders.approvals.remove(&session);
    event::emit(SessionBuilderCleared { account_id, session });
}

#[test_only]
/// The pre-upgrade `revoke_session`, which removes the session but not its
/// builder approval. That version stays callable after an upgrade.
public fun revoke_session_without_builder_for_testing(
    wrapper: &mut AccountWrapper,
    session: address,
    ctx: &mut TxContext,
) {
    let account = wrapper.load_account_mut(account::generate_auth(ctx));
    let data = account.borrow_data_mut<SessionsApp, SessionsData>(permit<SessionsApp>());
    let (_, _) = data.sessions.remove(&session);
}
