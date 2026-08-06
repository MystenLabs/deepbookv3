// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_sessions::sessions_tests;

use account::{
    account::{Self as account, AccountWrapper},
    account_registry::{Self as account_registry, AccountAdminCap, AccountRegistry}
};
use bs_oracle::verify;
use deepbook_predict::{
    admin::AdminCap,
    expiry_market::{Self as expiry_market, ExpiryMarket},
    market_lifecycle_cap::MarketLifecycleCap,
    market_manager,
    order,
    plp::{Self as plp, PoolVault},
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    registry::{Self as predict_registry, Registry as PredictRegistry}
};
use deepbook_sessions::sessions::{Self as sessions, SessionAuthorized, SessionRevoked, SessionsApp};
use fixed_math::math;
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::{Self as pyth_feed, PythFeed},
    registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap}
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    accumulator::{Self as accumulator, AccumulatorRoot},
    clock::{Self as clock, Clock},
    event,
    test_scenario::{Self as test, Scenario, return_shared}
};

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const SESSION: address = @0x5E5510;

const NOW_MS: u64 = 1_000;
const SESSION_DURATION_MS: u64 = 60_000;
const SESSION_EXPIRES_AT_MS: u64 = 61_000; // 1_000 + 60_000.
const REAUTH_NOW_MS: u64 = 2_000;
const REAUTH_DURATION_MS: u64 = 120_000;
const REAUTH_EXPIRES_AT_MS: u64 = 122_000; // 2_000 + 120_000.
const MAX_SESSION_DURATION_MS: u64 = 2_592_000_000; // 30 days.
const MAX_SESSION_EXPIRES_AT_MS: u64 = 2_592_001_000; // 1_000 + 30 days.
const ABOVE_MAX_SESSION_DURATION_MS: u64 = 2_592_000_001;
const ZERO_DURATION_MS: u64 = 0;
const ONE_EVENT: u64 = 1;
const EUnexpectedSuccess: u64 = 999;

const PROPBOOK_UNDERLYING_ID: u32 = 42;
const PYTH_SOURCE_ID: u32 = 1;
const MARKET_TICK_SIZE: u64 = 1_000_000_000;
const MARKET_ADMISSION_TICK_SIZE: u64 = 10_000_000_000;
const MARKET_MAX_EXPIRY_ALLOCATION: u64 = 250_000_000_000;
const MARKET_INITIAL_EXPIRY_CASH: u64 = 20_000_000_000;
const MARKET_CADENCE_WINDOW_SIZE: u64 = 1;
const GATE_NOW_MS: u64 = 120_000;
const GATE_SESSION_EXPIRES_AT_MS: u64 = 180_000; // 120_000 + 60_000.
const MARKET_EXPIRY_MS: u64 = 180_000;
const LIVE_SOURCE_TIMESTAMP_MS: u64 = 119_000;
const LIVE_PRICE: u64 = 100_000_000_000;
const PYTH_EXPONENT_NEG_9: u16 = 9;
const SVI_A_MAGNITUDE: u128 = 1;
const SVI_B: u128 = 10_000;
const SVI_SIGMA: u128 = 1_000_000;
const SVI_RHO_MAGNITUDE: u128 = 1_000_000_000;
const SVI_M_MAGNITUDE: u128 = 10_000_000_000;
const MINT_LOWER_TICK: u64 = 0;
const MINT_HIGHER_TICK: u64 = 100;
// Ten contracts at an approximately 50% range price stays above Predict's one-DUSDC minimum net premium and is an exact position-lot multiple.
const MINT_QUANTITY: u64 = 10_000_000;
const MINT_MAX_PREMIUM: u64 = 1_000;
const ZERO_COST: u64 = 0;
const ZERO_PROBABILITY: u64 = 0;
const MISSING_ORDER_ID: u256 = 1;
const CLOSE_QUANTITY: u64 = 1;

macro fun mint_leverage(): u64 { math::float_scaling!() }

public struct GateFixture {
    scenario: Scenario,
    clock: Clock,
    market_id: ID,
    wrapper_id: ID,
    config_id: ID,
    oracle_registry_id: ID,
    pyth_id: ID,
    bs_values_id: ID,
    bs_svi_id: ID,
}

public struct LiveGateInputs {
    market: ExpiryMarket,
    account_registry: AccountRegistry,
    wrapper: AccountWrapper,
    config: ProtocolConfig,
    pricer: Pricer,
    root: AccumulatorRoot,
}

