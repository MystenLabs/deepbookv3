// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_sessions::sessions_tests;

use account::{
    account::{Self as account, AccountWrapper},
    account_registry::{Self as account_registry, AccountRegistry}
};
use deepbook_predict::{
    expiry_market::{Self as expiry_market, ExpiryMarket},
    flow_test_helpers as predict_helpers,
    order_events,
    predict_account,
    pricing::Pricer,
    protocol_config::ProtocolConfig,
    test_constants
};
use deepbook_sessions::{
    session_config::{Self as session_config, SessionsConfig},
    sessions::{Self as sessions, SessionAuthorized, SessionRevoked, SessionsApp}
};
use propbook::{
    block_scholes_store::{BlockScholesSVIStore, BlockScholesValueStore},
    pyth_feed::PythFeed,
    registry::{Self as propbook_registry, OracleRegistry}
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{
    accumulator::AccumulatorRoot,
    clock::{Self as clock, Clock},
    event,
    test_scenario::{Self as test, Scenario, return_shared}
};
use usdc::usdc::USDC;

const ADMIN: address = @0xAD;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const SESSION: address = @0x5E5510;
const SESSION_ONE: address = @0x51;
const SESSION_TWO: address = @0x52;
const SESSION_THREE: address = @0x53;
const SESSION_FOUR: address = @0x54;
const SESSION_FIVE: address = @0x55;
const SESSION_SIX: address = @0x56;
const SESSION_SEVEN: address = @0x57;
const SESSION_EIGHT: address = @0x58;
const SESSION_NINE: address = @0x59;
const SESSION_TEN: address = @0x510;
const SESSION_ELEVEN: address = @0x511;
const SESSION_TWELVE: address = @0x512;
const SESSION_THIRTEEN: address = @0x513;
const SESSION_FOURTEEN: address = @0x514;
const SESSION_FIFTEEN: address = @0x515;
const SESSION_SIXTEEN: address = @0x516;
const SESSION_SEVENTEEN: address = @0x517;
const SESSION_EIGHTEEN: address = @0x518;
const SESSION_NINETEEN: address = @0x519;
const SESSION_TWENTY: address = @0x520;
const SESSION_TWENTY_ONE: address = @0x521;

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
const MAX_SESSIONS: u64 = 20;
const FIRST_SESSION_INDEX: u64 = 0;
const LAST_SESSION_INDEX: u64 = 19;
const EXCESS_SESSION_INDEX: u64 = 20;
const POST_REVOKE_EXPIRES_AT_MS: u64 = 62_000; // 2_000 + 60_000.
const ONE_EVENT: u64 = 1;
const EUnexpectedSuccess: u64 = 999;

const FLOW_SESSION_EXPIRES_AT_MS: u64 = 180_000; // 120_000 + 60_000.
const SETTLEMENT_SESSION_DURATION_MS: u64 = 180_000;
const SETTLEMENT_SESSION_EXPIRES_AT_MS: u64 = 300_000; // 120_000 + 180_000.
const LIVE_REDEEM_MS: u64 = 120_001;
const DEFAULT_TRADE_FEE: u64 = 5_000_000;
const TEN_THOUSAND_LOTS: u64 = 100_000_000;
const NEXT_LOT_QUANTITY: u64 = 100_010_000;
const SETTLEMENT_HIGHER_TICK_OFFSET: u64 = 10;
const SETTLEMENT_PRICE_TICK_OFFSET: u64 = 1;
const ONE_RAW_UNIT: u64 = 1;
const ZERO_COST: u64 = 0;
const ZERO_PREMIUM: u64 = 0;
const ZERO_PROBABILITY: u64 = 0;
const MISSING_ORDER_ID: u256 = 1;
const CLOSE_QUANTITY: u64 = 1;
const FUTURE_VERSION: u64 = 2;

public struct ExpectedSessionAuthorized has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}

public struct ExpectedSessionRevoked has copy, drop {
    account_id: ID,
    session: address,
    expires_at_ms: u64,
}

