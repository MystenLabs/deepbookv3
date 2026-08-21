// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end coverage for mint referral distribution: the split comes out of
/// protocol proceeds without changing the trader quote, uses the live config
/// rate, excludes sponsor subsidy and builder fees, includes congestion, and
/// preserves the referrer's immutable Account identity and routing snapshot.
#[test_only]
module deepbook_predict::referral_fee_flow_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    order_events,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::{bcs, unit_test::assert_eq};
use sui::event;

const MIN_TRADING_FEE: u64 = 5_000_000;
const DEFAULT_REFERRAL_FEE: u64 = 500_000;
const SUBSIDY_AT_RATE_CAP: u64 = 1_000_000;
const SUBSIDIZED_REFERRAL_FEE: u64 = 400_000;
const BUILDER_FEE_ATM: u64 = 500_000;
const BUILDER_CODE_INDEX: u64 = 0;
const ROUNDING_TO_ZERO_RATE: u64 = 1;
const EWMA_PENALTY_FLAT: u64 = 1_000_000;
const VARIANCE_SEED_QUANTITY: u64 = 100_000_000;
const VARIANCE_SEED_TRADING_FEE: u64 = 500_000;
const VARIANCE_SEED_REFERRAL_FEE: u64 = 50_000;
const CONGESTED_REFERRAL_FEE: u64 = 600_000;
const GAS_SEED: u64 = 2_000;
const GAS_SPIKE: u64 = 3_000;
const SPIKE_MS: u64 = 121_000;
const SPIKE_SOURCE_TS: u64 = 120_000;
const ONE_EVENT: u64 = 1;

/// BCS mirror used to assert the public event schema without adding production
/// getters solely for tests.
public struct ExpectedOrderMinted has copy, drop {
    expiry_market_id: ID,
    account_id: ID,
    order_id: u256,
    position_root_id: u256,
    owner: address,
    lower_tick: u64,
    higher_tick: u64,
    entry_probability: u64,
    quantity: u64,
    premium: u64,
    trading_fee: u64,
    fee_incentive_subsidy: u64,
    builder_fee: u64,
    penalty_fee: u64,
    referral_fee: u64,
    inventory_impact_charge: u64,
    skew_charge: u64,
    skew_rebate: u64,
    builder_code_id: Option<ID>,
    referrer_account_id: Option<ID>,
    onchain_timestamp_ms: u64,
    pyth_spot_source_timestamp_ms: u64,
    block_scholes_spot_source_timestamp_ms: u64,
    block_scholes_forward_source_timestamp_ms: u64,
    block_scholes_svi_source_timestamp_ms: u64,
}

