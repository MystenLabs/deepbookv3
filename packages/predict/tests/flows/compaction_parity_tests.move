// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// P0-8 compaction parity (METAMORPHIC: the parity asserts compare the two
/// paths to each other, not to an independent oracle — the independent anchors
/// are the boundary payouts and the floor-chain constants). Two expiry markets
/// in one fixture receive bit-identical order books (same args, same
/// time-to-expiry at mint, same oracle inputs, same 110e9 settlement); path B
/// additionally runs `compact_storage` after the settled sync. Pins that
/// compaction moves no cash and changes no liability, that per-order settled
/// payouts are bit-equal with and without compaction (orders stay closable
/// post-compaction), that the settled reserve drains to exactly zero on both
/// paths, and that both expiries end as pure payout+rebate escrow (cash ==
/// rebate reserve, no free LP cash stranded).
#[test_only]
module deepbook_predict::compaction_parity_tests;

use deepbook_predict::{
    config_constants,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    market_oracle::MarketOracle,
    plp,
    predict_manager::PredictManager,
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use predict_math::math;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

const EXPIRY_A_MS: u64 = 200_000;
const EXPIRY_B_MS: u64 = 300_000;
/// B's mints run at clock 200_000 so its time-to-expiry (100_000 ms) equals
/// A's at its mints — every economic term (entry probability, fee, floor
/// index, floor shares, terminal payout) depends only on (expiry − now), so
/// the two books are bit-identical by construction.
const B_MINT_CLOCK_MS: u64 = 200_000;
const B_RESEED_SOURCE_TS: u64 = 199_000;
/// Extra idle so both expiries can be independently funded to the cash floor.
const EXTRA_IDLE: u64 = 250_000_000_000;
/// Covers two identical 1_265e6 mint phases with headroom.
const MANAGER_DEPOSIT: u64 = 4_000_000_000;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// ATM digital p = Φ(0) = 0.5 exactly for both the UP and the complement DOWN
/// range; 1x net_premium = floor(0.5 * 1e9); 2x = floor(entry_value / 2).
const ONE_X_CONTRIBUTION: u64 = 500_000_000;
const TWO_X_CONTRIBUTION: u64 = 250_000_000;
/// Per-trade fee floors at min_fee (fixture base_fee = 1; default
/// max-multiplier 1.0 keeps the short-expiry ramp inert).
const MINT_MIN_FEE: u64 = 5_000_000;
/// floor(3 * 5e6 fee basis * 0.5 default rebate rate) per market.
const REBATE_PER_MARKET: u64 = 7_500_000;
/// Σ(quantity − floor_at_open): two zero-floor 1x orders contribute 1e9 each;
/// the 2x order's floor chain (phase 999_996_829 → phase² 999_993_658 →
/// index_open 1_199_998_731 → floor_shares 208_333_553 → floor_at_open
/// 249_999_999) leaves backing 750_000_001.
const SUMMED_LIVE_BACKING_PER_MARKET: u64 = 2_750_000_001;
/// Max point floor is the two UP winners (1e9 + 750_000_001); the disjoint
/// DOWN loser contributes a 1e9 gap, so default reserve is 2_000_000_001.
const MAX_LIVE_BACKING_PER_MARKET: u64 = 1_750_000_001;
const DISJOINT_GAP_PER_MARKET: u64 = SUMMED_LIVE_BACKING_PER_MARKET - MAX_LIVE_BACKING_PER_MARKET;
/// ITM for [min_strike, +inf), OTM for (-inf, min_strike].
const SETTLEMENT_ITM: u64 = 110_000_000_000;
/// Exact terminal liability at 110e9: 1x winner 1e9 + 1x loser 0 + 2x winner
/// (1e9 − floor(208_333_553 * 1.2e9 / 1e9) = 1e9 − 250_000_263).
const TWO_X_SETTLED_PAYOUT: u64 = 749_999_737;
const TERMINAL_LIABILITY_PER_MARKET: u64 = 1_749_999_737;

#[test]
fun settled_redeems_are_bit_equal_with_and_without_compaction() {
    let mut fx = helpers::setup_market_default();
    fx.add_idle_supply_before_expiries(EXTRA_IDLE);
    // Both markets must be created BEFORE the live re-seed: grid centering
    // reads the creation-time pyth spot, and parity needs identical grids.
    let (expiry_a, oracle_a_id) = fx.create_expiry(EXPIRY_A_MS);
    let (expiry_b, oracle_b_id) = fx.create_expiry(EXPIRY_B_MS);
    let mut manager = fx.create_funded_manager(MANAGER_DEPOSIT);
    let (mut pyth, mut vault, mut market_a, mut oracle_a, mut config) = fx.take_market(
        expiry_a,
        oracle_a_id,
    );
    let mut market_b = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_b);
    let mut oracle_b = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);
    fx.prepare_live_oracle(&config, &mut oracle_a, &mut pyth, test_constants::default_live_price());
    fx.prepare_live_oracle(&config, &mut oracle_b, &mut pyth, test_constants::default_live_price());

    // --- Funding sync over both expiries: each topped to the cash floor.
    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    vault.finish_pool_sync(&mut config, sync);
    let cash_floor = constants::expiry_cash_floor!();
    let total_supply = test_constants::default_initial_supply() + EXTRA_IDLE;
    let idle_after_funding = total_supply - 2 * cash_floor;
    assert_eq!(market_a.cash_balance(), cash_floor);
    assert_eq!(market_b.cash_balance(), cash_floor);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(idle_after_funding, total_supply, 0),
    );
    assert!(vault.active_expiry_markets().contains(&expiry_a));
    assert!(vault.active_expiry_markets().contains(&expiry_b));

    // --- Identical mint phase into A (clock 100_000, tte 100_000 ms): 1x
    // winner, 1x loser (strictly OTM at the settlement), 2x leveraged winner.
    let orders_a = mint_three(&mut fx, &config, &mut manager, &mut market_a, &oracle_a, &pyth);
    let spend_per_market = 2 * ONE_X_CONTRIBUTION + TWO_X_CONTRIBUTION + 3 * MINT_MIN_FEE;
    let cash_after_mints = cash_floor + spend_per_market;
    assert_eq!(manager.balance(), MANAGER_DEPOSIT - spend_per_market);
    assert_eq!(manager.trading_fees_paid(expiry_a), 3 * MINT_MIN_FEE);
    helpers::check_market_cash(
        &market_a,
        helpers::expected_market_cash(
            cash_after_mints,
            buffered_live_reserve_per_market(),
            REBATE_PER_MARKET,
        ),
    );

    // --- Identical mint phase into B at equal time-to-expiry.
    fx.set_clock_for_testing(B_MINT_CLOCK_MS);
    fx.prepare_live_oracle_at(
        &config,
        &mut oracle_b,
        &mut pyth,
        test_constants::default_live_price(),
        B_RESEED_SOURCE_TS,
    );
    let orders_b = mint_three(&mut fx, &config, &mut manager, &mut market_b, &oracle_b, &pyth);
    assert_eq!(manager.balance(), MANAGER_DEPOSIT - 2 * spend_per_market);
    assert_eq!(manager.trading_fees_paid(expiry_b), manager.trading_fees_paid(expiry_a));
    assert_eq!(market_b.payout_liability(), market_a.payout_liability());

    // --- Settle both at the same exact price, then one settled sync over
    // both: the sync deactivates each expiry and releases all cash above the
    // settled liability + rebate reserve back to idle — identically on both
    // paths, BEFORE the divergence.
    fx.settle_oracle(&config, &mut oracle_a, &mut pyth, SETTLEMENT_ITM);
    fx.settle_oracle(&config, &mut oracle_b, &mut pyth, SETTLEMENT_ITM);
    let mut sync = plp::start_pool_sync(&mut config, &vault);
    sync.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    vault.finish_pool_sync(&mut config, sync);
    let escrow_cash = TERMINAL_LIABILITY_PER_MARKET + REBATE_PER_MARKET;
    let released_per_market = cash_after_mints - escrow_cash;
    assert_eq!(market_a.payout_liability(), TERMINAL_LIABILITY_PER_MARKET);
    assert_eq!(market_b.payout_liability(), TERMINAL_LIABILITY_PER_MARKET);
    assert_eq!(market_a.cash_balance(), escrow_cash);
    assert_eq!(market_b.cash_balance(), escrow_cash);
    assert!(!vault.active_expiry_markets().contains(&expiry_a));
    assert!(!vault.active_expiry_markets().contains(&expiry_b));
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            idle_after_funding + 2 * released_per_market,
            total_supply,
            0,
        ),
    );
    let (sent_a, received_a) = vault.expiry_flow_amounts(expiry_a);
    let (sent_b, received_b) = vault.expiry_flow_amounts(expiry_b);
    assert_eq!(sent_a, cash_floor);
    assert_eq!(received_a, released_per_market);
    assert_eq!(sent_b, sent_a);
    assert_eq!(received_b, received_a);

    // --- DIVERGENCE: compact path B only. Compaction is pure index
    // destruction — no cash moves, no liability change.
    fx.compact_storage(&config, &mut market_b, &oracle_b);
    assert_eq!(market_b.payout_liability(), TERMINAL_LIABILITY_PER_MARKET);
    assert_eq!(market_b.cash_balance(), escrow_cash);

    // --- Redeem all orders in the same sequence on both paths and compare
    // the per-order payouts bit-for-bit. The independent anchors: the 1x
    // winner pays full notional, the strictly-OTM loser pays zero, the 2x
    // winner pays quantity minus its terminal floor.
    let payouts_a = redeem_all_settled(
        &mut fx,
        &config,
        &mut manager,
        &mut market_a,
        &oracle_a,
        &pyth,
        orders_a,
    );
    let payouts_b = redeem_all_settled(
        &mut fx,
        &config,
        &mut manager,
        &mut market_b,
        &oracle_b,
        &pyth,
        orders_b,
    );
    assert_eq!(payouts_a, vector[test_constants::mint_quantity(), 0, TWO_X_SETTLED_PAYOUT]);
    assert_eq!(payouts_b, payouts_a);

    // --- Final sheets, bit-equal: the settled reserve drained to exactly
    // zero on both paths, and each expiry holds exactly its unresolved rebate
    // reserve (payout+rebate escrow only — no stranded LP cash). Neither
    // compaction nor the settled redeems moved pool cash.
    assert_eq!(market_a.payout_liability(), 0);
    assert_eq!(market_b.payout_liability(), 0);
    helpers::check_market_cash(
        &market_a,
        helpers::expected_market_cash(REBATE_PER_MARKET, 0, REBATE_PER_MARKET),
    );
    helpers::check_market_cash(
        &market_b,
        helpers::expected_market_cash(REBATE_PER_MARKET, 0, REBATE_PER_MARKET),
    );
    assert_eq!(manager.expiry_position_count(expiry_a), 0);
    assert_eq!(manager.expiry_position_count(expiry_b), 0);
    assert_eq!(
        manager.balance(),
        MANAGER_DEPOSIT - 2 * spend_per_market + 2 * TERMINAL_LIABILITY_PER_MARKET,
    );
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            idle_after_funding + 2 * released_per_market,
            total_supply,
            0,
        ),
    );

    return_shared(oracle_b);
    return_shared(market_b);
    helpers::return_market(pyth, vault, market_a, oracle_a, config);
    destroy(manager);
    fx.finish();
}