public struct SessionFlowFixture {
    predict: predict_helpers::Fixture,
    clock: Clock,
    market_id: ID,
    owner: address,
    wrapper_id: ID,
    sessions_config_id: ID,
    config_id: ID,
    pyth_id: ID,
    bs_values_id: ID,
    bs_svi_id: ID,
}

public struct LiveInputs {
    market: ExpiryMarket,
    account_registry: AccountRegistry,
    wrapper: AccountWrapper,
    sessions_config: SessionsConfig,
    config: ProtocolConfig,
    pricer: Pricer,
    root: AccumulatorRoot,
}

public struct SettledInputs {
    market: ExpiryMarket,
    account_registry: AccountRegistry,
    wrapper: AccountWrapper,
    sessions_config: SessionsConfig,
    config: ProtocolConfig,
    root: AccumulatorRoot,
}

#[test]
fun owner_authorizes_reauthorizes_and_revokes_session() {
    let (mut scenario, mut clock, wrapper_id, sessions_config_id) = setup_account();

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let account_id = wrapper.load_account().account_id();
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
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
    assert_session_authorized_event(
        &authorized[0],
        account_id,
        SESSION,
        SESSION_EXPIRES_AT_MS,
    );
    return_shared(sessions_config);
    return_shared(wrapper);

    scenario.next_tx(ALICE);
    clock.set_for_testing(REAUTH_NOW_MS);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
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
    assert_session_authorized_event(
        &reauthorized[0],
        account_id,
        SESSION,
        REAUTH_EXPIRES_AT_MS,
    );
    return_shared(sessions_config);
    return_shared(wrapper);

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    assert!(wrapper.load_account().has_data<SessionsApp>());
    let revoked = event::events_by_type<SessionRevoked>();
    assert_eq!(revoked.length(), ONE_EVENT);
    assert_session_revoked_event(
        &revoked[0],
        account_id,
        SESSION,
        REAUTH_EXPIRES_AT_MS,
    );
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
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        MAX_SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(MAX_SESSION_EXPIRES_AT_MS),
    );
    return_shared(sessions_config);
    return_shared(wrapper);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun session_limit_allows_reauthorization_and_reuse_after_revocation() {
    let (mut scenario, mut clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let session_addresses = session_addresses();
    let mut index = FIRST_SESSION_INDEX;
    while (index < MAX_SESSIONS) {
        sessions::authorize_session(
            &mut wrapper,
            &sessions_config,
            session_addresses[index],
            SESSION_DURATION_MS,
            &clock,
            scenario.ctx(),
        );
        index = index + 1;
    };
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[FIRST_SESSION_INDEX]),
        option::some(SESSION_EXPIRES_AT_MS),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[LAST_SESSION_INDEX]),
        option::some(SESSION_EXPIRES_AT_MS),
    );

    clock.set_for_testing(REAUTH_NOW_MS);
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        session_addresses[LAST_SESSION_INDEX],
        REAUTH_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[LAST_SESSION_INDEX]),
        option::some(REAUTH_EXPIRES_AT_MS),
    );

    sessions::revoke_session(
        &mut wrapper,
        session_addresses[FIRST_SESSION_INDEX],
        scenario.ctx(),
    );
    assert!(
        sessions::session_expiration_ms(&wrapper, session_addresses[FIRST_SESSION_INDEX]).is_none(),
    );
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        session_addresses[EXCESS_SESSION_INDEX],
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[EXCESS_SESSION_INDEX]),
        option::some(POST_REVOKE_EXPIRES_AT_MS),
    );
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[LAST_SESSION_INDEX]),
        option::some(REAUTH_EXPIRES_AT_MS),
    );

    return_shared(sessions_config);
    return_shared(wrapper);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = sessions::ESessionLimitExceeded)]