#[test]
fun owner_authorizes_reauthorizes_and_revokes_session() {
    let (mut scenario, mut clock, wrapper_id) = setup_account();

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let account_id = wrapper.load_account().account_id();
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(SESSION_EXPIRES_AT_MS),
    );
    let authorized = event::events_by_type<SessionAuthorized>();
    assert_eq!(authorized.length(), ONE_EVENT);
    let (event_account_id, event_session, event_expiration) = sessions::session_authorized_fields(
        &authorized[0],
    );
    assert_eq!(event_account_id, account_id);
    assert_eq!(event_session, SESSION);
    assert_eq!(event_expiration, SESSION_EXPIRES_AT_MS);
    return_shared(wrapper);

    scenario.next_tx(ALICE);
    clock.set_for_testing(REAUTH_NOW_MS);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        REAUTH_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(REAUTH_EXPIRES_AT_MS),
    );
    let reauthorized = event::events_by_type<SessionAuthorized>();
    assert_eq!(reauthorized.length(), ONE_EVENT);
    let (_, event_session, event_expiration) = sessions::session_authorized_fields(
        &reauthorized[0],
    );
    assert_eq!(event_session, SESSION);
    assert_eq!(event_expiration, REAUTH_EXPIRES_AT_MS);
    return_shared(wrapper);

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    let revoked = event::events_by_type<SessionRevoked>();
    assert_eq!(revoked.length(), ONE_EVENT);
    let (event_account_id, event_session, event_expiration) = sessions::session_revoked_fields(
        &revoked[0],
    );
    assert_eq!(event_account_id, account_id);
    assert_eq!(event_session, SESSION);
    assert_eq!(event_expiration, REAUTH_EXPIRES_AT_MS);
    return_shared(wrapper);

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    assert!(event::events_by_type<SessionRevoked>().is_empty());
    return_shared(wrapper);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun maximum_session_duration_is_accepted() {
    let (mut scenario, clock, wrapper_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);

    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        MAX_SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(MAX_SESSION_EXPIRES_AT_MS),
    );
    return_shared(wrapper);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = sessions::EInvalidSessionDuration)]
fun zero_session_duration_aborts() {
    let (mut scenario, clock, wrapper_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);

    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        ZERO_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EInvalidSessionDuration)]
fun session_duration_above_maximum_aborts() {
    let (mut scenario, clock, wrapper_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);

    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        ABOVE_MAX_SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun non_owner_cannot_authorize_session() {
    let (mut scenario, clock, wrapper_id) = setup_account();
    scenario.next_tx(BOB);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);

    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun non_owner_cannot_revoke_session() {
    let (mut scenario, clock, wrapper_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    return_shared(wrapper);

    scenario.next_tx(BOB);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_use_predict_wrapper() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        ..,
    } = setup_gate_fixture();
    scenario.next_tx(SESSION);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(market_id);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let root = scenario.take_shared<AccumulatorRoot>();

    let (closed_order_id, replacement_order_id) = sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(closed_order_id);
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_at_exact_expiration_cannot_use_predict_wrapper() {
    let GateFixture {
        mut scenario,
        mut clock,
        market_id,
        wrapper_id,
        config_id,
        ..,
    } = setup_gate_fixture();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    return_shared(wrapper);

    clock.set_for_testing(GATE_SESSION_EXPIRES_AT_MS);
    scenario.next_tx(SESSION);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(market_id);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let root = scenario.take_shared<AccumulatorRoot>();

    let (closed_order_id, replacement_order_id) = sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(closed_order_id);
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EMarketNotSettled)]
fun active_session_passes_session_gate_and_reaches_predict() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        ..,
    } = setup_gate_fixture();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    return_shared(wrapper);

    scenario.next_tx(SESSION);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(market_id);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let root = scenario.take_shared<AccumulatorRoot>();

    let (closed_order_id, replacement_order_id) = sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(closed_order_id);
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun revoked_session_cannot_use_predict_wrapper() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        ..,
    } = setup_gate_fixture();
    authorize_gate_session(&mut scenario, &clock, wrapper_id);

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    return_shared(wrapper);

    scenario.next_tx(SESSION);
    let mut market = scenario.take_shared_by_id<ExpiryMarket>(market_id);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let root = scenario.take_shared<AccumulatorRoot>();

    let (closed_order_id, replacement_order_id) = sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(closed_order_id);
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EMintProbabilityAboveMax)]
fun active_session_reaches_predict_mint_exact_quantity() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
    } = setup_gate_fixture();
    authorize_gate_session(&mut scenario, &clock, wrapper_id);
    scenario.next_tx(SESSION);
    let LiveGateInputs {
        mut market,
        account_registry,
        mut wrapper,
        config,
        pricer,
        root,
    } = take_live_gate_inputs(
        &mut scenario,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
        &clock,
    );

    let order_id = sessions::mint_exact_quantity(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        &pricer,
        MINT_LOWER_TICK,
        MINT_HIGHER_TICK,
        MINT_QUANTITY,
        mint_leverage!(),
        std::u64::max_value!(),
        ZERO_PROBABILITY,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EMintCostCapRequired)]