/// The identical three-order book minted into one market: 1x UP winner,
/// 1x DOWN loser, 2x leveraged UP winner — all quantity `mint_quantity()`.
fun mint_three(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
): vector<u256> {
    let winner_1x = fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let loser_1x = fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        constants::neg_inf!(),
        helpers::min_strike(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let winner_2x = fx.mint(
        config,
        manager,
        market,
        oracle,
        pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );
    vector[winner_1x, loser_1x, winner_2x]
}

/// Fully close every order via the permissionless settled redeem, asserting
/// the backing invariant after each, and return the per-order payout deltas.
fun redeem_all_settled(
    fx: &mut helpers::Fixture,
    config: &ProtocolConfig,
    manager: &mut PredictManager,
    market: &mut ExpiryMarket,
    oracle: &MarketOracle,
    pyth: &PythSource,
    orders: vector<u256>,
): vector<u64> {
    let mut payouts = vector[];
    orders.do!(|order_id| {
        let before = manager.balance();
        fx.redeem_settled(
            config,
            manager,
            market,
            oracle,
            pyth,
            order_id,
            test_constants::mint_quantity(),
        );
        helpers::assert_market_backed(market);
        payouts.push_back(manager.balance() - before);
    });
    payouts
}

fun buffered_live_reserve_per_market(): u64 {
    // M + λ(Σ − M) = 1_750_000_001 + 0.25 * 1_000_000_000 = 2_000_000_001.
    MAX_LIVE_BACKING_PER_MARKET
        + math::mul(config_constants::default_backing_buffer_lambda!(), DISJOINT_GAP_PER_MARKET)
}