fun twenty_first_distinct_session_aborts() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    let session_addresses = session_addresses();
    let mut index = FIRST_SESSION_INDEX;
    while (index < MAX_SESSIONS) {
        sessions::authorize_session(
            &mut wrapper,
            &sessions_config,
            session_addresses[index],
            SESSION_DURATION_MS,
            &clock,
            scenario.ctx(),
        );
        index = index + 1;
    };
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, session_addresses[LAST_SESSION_INDEX]),
        option::some(SESSION_EXPIRES_AT_MS),
    );

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        session_addresses[EXCESS_SESSION_INDEX],
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EInvalidSessionDuration)]
fun zero_session_duration_aborts() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        ZERO_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::EInvalidSessionDuration)]
fun session_duration_above_maximum_aborts() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        ABOVE_MAX_SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun non_owner_cannot_authorize_session() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(BOB);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun non_owner_cannot_revoke_session() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    return_shared(sessions_config);
    return_shared(wrapper);

    scenario.next_tx(BOB);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_authorize_session() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let mut sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    session_config::set_version_watermark_for_testing(&mut sessions_config, FUTURE_VERSION);

    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );

    abort EUnexpectedSuccess
}

#[test]
fun retired_package_version_keeps_reads_and_revocation_available() {
    let (mut scenario, clock, wrapper_id, sessions_config_id) = setup_account();
    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        SESSION_DURATION_MS,
        &clock,
        scenario.ctx(),
    );
    return_shared(sessions_config);
    return_shared(wrapper);

    scenario.next_tx(ADMIN);
    let mut sessions_config = scenario.take_shared_by_id<SessionsConfig>(sessions_config_id);
    session_config::set_version_watermark_for_testing(&mut sessions_config, FUTURE_VERSION);
    assert_eq!(sessions_config.version_watermark(), FUTURE_VERSION);
    return_shared(sessions_config);

    scenario.next_tx(ALICE);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(wrapper_id);
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(SESSION_EXPIRES_AT_MS),
    );
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    assert!(sessions::session_expiration_ms(&wrapper, SESSION).is_none());
    return_shared(wrapper);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_use_predict_wrapper() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    let SettledInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        root,
    } = begin_settled_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        MISSING_ORDER_ID,
        &root,
        clock,
        scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_mint_exact_quantity() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    let order_id = sessions::mint_exact_quantity(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        std::u64::max_value!(),
        ZERO_PROBABILITY,
        &root,
        clock,
        scenario.ctx(),
    );
    destroy(order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_mint_exact_amount() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    let order_id = sessions::mint_exact_amount(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        test_constants::mint_deposit(),
        test_constants::mint_quantity(),
        ZERO_COST,
        &root,
        clock,
        scenario.ctx(),
    );
    destroy(order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun unapproved_session_cannot_redeem_live() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    let replacement_order_id = sessions::redeem_live(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        MISSING_ORDER_ID,
        CLOSE_QUANTITY,
        ZERO_PROBABILITY,
        ZERO_COST,
        &root,
        clock,
        scenario.ctx(),
    );
    destroy(replacement_order_id);

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun session_at_exact_expiration_cannot_use_predict_wrapper() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    authorize_flow_session(&mut fixture, SESSION_DURATION_MS);
    fixture.clock.set_for_testing(FLOW_SESSION_EXPIRES_AT_MS);
    let SettledInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        root,
    } = begin_settled_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        MISSING_ORDER_ID,
        &root,
        clock,
        scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun revoked_session_cannot_use_predict_wrapper() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    authorize_flow_session(&mut fixture, SESSION_DURATION_MS);
    revoke_flow_session(&mut fixture);
    let SettledInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        root,
    } = begin_settled_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        MISSING_ORDER_ID,
        &root,
        clock,
        scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = sessions::ESessionNotAuthorized)]
