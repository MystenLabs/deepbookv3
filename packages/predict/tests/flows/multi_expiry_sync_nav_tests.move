// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// S4/A2 multi-expiry sync NAV conservation + ledger flow watermarks: a pool
/// funds TWO expiries, one trader mints in expiry A only, then four full
/// multi-expiry syncs run around a supply/withdraw round-trip. Pins the exact
/// pool value returned by `finish_pool_sync` (deposits + trader inflow −
/// marked liability − rebate reserve − pending protocol share), that every
/// pool↔expiry cash delta appears in `expiry_flow_amounts` exactly once (the
/// floor top-up and the single post-trade sweep), and the NAV-directional
/// round-trip: withdrawing the freshly-supplied shares returns strictly less
/// than the payment (no free round-trip; dust stays in idle).
#[test_only]
module deepbook_predict::multi_expiry_sync_nav_tests;

use deepbook_predict::{
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    plp,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

/// Second supply before registering the expiries: registration asserts the
/// pool earmark idle >= Σ(per-expiry funding cap − net funded), and two
/// expiries at the default 250_000e6 cap need more than the 300_000e6
/// bootstrap idle. Priced at NAV 1.0 (idle-only pool), so shares == payment
/// exactly under any rounding order.
const HEADROOM_SUPPLY: u64 = 300_000_000_000;
/// Expiry B ≈ 364 days out — far enough for a flat floor schedule, carries no
/// orders.
const EXPIRY_B_MS: u64 = 31_449_700_000;
/// ATM 1x mint in expiry A: p = Φ(0) = 0.5 exactly, premium = floor(0.5 * 1e9),
/// fee floors at min_fee (fixture base_fee = 1, ramp multiplier exactly 1.0).
const MINT_PRINCIPAL: u64 = 500_000_000;
const MINT_MIN_FEE: u64 = 5_000_000;
/// floor(5e6 fee basis * 0.5 default rebate rate).
const MINT_REBATE: u64 = 2_500_000;
/// The expiry-NAV mark for the open order: range value − floor
/// = mul(1e9, 0.5) − 0. (Numerically equal to the premium because p = 0.5.)
const POSITION_LIABILITY_MARK: u64 = 500_000_000;
/// Pending protocol-profit exclusion at the synced mark: marked profit
/// = trader inflow 505e6 − liability mark 500e6 − rebate 2.5e6 = 2_500_000;
/// exclusion = floor(2.5e6 * 0.4 fixture reserve share) = 1_000_000.
const PENDING_PROTOCOL_SHARE: u64 = 1_000_000;
/// Supply payment chosen so every multiply/divide order agrees on the share
/// count: ratio = floor(600_000e6 * 1e9 / 600_001_500_000) = 999_997_500;
/// shares = floor(4e9 * ratio / 1e9) = 3_999_990_000 (== full-precision floor).
const SUPPLY_PAYMENT: u64 = 4_000_000_000;
const SUPPLY_SHARES: u64 = 3_999_990_000;
/// Withdraw of the same shares (divide then multiply, rounding down):
/// ratio = floor(3_999_990_000 * 1e9 / 603_999_990_000) = 6_622_500;
/// gross = floor(604_001_500_000 * ratio / 1e9) = 3_999_999_933. The
/// uncertainty-band withdraw fee is zero for a fully-verified 1x-only book
/// (zero aggregate floor exposure), so net == gross — still < the payment.
const WITHDRAW_PROCEEDS: u64 = 3_999_999_933;

#[test]
fun two_expiry_sync_conserves_nav_and_counts_each_flow_once() {
    let mut fx = helpers::setup_market_default();
    fx.add_idle_supply_before_expiries(HEADROOM_SUPPLY);
    let (expiry_a_id, oracle_a_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let (expiry_b_id, oracle_b_id) = fx.create_expiry(EXPIRY_B_MS);
    let mut manager = fx.create_funded_manager(test_constants::mint_deposit());

    let (mut pyth, mut vault, mut market_a, mut oracle_a, mut config) = fx.take_market(
        expiry_a_id,
        oracle_a_id,
    );
    let mut market_b = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_b_id);
    let mut oracle_b = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);
    fx.prepare_live_oracle(&config, &mut oracle_a, &mut pyth, test_constants::default_live_price());
    fx.prepare_live_oracle(&config, &mut oracle_b, &mut pyth, test_constants::default_live_price());

    let total_deposits = test_constants::default_initial_supply() + HEADROOM_SUPPLY;
    let cash_floor = constants::expiry_cash_floor!();

    // --- Sync #1 (funding): registration moved no cash, so the first
    // rebalance tops each expiry from 0 to the cash floor. Funding moves cash,
    // not value: the returned pool value equals total deposits exactly.
    let mut sync1 = plp::start_pool_sync(&mut config, &vault);
    sync1.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync1.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let pool_value_1 = vault.finish_pool_sync(&mut config, sync1);
    assert_eq!(pool_value_1, total_deposits);
    let idle_after_funding = total_deposits - 2 * cash_floor;
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(idle_after_funding, total_deposits, 0),
    );
    let (sent_a, received_a) = vault.expiry_flow_amounts(expiry_a_id);
    assert_eq!(sent_a, cash_floor);
    assert_eq!(received_a, 0);
    let (sent_b, received_b) = vault.expiry_flow_amounts(expiry_b_id);
    assert_eq!(sent_b, cash_floor);
    assert_eq!(received_b, 0);
    helpers::check_market_cash(&market_a, helpers::expected_market_cash(cash_floor, 0, 0));
    helpers::check_market_cash(&market_b, helpers::expected_market_cash(cash_floor, 0, 0));

    // --- One 1x ATM mint in expiry A only. Trader cash enters expiry custody
    // directly — it is NOT a pool→expiry ledger flow (negative control).
    let _order_id = fx.mint(
        &config,
        &mut manager,
        &mut market_a,
        &oracle_a,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    helpers::check_manager(
        &manager,
        expiry_a_id,
        helpers::expected_manager_state(
            test_constants::mint_deposit() - MINT_PRINCIPAL - MINT_MIN_FEE,
            MINT_MIN_FEE,
            1,
            0,
            0,
        ),
    );
    helpers::check_market_cash(
        &market_a,
        helpers::expected_market_cash(
            cash_floor + MINT_PRINCIPAL + MINT_MIN_FEE,
            test_constants::mint_quantity(),
            MINT_REBATE,
        ),
    );
    let (sent_a, received_a) = vault.expiry_flow_amounts(expiry_a_id);
    assert_eq!(sent_a, cash_floor);
    assert_eq!(received_a, 0);

    // --- Sync #2: A's surplus over the floor (principal + fee) sweeps back to
    // idle, counted exactly once in `received`; B is untouched. The returned
    // pool value conserves: deposits + trader inflow − liability mark − rebate
    // reserve − pending protocol share.
    let trader_inflow = MINT_PRINCIPAL + MINT_MIN_FEE;
    let mut sync2 = plp::start_pool_sync(&mut config, &vault);
    sync2.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync2.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let pool_value_2 = vault.finish_pool_sync(&mut config, sync2);
    assert_eq!(
        pool_value_2,
        total_deposits + trader_inflow - POSITION_LIABILITY_MARK - MINT_REBATE
            - PENDING_PROTOCOL_SHARE,
    );
    let idle_after_sweep = idle_after_funding + trader_inflow;
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(idle_after_sweep, total_deposits, 0),
    );
    let (sent_a, received_a) = vault.expiry_flow_amounts(expiry_a_id);
    assert_eq!(sent_a, cash_floor);
    assert_eq!(received_a, trader_inflow);
    let (sent_b, received_b) = vault.expiry_flow_amounts(expiry_b_id);
    assert_eq!(sent_b, cash_floor);
    assert_eq!(received_b, 0);
    helpers::check_market_cash(
        &market_a,
        helpers::expected_market_cash(
            cash_floor,
            test_constants::mint_quantity(),
            MINT_REBATE,
        ),
    );

    // --- Sync #3 + supply at the synced mark. Both rebalances are no-ops
    // (cash == target), so the mark is identical to sync #2's; the supply
    // joins idle only and the expiry watermarks are unchanged.
    let mut sync3 = plp::start_pool_sync(&mut config, &vault);
    sync3.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync3.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let plp_coin = fx.supply(&mut config, &mut vault, sync3, &pyth, SUPPLY_PAYMENT);
    assert_eq!(plp_coin.value(), SUPPLY_SHARES);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            idle_after_sweep + SUPPLY_PAYMENT,
            total_deposits + SUPPLY_SHARES,
            0,
        ),
    );

    // --- Sync #4 + withdraw the same shares. Proceeds are strictly below the
    // supply payment (withdraw_NAV <= supply_NAV — no free round-trip); the
    // dust stays in idle for remaining LPs; watermarks are stable across all
    // four syncs.
    let mut sync4 = plp::start_pool_sync(&mut config, &vault);
    sync4.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync4.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let (dusdc, sui, deep) = fx.withdraw(&mut config, &mut vault, sync4, plp_coin);
    assert_eq!(dusdc.value(), WITHDRAW_PROCEEDS);
    assert!(dusdc.value() <= SUPPLY_PAYMENT);
    assert_eq!(sui.value(), 0);
    assert_eq!(deep.value(), 0);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            idle_after_sweep + SUPPLY_PAYMENT - WITHDRAW_PROCEEDS,
            total_deposits,
            0,
        ),
    );
    let (sent_a, received_a) = vault.expiry_flow_amounts(expiry_a_id);
    assert_eq!(sent_a, cash_floor);
    assert_eq!(received_a, trader_inflow);
    let (sent_b, received_b) = vault.expiry_flow_amounts(expiry_b_id);
    assert_eq!(sent_b, cash_floor);
    assert_eq!(received_b, 0);

    destroy(dusdc);
    destroy(sui);
    destroy(deep);
    return_shared(oracle_b);
    return_shared(market_b);
    helpers::return_market(pyth, vault, market_a, oracle_a, config);
    destroy(manager);
    fx.finish();
}
