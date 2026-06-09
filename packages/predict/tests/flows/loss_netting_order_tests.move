// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Decision-pinned (2026-06-09): the protocol profit take depends on expiry
/// settlement order BY DESIGN. Loss netting is forward-only
/// (`pool_accounting::net_losses_to_fill`): a terminal loss only nets against
/// profits that materialize AFTER it, while already-materialized profit (and
/// the protocol's share of it) is never clawed back by a later loss. Two
/// mirrored two-expiry scenarios run the SAME trades — one worthless 1x order
/// (505e6 pool profit) and one winning 1x order (495e6 pool loss) — and differ
/// only in which expiry settles first. The pinned takes: profit-first
/// 0.4 × 505e6 = 202e6; loss-first 0.4 × (505e6 − 495e6) = 4e6.
#[test_only]
module deepbook_predict::loss_netting_order_tests;

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

/// Registration earmarks the default 250_000e6 funding cap per expiry; two
/// expiries need >= 500_000e6 idle backing, so a second 300_000e6 supply joins
/// the 300_000e6 bootstrap (mirrors `multi_expiry_sync_nav_tests`).
const HEADROOM_SUPPLY: u64 = 300_000_000_000;
/// Both supplies priced 1:1 on an idle-only pool.
const TOTAL_SUPPLY: u64 = 600_000_000_000;
/// ITM settlement for a `(min_strike, +inf]` order: strictly above min_strike.
/// (The worthless settlement is `min_strike` itself — the half-open range
/// excludes its lower bound.)
const SETTLEMENT_ITM: u64 = 110_000_000_000;

// Per-expiry economics (identical in both orderings):
// - worthless expiry pool profit = the trader's full inflow,
//   premium floor(0.5 * 1e9) + min fee 5e6 = 505e6, returned to the pool as a
//   502.5e6 settled release (505e6 minus the 2.5e6 rebate reserve) plus the
//   2.5e6 zero-rebate claim residual;
// - winning expiry pool loss = payout 1e9 − premium 500e6 − fee 5e6 = 495e6,
//   booked as a 497.5e6 release-time loss (50_000e6 funded − 49_502.5e6
//   returned) minus the winner's 2.5e6 claim residual.
// Protocol share is the 0.4 fixture `protocol_reserve_share`.

/// Profit-first: each profit chunk materializes in full (no prior loss to
/// fill): floor(502_500_000 * 0.4) = 201_000_000 at the settled release...
const PROFIT_FIRST_RESERVE_AFTER_RELEASE: u64 = 201_000_000;
/// ...plus floor(2_500_000 * 0.4) = 1_000_000 at the claim residual. The later
/// 495e6 loss only parks in `net_losses_to_fill` — the take never shrinks.
const PROFIT_FIRST_PROTOCOL_TAKE: u64 = 202_000_000;

/// Loss-first: the 497.5e6 release-time loss is reduced to 495e6 by the
/// winner's claim residual, then the later profit nets against it first:
/// floor((502_500_000 − 495_000_000) * 0.4) = 3_000_000 at the release...
const LOSS_FIRST_RESERVE_AFTER_RELEASE: u64 = 3_000_000;
/// ...plus floor(2_500_000 * 0.4) = 1_000_000 at the claim residual.
const LOSS_FIRST_PROTOCOL_TAKE: u64 = 4_000_000;

/// Closed-system pool cash: deposits 600_000e6 + the two traders' inflows
/// 2 × 505e6 − the winner's 1_000e6 payout = 600_010e6, ending entirely in
/// pool idle + protocol reserve (both expiries drain to zero).
const TOTAL_POOL_CASH: u64 = 600_010_000_000;
/// The traders deposit 2 × 1e9; the loser nets −505e6 and the winner +495e6:
/// 2_000_000_000 − 505_000_000 + 495_000_000 = 1_990_000_000.
const TRADERS_FINAL_TOTAL: u64 = 1_990_000_000;

#[test]
fun profit_first_settlement_protocol_takes_share_of_gross_profit() {
    run_two_expiry_settlements(
        helpers::min_strike(),
        SETTLEMENT_ITM,
        PROFIT_FIRST_RESERVE_AFTER_RELEASE,
        PROFIT_FIRST_PROTOCOL_TAKE,
        PROFIT_FIRST_PROTOCOL_TAKE,
        PROFIT_FIRST_PROTOCOL_TAKE,
        TOTAL_POOL_CASH - PROFIT_FIRST_PROTOCOL_TAKE,
    );
}

#[test]
fun loss_first_settlement_protocol_takes_share_of_net_profit() {
    run_two_expiry_settlements(
        SETTLEMENT_ITM,
        helpers::min_strike(),
        0,
        0,
        LOSS_FIRST_RESERVE_AFTER_RELEASE,
        LOSS_FIRST_PROTOCOL_TAKE,
        TOTAL_POOL_CASH - LOSS_FIRST_PROTOCOL_TAKE,
    );
}