fun another_signer_cannot_use_an_approved_session() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    authorize_flow_session(&mut fixture, SESSION_DURATION_MS);
    let SettledInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        root,
    } = begin_settled_tx(&mut fixture, BOB);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();

    sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        MISSING_ORDER_ID,
        &root,
        clock,
        scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun session_mints_exact_quantity_and_redeems_live() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    authorize_flow_session(&mut fixture, SESSION_DURATION_MS);
    let market_id = fixture.market_id;
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    // Predict's independent ATM reference anchors the quote; this test owns
    // forwarding its exact cost and probability through Sessions.
    let quote = market.quote_mint_for_account(
        &wrapper,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        ZERO_PREMIUM,
        test_constants::mint_quantity(),
        true,
        &root,
        clock,
        scenario.ctx(),
    );
    predict_helpers::assert_atm_entry_probability(quote.entry_probability());
    let order_id = sessions::mint_exact_quantity(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        quote.entry_probability(),
        &root,
        clock,
        scenario.ctx(),
    );
    let post_mint_balance = test_constants::mint_deposit() - quote.all_in_cost();
    assert_eq!(wrapper.load_account().balance<USDC>(&root, clock), post_mint_balance);
    assert!(predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert_eq!(event::events_by_type<order_events::OrderMinted>().length(), ONE_EVENT);
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(FLOW_SESSION_EXPIRES_AT_MS),
    );
    return_live_inputs(LiveInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        pricer,
        root,
    });

    fixture.clock.set_for_testing(LIVE_REDEEM_MS);
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    let gross_value = market.live_order_value(&pricer, order_id);
    let replacement_order_id = sessions::redeem_live(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        order_id,
        test_constants::mint_quantity(),
        ZERO_PROBABILITY,
        ZERO_COST,
        &root,
        clock,
        scenario.ctx(),
    );
    assert!(replacement_order_id.is_none());
    // The public order value is gross of the fixture's one minimum close fee.
    assert_eq!(
        wrapper.load_account().balance<USDC>(&root, clock),
        post_mint_balance + gross_value - DEFAULT_TRADE_FEE,
    );
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert_eq!(event::events_by_type<order_events::LiveOrderRedeemed>().length(), ONE_EVENT);
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(FLOW_SESSION_EXPIRES_AT_MS),
    );
    return_live_inputs(LiveInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        pricer,
        root,
    });
    finish_flow_fixture(fixture);
}

#[test]
fun session_mints_exact_amount() {
    let mut fixture = setup_flow_fixture(test_constants::default_expiry_ms());
    authorize_flow_session(&mut fixture, SESSION_DURATION_MS);
    let market_id = fixture.market_id;
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    let next_lot_quote = market.quote_mint_for_account(
        &wrapper,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        ZERO_PREMIUM,
        NEXT_LOT_QUANTITY,
        true,
        &root,
        clock,
        scenario.ctx(),
    );
    predict_helpers::assert_atm_entry_probability(next_lot_quote.entry_probability());
    let expected_quote = market.quote_mint_for_account(
        &wrapper,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        ZERO_PREMIUM,
        TEN_THOUSAND_LOTS,
        true,
        &root,
        clock,
        scenario.ctx(),
    );
    predict_helpers::assert_atm_entry_probability(expected_quote.entry_probability());
    // One raw unit below the next lot's premium must size exactly ten thousand lots.
    let budget = next_lot_quote.premium() - ONE_RAW_UNIT;
    let order_id = sessions::mint_exact_amount(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        predict_helpers::strike_tick(),
        predict_helpers::pos_inf_tick(),
        budget,
        TEN_THOUSAND_LOTS,
        expected_quote.all_in_cost(),
        &root,
        clock,
        scenario.ctx(),
    );
    assert_eq!(expected_quote.quantity(), TEN_THOUSAND_LOTS);
    assert_eq!(
        wrapper.load_account().balance<USDC>(&root, clock),
        test_constants::mint_deposit() - expected_quote.all_in_cost(),
    );
    assert!(predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert_eq!(event::events_by_type<order_events::OrderMinted>().length(), ONE_EVENT);
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(FLOW_SESSION_EXPIRES_AT_MS),
    );
    return_live_inputs(LiveInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        pricer,
        root,
    });
    finish_flow_fixture(fixture);
}

