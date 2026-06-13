// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the custody of the unresolved trading-loss rebate reserve through a
/// settled pool sync: `release_settled_pool_cash` returns everything above
/// `settled_liability + rebate_reserve` to pool idle and retains the reserve
/// inside the settled expiry, where it is excluded from pool NAV (the settled
/// expiry is recorded at NAV 0 and deactivated, so later full-pool syncs never
/// revisit it). The per-manager `claim_trading_loss_rebate` is the only drain:
/// for a net-winner manager (owed nothing) it resolves the fee basis and
/// returns the full residual reserve to pool idle.
#[test_only]
module deepbook_predict::rebate_reserve_retention_tests;

use deepbook_predict::{constants, flow_test_helpers as helpers, plp, test_constants};
use std::unit_test::{assert_eq, destroy};

/// Per-trade fee floors at `min_fee` (fixture base_fee = 1) — independently
/// pinned in `lifecycle_tests`.
const MINT_MIN_FEE: u64 = 5_000_000;
/// 1x ATM premium: the order is `[min_strike, +inf)` with live forward ==
/// min_strike, so entry probability = Φ(0) = 0.5 and
/// net_premium = floor(0.5 * 1e9 quantity) = 500_000_000.
const MINT_PRINCIPAL: u64 = 500_000_000;
/// Reserved at mint = floor(fee * default 50% trading-loss rebate rate)
///   = floor(5_000_000 * 0.5) = 2_500_000.
const REBATE_RESERVE: u64 = 2_500_000;
/// In the money: strictly above the order's lower strike (min_strike = 100e9).
const SETTLEMENT_ITM: u64 = 110_000_000_000;
/// Pool idle after the settled sync. The expiry holds
///   cash_floor + premium + fee - payout = 50_000e6 + 505e6 - 1_000e6
///   = 49_505_000_000
/// and releases everything above the 2_500_000 reserve:
///   idle = (initial_supply - cash_floor) + (49_505_000_000 - 2_500_000)
///        = 250_000_000_000 + 49_502_500_000 = 299_502_500_000.
const IDLE_AFTER_SETTLED_SYNC: u64 = 299_502_500_000;

#[test]
fun settled_sync_retains_rebate_reserve_until_manager_claim() {
    let (mut fx, expiry_id, oracle_id, mut manager) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut vault, mut market, mut oracle, mut config) = fx.take_market(
        expiry_id,
        oracle_id,
    );
    let cash_floor = constants::expiry_cash_floor!();
    let initial_supply = test_constants::default_initial_supply();

    // --- Mint one 1x ATM order: premium + fee move into expiry cash and the
    // fee books the rebate reserve.
    let order_id = fx.mint(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        helpers::min_strike(),
        constants::pos_inf!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
    );
    let cash_after_mint = cash_floor + MINT_PRINCIPAL + MINT_MIN_FEE;
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(
            cash_after_mint,
            test_constants::mint_quantity(),
            REBATE_RESERVE,
        ),
    );

    // --- Settle ITM and fully close: the 1x winner is paid its full notional,
    // draining the payout liability; the rebate reserve survives untouched.
    fx.settle_oracle(&config, &mut oracle, &mut pyth, SETTLEMENT_ITM);
    fx.redeem_settled(
        &config,
        &mut manager,
        &mut market,
        &oracle,
        &pyth,
        order_id,
        test_constants::mint_quantity(),
    );
    let cash_after_redeem = cash_after_mint - test_constants::mint_quantity();
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(cash_after_redeem, 0, REBATE_RESERVE),
    );

    // --- Settled pool sync: the expiry is deactivated and releases everything
    // above settled_liability (0) + rebate_reserve back to pool idle.
    let pool_value = fx.sync_expiry_value(&mut config, &mut vault, &mut market, &oracle, &pyth);

    // PIN 1 — the reserve stays inside the settled expiry: cash == reserve.
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(REBATE_RESERVE, 0, REBATE_RESERVE),
    );
    // PIN 2 — the retained reserve is excluded from pool NAV: the settled
    // expiry was recorded at NAV 0, and the loss expiry materializes no
    // protocol profit (credits 49_502_500_000 < debits 50_000_000_000 keeps the
    // protocol-share exclusion at 0), so the pool value is exactly the idle
    // balance and the protocol reserve takes nothing.
    assert_eq!(pool_value, IDLE_AFTER_SETTLED_SYNC);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(IDLE_AFTER_SETTLED_SYNC, initial_supply, 0),
    );

    // PIN 3 — later full-pool syncs no longer visit the deactivated expiry: an
    // empty sync succeeds without touching the market, the pool value is
    // unchanged, and the reserve still sits in the expiry. No pool-side path
    // drains it.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let pool_value_after = vault.finish_pool_sync(&mut config, sync);
    assert_eq!(pool_value_after, IDLE_AFTER_SETTLED_SYNC);
    helpers::check_market_cash(
        &market,
        helpers::expected_market_cash(REBATE_RESERVE, 0, REBATE_RESERVE),
    );

    // PIN 4 — the per-manager claim is the only drain. The manager is a net
    // winner (its gross profit, payout minus premium, far exceeds the
    // 2_500_000 reserve), so its eligible rebate is 0: nothing is paid to the
    // manager and the FULL residual returns to pool idle. The returned
    // 2_500_000 is terminal profit absorbed by the expiry's outstanding
    // 497_500_000 terminal loss, so the protocol reserve still takes nothing.
    let manager_balance_before = manager.balance();
    fx.claim_trading_loss_rebate(&config, &mut vault, &mut market, &oracle, &mut manager);
    assert_eq!(manager.balance(), manager_balance_before);
    helpers::check_market_cash(&market, helpers::expected_market_cash(0, 0, 0));
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            IDLE_AFTER_SETTLED_SYNC + REBATE_RESERVE,
            initial_supply,
            0,
        ),
    );

    helpers::return_market(pyth, vault, market, oracle, config);
    destroy(manager);
    fx.finish();
}