#[test]
fun default_rate_routes_protocol_fee_without_changing_trader_cost() {
    let (mut fx, expiry_id, trader, referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let referrer_account_id = trader_account_id(&mut fx, &referrer);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    let quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    helpers::assert_atm_entry_probability(quote.entry_probability());
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.all_in_cost(), quote.premium() + MIN_TRADING_FEE);

    let trader_balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let market_cash_before = helpers::market(&market).cash_balance();
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert!(helpers::has_position_bundle(&account, expiry_id, order_id));
    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        trader_balance_before - quote.all_in_cost(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        market_cash_before + quote.premium() + MIN_TRADING_FEE - DEFAULT_REFERRAL_FEE,
    );
    let events = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedOrderMinted {
        expiry_market_id: expiry_id,
        account_id,
        order_id,
        position_root_id: order_id,
        owner: helpers::owner(&trader),
        lower_tick: helpers::strike_tick(),
        higher_tick: constants::pos_inf_tick!(),
        entry_probability: quote.entry_probability(),
        quantity: test_constants::mint_quantity(),
        premium: quote.premium(),
        trading_fee: MIN_TRADING_FEE,
        fee_incentive_subsidy: 0,
        builder_fee: 0,
        penalty_fee: 0,
        referral_fee: DEFAULT_REFERRAL_FEE,
        inventory_impact_charge: 0,
        skew_charge: 0,
        skew_rebate: 0,
        builder_code_id: option::none(),
        referrer_account_id: option::some(referrer_account_id),
        onchain_timestamp_ms: test_constants::now_ms(),
        pyth_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun rounded_zero_fee_keeps_referrer_event_attribution() {
    let (mut fx, expiry_id, trader, referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    let referrer_account_id = trader_account_id(&mut fx, &referrer);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let account_id = helpers::account_id_bundle(&account);

    // The market and both Accounts already exist. Reading this new rate at mint
    // proves it is live protocol config rather than a market/Account snapshot.
    fx.set_referral_fee_rate_bundle(&mut market, ROUNDING_TO_ZERO_RATE);
    let quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    // floor(5_000_000 * 1 / 1_000_000_000) = 0.
    let order_id = fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    let events = event::events_by_type<order_events::OrderMinted>();
    assert_eq!(events.length(), ONE_EVENT);
    let expected = ExpectedOrderMinted {
        expiry_market_id: expiry_id,
        account_id,
        order_id,
        position_root_id: order_id,
        owner: helpers::owner(&trader),
        lower_tick: helpers::strike_tick(),
        higher_tick: constants::pos_inf_tick!(),
        entry_probability: quote.entry_probability(),
        quantity: test_constants::mint_quantity(),
        premium: quote.premium(),
        trading_fee: MIN_TRADING_FEE,
        fee_incentive_subsidy: 0,
        builder_fee: 0,
        penalty_fee: 0,
        referral_fee: 0,
        inventory_impact_charge: 0,
        skew_charge: 0,
        skew_rebate: 0,
        builder_code_id: option::none(),
        referrer_account_id: option::some(referrer_account_id),
        onchain_timestamp_ms: test_constants::now_ms(),
        pyth_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_spot_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_forward_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
        block_scholes_svi_source_timestamp_ms: test_constants::live_source_timestamp_ms(),
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&expected));
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun sponsor_and_builder_are_excluded_from_referral_basis() {
    let (mut fx, expiry_id, trader, _referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.create_and_link_builder_code(BUILDER_CODE_INDEX, &trader);
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.sponsor_fee_incentives_bundle(&mut market, constants::min_fee_incentive_sponsorship!());
    fx.rebalance_expiry_cash_bundle(&mut market);

    let quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.fee_incentive_subsidy(), SUBSIDY_AT_RATE_CAP);
    assert_eq!(quote.builder_fee(), BUILDER_FEE_ATM);
    let trader_balance_before = fx.account_balance_bundle<DUSDC>(&account);
    let market_cash_before = helpers::market(&market).cash_balance();

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );

    assert_eq!(
        fx.account_balance_bundle<DUSDC>(&account),
        trader_balance_before - quote.all_in_cost(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        market_cash_before + quote.premium() + MIN_TRADING_FEE - SUBSIDIZED_REFERRAL_FEE,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun congestion_surcharge_is_included_in_referral_basis() {
    let (mut fx, expiry_id, trader, _referrer) = helpers::setup_referred_live_market(
        test_constants::default_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let mut market = fx.take_market_bundle(expiry_id);
    fx.set_ewma_penalty_bundle(
        &mut market,
        config_constants::default_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    helpers::return_market_bundle(market);

    let epoch_timestamp_ms = fx.scenario_mut().ctx().epoch_timestamp_ms();
    let seed_ctx = fx
        .scenario_mut()
        .ctx_builder()
        .set_gas_price(GAS_SEED)
        .set_epoch_timestamp(epoch_timestamp_ms);
    fx.scenario_mut().next_with_context(seed_ctx);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    let seed_quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        VARIANCE_SEED_QUANTITY,
    );
    assert_eq!(seed_quote.trading_fee(), VARIANCE_SEED_TRADING_FEE);
    assert_eq!(seed_quote.penalty_fee(), 0);
    let seed_cash_before = helpers::market(&market).cash_balance();
    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        VARIANCE_SEED_QUANTITY,
        std::u64::max_value!(),
        std::u64::max_value!(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        seed_cash_before
            + seed_quote.premium()
            + VARIANCE_SEED_TRADING_FEE
            - VARIANCE_SEED_REFERRAL_FEE,
    );
    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);

    fx.set_clock_for_testing(SPIKE_MS);
    let spike_ctx = fx
        .scenario_mut()
        .ctx_builder()
        .set_gas_price(GAS_SPIKE)
        .set_epoch_timestamp(epoch_timestamp_ms);
    fx.scenario_mut().next_with_context(spike_ctx);
    let mut market = fx.take_market_bundle(expiry_id);
    let mut account = fx.take_account_bundle(&trader);
    fx.prepare_live_oracle_bundle_at(
        &mut market,
        test_constants::default_live_price(),
        SPIKE_SOURCE_TS,
    );
    let quote = fx.quote_mint_for_account_bundle(
        &market,
        &account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
    );
    assert_eq!(quote.trading_fee(), MIN_TRADING_FEE);
    assert_eq!(quote.penalty_fee(), EWMA_PENALTY_FLAT);
    let spike_cash_before = helpers::market(&market).cash_balance();

    fx.mint_exact_quantity_bundle(
        &mut market,
        &mut account,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        quote.all_in_cost(),
        std::u64::max_value!(),
    );
    assert_eq!(
        helpers::market(&market).cash_balance(),
        spike_cash_before
            + quote.premium()
            + MIN_TRADING_FEE
            + EWMA_PENALTY_FLAT
            - CONGESTED_REFERRAL_FEE,
    );
    helpers::assert_market_backed_bundle(&market);

    helpers::return_account_bundle(account);
    helpers::return_market_bundle(market);
    fx.finish();
}

fun trader_account_id(fx: &mut helpers::Fixture, trader: &helpers::Trader): ID {
    fx.scenario_mut().next_tx(helpers::owner(trader));
    let account = fx.take_account_bundle(trader);
    let account_id = helpers::account_id_bundle(&account);
    helpers::return_account_bundle(account);
    account_id
}