#[test]
fun session_redeems_settled_order() {
    let expiry_ms = test_constants::short_expiry_ms();
    let mut fixture = setup_flow_fixture(expiry_ms);
    authorize_flow_session(&mut fixture, SETTLEMENT_SESSION_DURATION_MS);
    let market_id = fixture.market_id;
    let lower_tick = predict_helpers::strike_tick();
    let higher_tick = lower_tick + SETTLEMENT_HIGHER_TICK_OFFSET;
    let LiveInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        pricer,
        root,
    } = begin_live_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    // Predict's quote tests own the mint cost; this flow owns session auth and
    // the independently exact in-range terminal payout.
    let quote = market.quote_mint_for_account(
        &wrapper,
        &config,
        &pricer,
        lower_tick,
        higher_tick,
        ZERO_PREMIUM,
        test_constants::mint_quantity(),
        true,
        &root,
        clock,
        scenario.ctx(),
    );
    let order_id = sessions::mint_exact_quantity(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        &pricer,
        lower_tick,
        higher_tick,
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        quote.entry_probability(),
        &root,
        clock,
        scenario.ctx(),
    );
    let post_mint_balance = test_constants::mint_deposit() - quote.all_in_cost();
    assert_eq!(wrapper.load_account().balance<USDC>(&root, clock), post_mint_balance);
    assert!(predict_account::has_position(wrapper.load_account(), market_id, order_id));
    return_live_inputs(LiveInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        pricer,
        root,
    });

    fixture.clock.set_for_testing(expiry_ms);
    fixture.predict.set_clock_for_testing(expiry_ms);
    let settlement_price =
        (lower_tick + SETTLEMENT_PRICE_TICK_OFFSET) * test_constants::default_tick_size();
    settle_flow_market(&mut fixture, settlement_price);
    let SettledInputs {
        mut market,
        account_registry,
        mut wrapper,
        sessions_config,
        config,
        root,
    } = begin_settled_tx(&mut fixture, SESSION);
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    assert_eq!(market.settled_order_payout(order_id), test_constants::mint_quantity());
    sessions::redeem_settled(
        &mut market,
        &account_registry,
        &mut wrapper,
        &sessions_config,
        &config,
        order_id,
        &root,
        clock,
        scenario.ctx(),
    );
    assert_eq!(
        wrapper.load_account().balance<USDC>(&root, clock),
        post_mint_balance + test_constants::mint_quantity(),
    );
    assert!(!predict_account::has_position(wrapper.load_account(), market_id, order_id));
    assert_eq!(event::events_by_type<order_events::SettledOrderRedeemed>().length(), ONE_EVENT);
    assert_eq!(
        sessions::session_expiration_ms(&wrapper, SESSION),
        option::some(SETTLEMENT_SESSION_EXPIRES_AT_MS),
    );
    return_settled_inputs(SettledInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        root,
    });
    finish_flow_fixture(fixture);
}

fun session_addresses(): vector<address> {
    vector[
        SESSION_ONE,
        SESSION_TWO,
        SESSION_THREE,
        SESSION_FOUR,
        SESSION_FIVE,
        SESSION_SIX,
        SESSION_SEVEN,
        SESSION_EIGHT,
        SESSION_NINE,
        SESSION_TEN,
        SESSION_ELEVEN,
        SESSION_TWELVE,
        SESSION_THIRTEEN,
        SESSION_FOURTEEN,
        SESSION_FIFTEEN,
        SESSION_SIXTEEN,
        SESSION_SEVENTEEN,
        SESSION_EIGHTEEN,
        SESSION_NINETEEN,
        SESSION_TWENTY,
        SESSION_TWENTY_ONE,
    ]
}

fun setup_account(): (Scenario, Clock, ID, ID) {
    let mut scenario = test::begin(ADMIN);
    account_registry::init_for_testing(scenario.ctx());
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(scenario.ctx());
    destroy(sessions_admin_cap);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    scenario.next_tx(ALICE);
    let mut registry = scenario.take_shared<AccountRegistry>();
    let wrapper = registry.new(scenario.ctx());
    let wrapper_id = wrapper.id();
    wrapper.share();
    return_shared(registry);
    scenario.next_tx(ADMIN);

    (scenario, clock, wrapper_id, sessions_config_id)
}