fun active_session_reaches_predict_mint_exact_amount() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
    } = setup_gate_fixture();
    authorize_gate_session(&mut scenario, &clock, wrapper_id);
    scenario.next_tx(SESSION);
    let LiveGateInputs {
        mut market,
        account_registry,
        mut wrapper,
        config,
        pricer,
        root,
    } = take_live_gate_inputs(
        &mut scenario,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
        &clock,
    );

    let order_id = sessions::mint_exact_amount(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        &pricer,
        MINT_LOWER_TICK,
        MINT_HIGHER_TICK,
        MINT_MAX_PREMIUM,
        MINT_QUANTITY,
        mint_leverage!(),
        ZERO_COST,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = order::EInvalidFloorShares)]
fun active_session_reaches_predict_redeem_live() {
    let GateFixture {
        mut scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
    } = setup_gate_fixture();
    authorize_gate_session(&mut scenario, &clock, wrapper_id);
    scenario.next_tx(SESSION);
    let LiveGateInputs {
        mut market,
        account_registry,
        mut wrapper,
        config,
        pricer,
        root,
    } = take_live_gate_inputs(
        &mut scenario,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
        &clock,
    );

    let (closed_order_id, replacement_order_id) = sessions::redeem_live(
        &mut market,
        &account_registry,
        &mut wrapper,
        &config,
        &pricer,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        ZERO_PROBABILITY,
        ZERO_COST,
        &root,
        &clock,
        scenario.ctx(),
    );
    destroy(closed_order_id);
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

fun setup_account(): (Scenario, Clock, ID) {
    let mut scenario = test::begin(ADMIN);
    account_registry::init_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    scenario.next_tx(ALICE);
    let mut registry = scenario.take_shared<AccountRegistry>();
    let wrapper = registry.new(scenario.ctx());
    let wrapper_id = wrapper.id();
    wrapper.share();
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, clock, wrapper_id)
}

fun authorize_gate_session(scenario: &mut Scenario, clock: &Clock, wrapper_id: ID) {
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::authorize_session(
        &mut wrapper,
        SESSION,
        SESSION_DURATION_MS,
        clock,
        scenario.ctx(),
    );
    return_shared(wrapper);
}

fun take_live_gate_inputs(
    scenario: &mut Scenario,
    market_id: ID,
    wrapper_id: ID,
    config_id: ID,
    oracle_registry_id: ID,
    pyth_id: ID,
    bs_values_id: ID,
    bs_svi_id: ID,
    clock: &Clock,
): LiveGateInputs {
    let market = scenario.take_shared_by_id<ExpiryMarket>(market_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let oracle_registry = scenario.take_shared_by_id<OracleRegistry>(oracle_registry_id);
    let pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    let bs_values = scenario.take_shared_by_id<BlockScholesValueStore>(bs_values_id);
    let bs_svi = scenario.take_shared_by_id<BlockScholesSVIStore>(bs_svi_id);
    let pricer = market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_values,
        &bs_svi,
        clock,
        scenario.ctx(),
    );
    return_shared(oracle_registry);
    return_shared(pyth);
    return_shared(bs_values);
    return_shared(bs_svi);

    LiveGateInputs {
        market,
        account_registry: scenario.take_shared<AccountRegistry>(),
        wrapper: scenario.take_shared_by_id<AccountWrapper>(wrapper_id),
        config,
        pricer,
        root: scenario.take_shared<AccumulatorRoot>(),
    }
}

