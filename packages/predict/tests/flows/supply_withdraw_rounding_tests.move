// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A1/A3 PLP supply/withdraw rounding on an idle-only pool (no expiries, so
/// every sync finishes trivially and the uncertainty-band withdraw fee is
/// structurally zero). Supply and withdraw both price through a FLOORED
/// 1e9-scaled ratio (divide then multiply, rounding down), so dust is lost
/// whenever the ratio is non-terminating — always to the pool, never to the
/// user: an exactly-dividing withdraw pays full pro-rata, a non-dividing one
/// rounds down twice, a supply at the enriched per-share mints fractionally
/// fewer shares, and a same-state supply→withdraw round-trip strictly loses.
/// The remaining holder's per-share value never falls at any step, and the
/// protocol reserve stays untouched (rounding dust is LP-owned).
#[test_only]
module deepbook_predict::supply_withdraw_rounding_tests;

use deepbook_predict::{
    flow_test_helpers as helpers,
    plp::{Self, PoolVault},
    protocol_config::ProtocolConfig,
    pyth_source::PythSource,
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::return_shared;

/// Supplied at an exact 1:1 pool (ratio = 1e9 exactly) — mints 1:1.
const PHASE_A_SUPPLY: u64 = 50_000_000_000;
/// lp / total_supply = 35e9 / 350e9 = 0.1 exactly: ratio 100_000_000
/// terminates, payout is full pro-rata 35_000_000_000.
const WITHDRAW_EVEN_SHARES: u64 = 35_000_000_000;
/// The remaining 15e9 shares: lp / total_supply = 15e9 / 315e9 = 1/21 does NOT
/// terminate — ratio = floor(1e9 / 21) = 47_619_047, gross
/// = floor(315e9 * ratio / 1e9) = 14_999_999_805; dust 195 stays in idle.
const WITHDRAW_DUST_SHARES: u64 = 15_000_000_000;
const WITHDRAW_DUST_PROCEEDS: u64 = 14_999_999_805;
const DUST_RETAINED: u64 = 195;
/// Supply at the now-enriched per-share (300_000_000_195 value over 300e9
/// shares): ratio = floor(300e9 * 1e9 / 300_000_000_195) = 999_999_999, so
/// the 1e9 payment mints 999_999_999 shares (one fractional share to the pool).
const UNEVEN_SUPPLY: u64 = 1_000_000_000;
const UNEVEN_SUPPLY_SHARES: u64 = 999_999_999;
/// Round-trip: withdrawing those shares back at the same mark pays
/// ratio = floor(999_999_999e9 / 300_999_999_999) = 3_322_259, gross
/// = floor(301_000_000_195 * ratio / 1e9) = 999_999_959 — an exact loss of 41.
const ROUND_TRIP_PROCEEDS: u64 = 999_999_959;

#[test]
fun rounding_always_favors_the_pool_and_round_trips_lose() {
    let mut fx = helpers::setup_market_default();
    fx.scenario_mut().next_tx(test_constants::admin());
    let pyth = fx.scenario_mut().take_shared_by_id<PythSource>(fx.pyth_id());
    let mut vault = fx.scenario_mut().take_shared_by_id<PoolVault>(fx.vault_id());
    let mut config = fx.scenario_mut().take_shared<ProtocolConfig>();

    // --- Bootstrap: the fixture's first supply minted 1:1.
    let initial = test_constants::default_initial_supply();
    helpers::check_pool(&vault, helpers::expected_pool_state(initial, initial, 0));

    // --- Supply at exact 1:1: zero dust, shares == payment.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let mut plp1 = fx.supply(&mut config, &mut vault, sync, &pyth, PHASE_A_SUPPLY);
    assert_eq!(plp1.value(), PHASE_A_SUPPLY);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(initial + PHASE_A_SUPPLY, initial + PHASE_A_SUPPLY, 0),
    );

    // --- Withdraw an exactly-dividing share count: full pro-rata payout, zero
    // band fee, zero-value in-kind incentive coins.
    let coin_even = plp1.split(WITHDRAW_EVEN_SHARES, fx.scenario_mut().ctx());
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc_a, sui_a, deep_a) = fx.withdraw(&mut config, &mut vault, sync, coin_even);
    assert_eq!(dusdc_a.value(), WITHDRAW_EVEN_SHARES);
    assert_eq!(sui_a.value(), 0);
    assert_eq!(deep_a.value(), 0);
    let supply_after_even = initial + PHASE_A_SUPPLY - WITHDRAW_EVEN_SHARES;
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(supply_after_even, supply_after_even, 0),
    );

    // --- Withdraw a NON-dividing share count: the floored ratio rounds the
    // payout down; the dust stays in idle, so the remaining holder's per-share
    // value strictly rises above 1.0.
    assert_eq!(plp1.value(), WITHDRAW_DUST_SHARES);
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc_b, sui_b, deep_b) = fx.withdraw(&mut config, &mut vault, sync, plp1);
    assert_eq!(dusdc_b.value(), WITHDRAW_DUST_PROCEEDS);
    assert_eq!(sui_b.value(), 0);
    assert_eq!(deep_b.value(), 0);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(initial + DUST_RETAINED, initial, 0),
    );

    // --- Supply at the enriched per-share: the supplier mints fractionally
    // FEWER shares (never more — the supply mark can't over-mint), and the
    // per-share value rises again for incumbents.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let plp2 = fx.supply(&mut config, &mut vault, sync, &pyth, UNEVEN_SUPPLY);
    assert_eq!(plp2.value(), UNEVEN_SUPPLY_SHARES);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            initial + DUST_RETAINED + UNEVEN_SUPPLY,
            initial + UNEVEN_SUPPLY_SHARES,
            0,
        ),
    );

    // --- Round-trip: withdrawing the freshly-minted shares at the unchanged
    // mark strictly loses (proceeds < payment) — no free round-trip; all dust
    // (195 + 41) ends in idle for remaining LPs, and the protocol reserve was
    // never touched.
    let sync = plp::start_pool_sync(&mut config, &vault);
    let (dusdc_c, sui_c, deep_c) = fx.withdraw(&mut config, &mut vault, sync, plp2);
    assert_eq!(dusdc_c.value(), ROUND_TRIP_PROCEEDS);
    assert!(dusdc_c.value() < UNEVEN_SUPPLY);
    helpers::check_pool(
        &vault,
        helpers::expected_pool_state(
            initial + DUST_RETAINED + UNEVEN_SUPPLY - ROUND_TRIP_PROCEEDS,
            initial,
            0,
        ),
    );

    destroy(dusdc_a);
    destroy(dusdc_b);
    destroy(dusdc_c);
    destroy(sui_a);
    destroy(sui_b);
    destroy(sui_c);
    destroy(deep_a);
    destroy(deep_b);
    destroy(deep_c);
    return_shared(config);
    return_shared(vault);
    return_shared(pyth);
    fx.finish();
}