fun assert_session_authorized_event(
    actual: &SessionAuthorized,
    account_id: ID,
    session: address,
    expires_at_ms: u64,
) {
    let expected = ExpectedSessionAuthorized { account_id, session, expires_at_ms };
    assert_eq!(bcs::to_bytes(actual), bcs::to_bytes(&expected));
}

fun assert_session_revoked_event(
    actual: &SessionRevoked,
    account_id: ID,
    session: address,
    expires_at_ms: u64,
) {
    let expected = ExpectedSessionRevoked { account_id, session, expires_at_ms };
    assert_eq!(bcs::to_bytes(actual), bcs::to_bytes(&expected));
}

fun setup_flow_fixture(expiry_ms: u64): SessionFlowFixture {
    let (mut predict, market_id, trader) = predict_helpers::setup_live_market(
        expiry_ms,
        test_constants::default_live_price(),
    );
    predict.authorize_account_app<SessionsApp>();
    let owner = predict_helpers::owner(&trader);
    let (sessions_config_id, sessions_admin_cap) = session_config::init_for_testing(predict
        .scenario_mut()
        .ctx());
    destroy(sessions_admin_cap);
    let config_id = predict.config_id();
    let pyth_id = predict.pyth_id();
    let now_ms = predict.clock().timestamp_ms();
    let mut clock = clock::create_for_testing(predict.scenario_mut().ctx());
    clock.set_for_testing(now_ms);

    let account_registry = predict.scenario_mut().take_shared<AccountRegistry>();
    let wrapper_id = account_registry.derived_wrapper_address(owner).to_id();
    let oracle_registry = predict.scenario_mut().take_shared<OracleRegistry>();
    let bs_pair = oracle_registry
        .propbook_block_scholes_store_pair_for_underlying(
            test_constants::propbook_underlying_id(),
        )
        .destroy_some();
    let bs_values_id = bs_pair.block_scholes_value_store_id();
    let bs_svi_id = bs_pair.block_scholes_svi_store_id();
    return_shared(account_registry);
    return_shared(oracle_registry);
    predict.scenario_mut().next_tx(test_constants::admin());

    SessionFlowFixture {
        predict,
        clock,
        market_id,
        owner,
        wrapper_id,
        sessions_config_id,
        config_id,
        pyth_id,
        bs_values_id,
        bs_svi_id,
    }
}

fun authorize_flow_session(fixture: &mut SessionFlowFixture, duration_ms: u64) {
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    scenario.next_tx(fixture.owner);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(fixture.wrapper_id);
    let sessions_config = scenario.take_shared_by_id<SessionsConfig>(fixture.sessions_config_id);
    sessions::authorize_session(
        &mut wrapper,
        &sessions_config,
        SESSION,
        duration_ms,
        clock,
        scenario.ctx(),
    );
    return_shared(sessions_config);
    return_shared(wrapper);
    scenario.next_tx(test_constants::admin());
}

fun revoke_flow_session(fixture: &mut SessionFlowFixture) {
    let scenario = fixture.predict.scenario_mut();
    scenario.next_tx(fixture.owner);
    let mut wrapper = scenario.take_shared_by_id<AccountWrapper>(fixture.wrapper_id);
    sessions::revoke_session(&mut wrapper, SESSION, scenario.ctx());
    return_shared(wrapper);
    scenario.next_tx(test_constants::admin());
}

fun begin_live_tx(fixture: &mut SessionFlowFixture, sender: address): LiveInputs {
    let clock = &fixture.clock;
    let scenario = fixture.predict.scenario_mut();
    scenario.next_tx(sender);
    let market = scenario.take_shared_by_id<ExpiryMarket>(fixture.market_id);
    let config = scenario.take_shared_by_id<ProtocolConfig>(fixture.config_id);
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let pyth = scenario.take_shared_by_id<PythFeed>(fixture.pyth_id);
    let bs_values = scenario.take_shared_by_id<BlockScholesValueStore>(fixture.bs_values_id);
    let bs_svi = scenario.take_shared_by_id<BlockScholesSVIStore>(fixture.bs_svi_id);
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

    LiveInputs {
        market,
        account_registry: scenario.take_shared<AccountRegistry>(),
        wrapper: scenario.take_shared_by_id<AccountWrapper>(fixture.wrapper_id),
        sessions_config: scenario.take_shared_by_id<SessionsConfig>(fixture.sessions_config_id),
        config,
        pricer,
        root: scenario.take_shared<AccumulatorRoot>(),
    }
}