fun setup_gate_fixture(): GateFixture {
    let mut scenario = test::begin(ADMIN);
    scenario.next_tx(@0x0);
    accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    account_registry::init_for_testing(scenario.ctx());
    let vault_id = plp::init_for_testing(scenario.ctx());
    let predict_registry_id = predict_registry::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);

    let account_admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let mut account_registry = scenario.take_shared<AccountRegistry>();
    account_registry.authorize_app<SessionsApp>(&account_admin_cap);
    return_shared(account_registry);

    let admin_cap = scenario.take_from_sender<AdminCap>();
    let config = scenario.take_shared<ProtocolConfig>();
    let config_id = config.id();
    let mut registry = scenario.take_shared_by_id<PredictRegistry>(predict_registry_id);
    registry.register_underlying(&config, &admin_cap, PROPBOOK_UNDERLYING_ID);
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        PROPBOOK_UNDERLYING_ID,
        market_manager::cadence_one_minute!(),
        MARKET_TICK_SIZE,
        MARKET_ADMISSION_TICK_SIZE,
        MARKET_MAX_EXPIRY_ALLOCATION,
        MARKET_INITIAL_EXPIRY_CASH,
        MARKET_CADENCE_WINDOW_SIZE,
    );
    let lifecycle_cap = registry.mint_lifecycle_cap(&config, &admin_cap, scenario.ctx());
    return_shared(config);
    return_shared(registry);

    let propbook_admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let mut oracle_registry = scenario.take_shared<OracleRegistry>();
    let oracle_registry_id = oracle_registry.id();
    let pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        PYTH_SOURCE_ID,
        scenario.ctx(),
    );
    let bs_pair = propbook_registry::create_and_share_block_scholes_stores(
        &mut oracle_registry,
        &propbook_admin_cap,
        PROPBOOK_UNDERLYING_ID,
        b"BTC".to_string(),
        scenario.ctx(),
    );
    let bs_values_id = bs_pair.block_scholes_value_store_id();
    let bs_svi_id = bs_pair.block_scholes_svi_store_id();
    return_shared(oracle_registry);

    scenario.next_tx(ADMIN);
    let mut oracle_registry = scenario.take_shared_by_id<OracleRegistry>(oracle_registry_id);
    let mut pyth = scenario.take_shared_by_id<PythFeed>(pyth_id);
    propbook_registry::bind_pyth_to_underlying(
        &mut oracle_registry,
        &propbook_admin_cap,
        &pyth,
        PROPBOOK_UNDERLYING_ID,
    );
    let mut registry = scenario.take_shared_by_id<PredictRegistry>(predict_registry_id);
    let mut vault = scenario.take_shared_by_id<PoolVault>(vault_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(GATE_NOW_MS);
    let market_id = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        PROPBOOK_UNDERLYING_ID,
        market_manager::cadence_one_minute!(),
        &clock,
        scenario.ctx(),
    );
    pyth_feed::record_raw_for_testing(
        &mut pyth,
        LIVE_PRICE,
        false,
        PYTH_EXPONENT_NEG_9,
        true,
        LIVE_SOURCE_TIMESTAMP_MS * 1000,
        LIVE_SOURCE_TIMESTAMP_MS * 1000,
        GATE_NOW_MS,
        false,
        scenario.ctx(),
    );
    let mut bs_values = scenario.take_shared_by_id<BlockScholesValueStore>(bs_values_id);
    let spot_sid = bs_values.spot_sid();
    bs_values.apply_spot_batch(
        verify::new_value_batch_for_testing(
            LIVE_SOURCE_TIMESTAMP_MS,
            vector[
                verify::new_value_update_for_testing(
                    spot_sid,
                    LIVE_SOURCE_TIMESTAMP_MS,
                    LIVE_PRICE as u128,
                ),
            ],
        ),
        &clock,
        scenario.ctx(),
    );
    let forward_sid = bs_values.forward_sid(MARKET_EXPIRY_MS);
    bs_values.apply_forward_batch(
        verify::new_value_batch_for_testing(
            LIVE_SOURCE_TIMESTAMP_MS,
            vector[
                verify::new_value_update_for_testing(
                    forward_sid,
                    LIVE_SOURCE_TIMESTAMP_MS,
                    LIVE_PRICE as u128,
                ),
            ],
        ),
        vector[MARKET_EXPIRY_MS],
        &clock,
        scenario.ctx(),
    );
    let mut bs_svi = scenario.take_shared_by_id<BlockScholesSVIStore>(bs_svi_id);
    let svi_sid = bs_svi.svi_sid(MARKET_EXPIRY_MS);
    bs_svi.apply_svi_batch(
        verify::new_svi_batch_for_testing(
            GATE_NOW_MS,
            vector[
                verify::new_svi_for_testing(
                    svi_sid,
                    GATE_NOW_MS,
                    SVI_A_MAGNITUDE,
                    false,
                    SVI_B,
                    SVI_SIGMA,
                    SVI_RHO_MAGNITUDE,
                    false,
                    SVI_M_MAGNITUDE,
                    false,
                ),
            ],
        ),
        vector[MARKET_EXPIRY_MS],
        &clock,
        scenario.ctx(),
    );
    return_shared(pyth);
    return_shared(bs_values);
    return_shared(bs_svi);
    return_shared(oracle_registry);
    return_shared(registry);
    return_shared(vault);
    return_shared(config);
    destroy(account_admin_cap);
    destroy(admin_cap);
    destroy(propbook_admin_cap);
    destroy(lifecycle_cap);

    scenario.next_tx(ALICE);
    let mut account_registry = scenario.take_shared<AccountRegistry>();
    let wrapper = account_registry.new(scenario.ctx());
    let wrapper_id = wrapper.id();
    wrapper.share();
    return_shared(account_registry);
    scenario.next_tx(ADMIN);

    GateFixture {
        scenario,
        clock,
        market_id,
        wrapper_id,
        config_id,
        oracle_registry_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
    }
}
