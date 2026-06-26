// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression for C1: a partial close followed by an in-the-money settle must
/// reserve the settled payout exactly, so the marginal settled redeem pays the
/// winner in full and drains the reserve to zero (no `u64` underflow).
///
/// Before the fix, a partial close removed `close_q - mul(remove_fs, T)` from the
/// payout tree, leaving residual `R = remaining_q - mul(old_fs,T) + mul(remove_fs,T)`,
/// while `close_settled_order` recomputes `P = remaining_q - mul(remaining_fs,T)`.
/// Round-down `mul` is sub-additive (`mul(old_fs,T) >= mul(remove_fs,T) + mul(remaining_fs,T)`,
/// gap in {0,1}), so `R <= P` and `settled_payout_liability - payout` underflowed
/// when the gap was 1, stranding the payout. The fix removes the order's full
/// terms and reinserts the survivor's exact terms, so `R == P` by construction.
///
/// The settlement-independent root-cause proof is the +1 floor-share
/// sub-additivity gap for these mint params, plus the live partial-close survivor
/// reinsertion staying solvent. Passive terminal settlement coverage lives in
/// `flows/settlement_flow_tests.move`; exact live-close cash / payout numbers live
/// in `flows/backing_buffer_flow_tests.move`.
#[test_only]
module deepbook_predict::strike_exposure_c1_tests;

use account::account::AccountWrapper;
use deepbook_predict::{
    block_scholes_feed::BlockScholesFeed,
    constants,
    expiry_market::ExpiryMarket,
    flow_test_helpers as helpers,
    plp::PoolVault,
    protocol_config::ProtocolConfig,
    test_constants
};
use propbook::{pyth_feed::PythFeed, registry::OracleRegistry};
use sui::accumulator::AccumulatorRoot;

/// 2x leverage gives a non-zero floor (required for the gap to exist).
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// Single close row for survivor reinsertion coverage.
const SINGLE_CLOSE: u64 = 400_000_000;

/// Double close: 300M then 200M of the 700M survivor exercise sequential survivor
/// reinsertion (the second close must remove terms the tree actually holds).
const FIRST_CLOSE: u64 = 300_000_000;
const SECOND_CLOSE: u64 = 200_000_000;

/// A single partial close must leave the survivor backed after reinsertion.
#[test]
fun partial_close_survivor_stays_backed() {
    run_live_close_schedule(vector[SINGLE_CLOSE]);
}

/// Two sequential closes: the survivor is reinserted each time, so the second close
/// removes terms the tree actually holds and the market stays solvent throughout.
#[test]
fun double_partial_close_survivor_reinsertion_stays_backed() {
    run_live_close_schedule(vector[FIRST_CLOSE, SECOND_CLOSE]);
}

/// Shared 2x-mint prologue + a row's live close schedule + the reachable solvency /
/// position assertions. Each row is a self-contained fixture lifecycle.
fun run_live_close_schedule(closes: vector<u64>) {
    let (mut fx, expiry_id, trader) = helpers::setup_live_market(
        test_constants::short_expiry_ms(),
        test_constants::default_live_price(),
    );
    fx.scenario_mut().next_tx(test_constants::alice());
    let (mut pyth, mut bs, oracle_registry, vault, mut market, config) = fx.take_market(expiry_id);
    let mut wrapper = fx.take_account(&trader);
    let root = fx.take_root();

    let order_id = fx.mint(
        &config,
        &oracle_registry,
        &mut wrapper,
        &root,
        &mut market,
        &pyth,
        &bs,
        helpers::strike_tick(),
        constants::pos_inf_tick!(),
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
    );

    // Run the live close schedule, threading the survivor id through each partial
    // close. After every close the survivor position must exist and the market must
    // stay backed (cash >= payout liability + rebate reserve).
    let mut survivor_id = order_id;
    let mut i = 0;
    while (i < closes.length()) {
        fx.advance_live_oracle(&market, &mut pyth, &mut bs, test_constants::default_live_price());
        let (_closed, replacement) = fx.redeem(
            &config,
            &oracle_registry,
            &mut wrapper,
            &root,
            &mut market,
            &pyth,
            &bs,
            survivor_id,
            closes[i],
        );
        survivor_id = replacement.destroy_some();
        assert!(helpers::has_position(&wrapper, expiry_id, survivor_id));
        helpers::assert_market_backed(&market);
        i = i + 1;
    };

    cleanup(fx, pyth, bs, oracle_registry, vault, market, config, wrapper, root);
}

fun cleanup(
    fx: helpers::Fixture,
    pyth: PythFeed,
    bs: BlockScholesFeed,
    oracle_registry: OracleRegistry,
    vault: PoolVault,
    market: ExpiryMarket,
    config: ProtocolConfig,
    wrapper: AccountWrapper,
    root: AccumulatorRoot,
) {
    helpers::return_account(wrapper, root);
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}