fun return_live_inputs(inputs: LiveInputs) {
    let LiveInputs {
        market,
        account_registry,
        wrapper,
        sessions_config,
        config,
        pricer: _,
        root,
    } = inputs;
    return_shared(market);
    return_shared(account_registry);
    return_shared(wrapper);
    return_shared(sessions_config);
    return_shared(config);
    return_shared(root);
}

fun begin_settled_tx(fixture: &mut SessionFlowFixture, sender: address): SettledInputs {
    let scenario = fixture.predict.scenario_mut();
    scenario.next_tx(sender);
    SettledInputs {
        market: scenario.take_shared_by_id<ExpiryMarket>(fixture.market_id),
        account_registry: scenario.take_shared<AccountRegistry>(),
        wrapper: scenario.take_shared_by_id<AccountWrapper>(fixture.wrapper_id),
        sessions_config: scenario.take_shared_by_id<SessionsConfig>(fixture.sessions_config_id),
        config: scenario.take_shared_by_id<ProtocolConfig>(fixture.config_id),
        root: scenario.take_shared<AccumulatorRoot>(),
    }
}

fun return_settled_inputs(inputs: SettledInputs) {
    let SettledInputs { market, account_registry, wrapper, sessions_config, config, root } = inputs;
    return_shared(market);
    return_shared(account_registry);
    return_shared(wrapper);
    return_shared(sessions_config);
    return_shared(config);
    return_shared(root);
}

fun settle_flow_market(fixture: &mut SessionFlowFixture, settlement_price: u64) {
    let expiry_ms = fixture.clock.timestamp_ms();
    fixture.predict.scenario_mut().next_tx(test_constants::admin());
    let mut pyth = fixture.predict.scenario_mut().take_shared_by_id<PythFeed>(fixture.pyth_id);
    fixture.predict.insert_exact_settlement_spot(&mut pyth, expiry_ms, settlement_price);
    return_shared(pyth);

    fixture.predict.scenario_mut().next_tx(test_constants::admin());
    let mut market = fixture
        .predict
        .scenario_mut()
        .take_shared_by_id<ExpiryMarket>(fixture.market_id);
    let config = fixture
        .predict
        .scenario_mut()
        .take_shared_by_id<ProtocolConfig>(fixture.config_id);
    let oracle_registry = fixture.predict.scenario_mut().take_shared<OracleRegistry>();
    let pyth = fixture.predict.scenario_mut().take_shared_by_id<PythFeed>(fixture.pyth_id);
    let bs_values = fixture
        .predict
        .scenario_mut()
        .take_shared_by_id<BlockScholesValueStore>(fixture.bs_values_id);
    assert_eq!(
        market.try_settle(&config, &oracle_registry, &pyth, &bs_values, &fixture.clock),
        true,
    );
    assert_eq!(market.try_settlement_price(), option::some(settlement_price));
    return_shared(market);
    return_shared(config);
    return_shared(oracle_registry);
    return_shared(pyth);
    return_shared(bs_values);
    fixture.predict.scenario_mut().next_tx(test_constants::admin());
}

fun finish_flow_fixture(fixture: SessionFlowFixture) {
    let SessionFlowFixture {
        predict,
        clock,
        market_id: _,
        owner: _,
        wrapper_id: _,
        sessions_config_id: _,
        config_id: _,
        pyth_id: _,
        bs_values_id: _,
        bs_svi_id: _,
    } = fixture;
    clock.destroy_for_testing();
    predict.finish();
}