/// Scenario runner: two funded expiries (A = short, settles first; B = far,
/// settles second), one 1x ATM order on each, settled at the caller's prices.
/// Asserts the exact protocol reserve after each materialization point and the
/// terminal conservation sheet.
fun run_two_expiry_settlements(
    settlement_a: u64,
    settlement_b: u64,
    reserve_after_first_release: u64,
    reserve_after_first_claim: u64,
    reserve_after_second_release: u64,
    final_reserve: u64,
    final_idle: u64,
) {
    let mut fx = helpers::setup_market_default();
    fx.add_idle_supply_before_expiries(HEADROOM_SUPPLY);
    let (expiry_a_id, oracle_a_id) = fx.create_expiry(test_constants::short_expiry_ms());
    let (expiry_b_id, oracle_b_id) = fx.create_expiry(test_constants::default_expiry_ms());
    let mut manager_a = fx.create_funded_manager(test_constants::mint_deposit());
    let mut manager_b = fx.create_funded_manager_as(
        test_constants::bob(),
        test_constants::mint_deposit(),
    );

    // --- TX (alice): fund both expiries to the cash floor, mint the A order.
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut vault, mut market_a, mut oracle_a, mut config) = fx.take_market(
        expiry_a_id,
        oracle_a_id,
    );
    let mut market_b = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_b_id);
    let mut oracle_b = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);
    fx.prepare_live_oracle(&config, &mut oracle_a, &mut pyth, test_constants::default_live_price());
    fx.prepare_live_oracle(&config, &mut oracle_b, &mut pyth, test_constants::default_live_price());
    let mut sync1 = plp::start_pool_sync(&mut config, &vault);
    sync1.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync1.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let _pool_value = vault.finish_pool_sync(&mut config, sync1);
    let order_a = fx.mint(
        &config,
        &mut manager_a,
        &mut market_a,
        &oracle_a,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    return_shared(oracle_b);
    return_shared(market_b);
    helpers::return_market(pyth, vault, market_a, oracle_a, config);

    // --- TX (bob): mint the B order, then run both settlements in order. All
    // post-mint flows (settle, settled redeem, sync, rebate claim) are
    // permissionless, so the whole sequence runs as bob.
    fx.scenario_mut().next_tx(test_constants::bob());
    let (mut pyth, mut vault, mut market_a, mut oracle_a, mut config) = fx.take_market(
        expiry_a_id,
        oracle_a_id,
    );
    let mut market_b = fx.scenario_mut().take_shared_by_id<ExpiryMarket>(expiry_b_id);
    let mut oracle_b = fx.scenario_mut().take_shared_by_id<MarketOracle>(oracle_b_id);
    let order_b = fx.mint(
        &config,
        &mut manager_b,
        &mut market_b,
        &oracle_b,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );

    // --- Settlement 1: expiry A settles and fully resolves (redeem -> settled
    // sync release -> rebate claim). The settled sync must also re-sync the
    // still-live expiry B, so B's oracle is re-seeded at the post-settlement
    // clock; that leg sweeps B's 505e6 over-floor trader inflow back to idle.
    fx.settle_oracle(&config, &mut oracle_a, &mut pyth, settlement_a);
    fx.redeem_settled(
        &config,
        &mut manager_a,
        &mut market_a,
        &oracle_a,
        &pyth,
        order_a,
        test_constants::mint_quantity(),
    );
    fx.prepare_live_oracle_at(
        &config,
        &mut oracle_b,
        &mut pyth,
        test_constants::default_live_price(),
        test_constants::short_expiry_ms() + 2_000,
    );
    let mut sync2 = plp::start_pool_sync(&mut config, &vault);
    sync2.sync_expiry(&mut vault, &mut market_a, &config, &oracle_a, &pyth, fx.clock());
    sync2.sync_expiry(&mut vault, &mut market_b, &config, &oracle_b, &pyth, fx.clock());
    let _pool_value = vault.finish_pool_sync(&mut config, sync2);
    assert_eq!(vault.protocol_reserve_balance(), reserve_after_first_release);
    fx.claim_trading_loss_rebate(&config, &mut vault, &mut market_a, &oracle_a, &mut manager_a);
    assert_eq!(vault.protocol_reserve_balance(), reserve_after_first_claim);

    // --- Settlement 2: expiry B settles and fully resolves the same way (A is
    // already deactivated, so the settled sync covers B alone).
    fx.settle_oracle(&config, &mut oracle_b, &mut pyth, settlement_b);
    fx.redeem_settled(
        &config,
        &mut manager_b,
        &mut market_b,
        &oracle_b,
        &pyth,
        order_b,
        test_constants::mint_quantity(),
    );
    fx.sync_expiry(&mut config, &mut vault, &mut market_b, &oracle_b, &pyth);
    assert_eq!(vault.protocol_reserve_balance(), reserve_after_second_release);
    fx.claim_trading_loss_rebate(&config, &mut vault, &mut market_b, &oracle_b, &mut manager_b);
    assert_eq!(vault.protocol_reserve_balance(), final_reserve);

    // --- Terminal sheet: both expiries fully drained; the traders' combined
    // cash is order-invariant, and the pool side conserves exactly — the only
    // order-dependent split is idle vs protocol reserve.
    helpers::check_market_cash(&market_a, helpers::expected_market_cash(0, 0, 0));
    helpers::check_market_cash(&market_b, helpers::expected_market_cash(0, 0, 0));
    assert_eq!(manager_a.balance() + manager_b.balance(), TRADERS_FINAL_TOTAL);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(final_idle, TOTAL_SUPPLY, final_reserve),
    );

    return_shared(oracle_b);
    return_shared(market_b);
    helpers::return_market(pyth, vault, market_a, oracle_a, config);
    destroy(manager_a);
    destroy(manager_b);
    fx.finish();
}
