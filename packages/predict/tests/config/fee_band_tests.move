// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The fee-band template on `ProtocolConfig`: the admin setter's validation
/// envelope, its `FeeBandsUpdated` post-state event, and the lookup a market
/// runs against the copy it takes at creation (`bands_to` then `band_fee`).
/// Bands are `[low, high)` over the contract price, in FLOAT_SCALING; a price
/// outside every band pays the fee once.
#[test_only]
module deepbook_predict::fee_band_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    config_events,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self as test, Scenario, return_shared}};

/// Contract prices and multipliers, in FLOAT_SCALING.
const ZERO_PRICE: u64 = 0;
const FORTY_CENTS: u64 = 400_000_000;
const FIFTY_CENTS: u64 = 500_000_000;
const SIXTY_CENTS: u64 = 600_000_000;
const ONE_DOLLAR: u64 = 1_000_000_000;
const ONE_X: u64 = 1_000_000_000;
const ONE_AND_A_HALF_X: u64 = 1_500_000_000;
const TWO_X: u64 = 2_000_000_000;
const THREE_X: u64 = 3_000_000_000;
const TEN_X: u64 = 10_000_000_000;

/// A trading fee in USDC base units, and its multiples.
const FEE: u64 = 20_000;
const TWO_X_FEE: u64 = 40_000;
const THREE_X_FEE: u64 = 60_000;
const TEN_X_FEE: u64 = 200_000;
/// 1.5 * 7 = 10.5, rounded down.
const ODD_FEE: u64 = 7;
const ODD_FEE_AT_ONE_AND_A_HALF_X: u64 = 10;

/// The eight touching bands `[k/8, (k+1)/8)` of `$1`.
const EIGHTH: u64 = 125_000_000;
const MAX_BANDS: u64 = 8;
const NINE_BANDS: u64 = 9;

const EVENT_TIMESTAMP_MS: u64 = 1_750_000_000_000;
const TWO_EVENTS: u64 = 2;

public struct ExpectedFeeBandsUpdated has copy, drop {
    bands: vector<u64>,
    onchain_timestamp_ms: u64,
}

/// A real shared `ProtocolConfig` with no fee-band template, and an `AdminCap`.
fun new_shared_config(): (Scenario, AdminCap, ID, Clock) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(EVENT_TIMESTAMP_MS);
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id, clock)
}

fun finish(scenario: Scenario, admin_cap: AdminCap, config: ProtocolConfig, clock: Clock) {
    return_shared(config);
    clock.destroy_for_testing();
    destroy(admin_cap);
    scenario.end();
}

/// The fee a market created now would charge at `price`: copy the template onto
/// a fresh UID, the way market creation does, and look the price up there.
fun banded(config: &ProtocolConfig, scenario: &mut Scenario, price: u64, fee: u64): u64 {
    let mut id = object::new(scenario.ctx());
    config.bands_to(&mut id);
    let charged = protocol_config::band_fee(&id, price, fee);
    id.delete();
    charged
}

fun set(config: &mut ProtocolConfig, admin_cap: &AdminCap, bands: vector<u64>, clock: &Clock) {
    config.set_template_fee_bands(admin_cap, bands, clock);
}

// === Lookup ===

#[test]
fun no_template_charges_every_price_once() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    assert_eq!(banded(&config, &mut scenario, ZERO_PRICE, FEE), FEE);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), FEE);
    assert_eq!(banded(&config, &mut scenario, ONE_DOLLAR, FEE), FEE);
    finish(scenario, admin_cap, config, clock);
}

#[test]
fun a_band_includes_its_low_and_excludes_its_high() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X], &clock);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS - 1, FEE), FEE);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), TWO_X_FEE);
    assert_eq!(banded(&config, &mut scenario, SIXTY_CENTS - 1, FEE), TWO_X_FEE);
    assert_eq!(banded(&config, &mut scenario, SIXTY_CENTS, FEE), FEE);
    finish(scenario, admin_cap, config, clock);
}

/// Where two bands touch, the shared edge is the upper band's low.
#[test]
fun touching_bands_give_the_shared_edge_to_the_upper_band() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(
        &mut config,
        &admin_cap,
        vector[FORTY_CENTS, FIFTY_CENTS, TWO_X, FIFTY_CENTS, SIXTY_CENTS, THREE_X],
        &clock,
    );
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS - 1, FEE), TWO_X_FEE);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), THREE_X_FEE);
    finish(scenario, admin_cap, config, clock);
}

#[test]
fun the_multiplied_fee_rounds_down() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[ZERO_PRICE, ONE_DOLLAR, ONE_AND_A_HALF_X], &clock);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, ODD_FEE), ODD_FEE_AT_ONE_AND_A_HALF_X);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, 0), 0);
    finish(scenario, admin_cap, config, clock);
}

/// An empty table removes the template, so later markets copy nothing.
#[test]
fun an_empty_table_clears_the_template() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[ZERO_PRICE, ONE_DOLLAR, TWO_X], &clock);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), TWO_X_FEE);
    set(&mut config, &admin_cap, vector[], &clock);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), FEE);
    // Clearing an absent template is a no-op.
    set(&mut config, &admin_cap, vector[], &clock);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), FEE);
    finish(scenario, admin_cap, config, clock);
}

/// A copy belongs to the UID it was taken on: replacing the template leaves an
/// earlier copy as it was.
#[test]
fun a_copy_keeps_the_template_it_was_taken_from() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[ZERO_PRICE, ONE_DOLLAR, TWO_X], &clock);
    let mut earlier = object::new(scenario.ctx());
    config.bands_to(&mut earlier);
    set(&mut config, &admin_cap, vector[ZERO_PRICE, ONE_DOLLAR, THREE_X], &clock);
    assert_eq!(protocol_config::band_fee(&earlier, FIFTY_CENTS, FEE), TWO_X_FEE);
    assert_eq!(banded(&config, &mut scenario, FIFTY_CENTS, FEE), THREE_X_FEE);
    earlier.delete();
    finish(scenario, admin_cap, config, clock);
}

// === Validation envelope ===

/// Eight touching bands spanning `[0, $1)`, from 1x up to the 10x cap: every
/// boundary the setter accepts at once.
#[test]
fun the_setter_accepts_its_boundaries() {
    let (mut scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let mut bands = vector[];
    MAX_BANDS.do!(|k| {
        let mult = if (k == MAX_BANDS - 1) TEN_X else ONE_X;
        bands.append(vector[k * EIGHTH, (k + 1) * EIGHTH, mult]);
    });
    assert_eq!(bands[bands.length() - 2], ONE_DOLLAR);
    set(&mut config, &admin_cap, bands, &clock);
    assert_eq!(banded(&config, &mut scenario, ZERO_PRICE, FEE), FEE);
    assert_eq!(banded(&config, &mut scenario, ONE_DOLLAR - EIGHTH - 1, FEE), FEE);
    assert_eq!(banded(&config, &mut scenario, ONE_DOLLAR - EIGHTH, FEE), TEN_X_FEE);
    assert_eq!(banded(&config, &mut scenario, ONE_DOLLAR - 1, FEE), TEN_X_FEE);
    // `high` is exclusive, so no band holds the whole `$1`.
    assert_eq!(banded(&config, &mut scenario, ONE_DOLLAR, FEE), FEE);
    finish(scenario, admin_cap, config, clock);
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun a_partial_triple_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, SIXTY_CENTS], &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun nine_bands_abort() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    let mut bands = vector[];
    NINE_BANDS.do!(|k| bands.append(vector[k * EIGHTH / 2, (k + 1) * EIGHTH / 2, TWO_X]));
    set(&mut config, &admin_cap, bands, &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun an_empty_band_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, FIFTY_CENTS, TWO_X], &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun a_high_above_one_dollar_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, ONE_DOLLAR + 1, TWO_X], &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun a_multiplier_below_one_x_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, SIXTY_CENTS, ONE_X - 1], &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun a_multiplier_above_ten_x_aborts() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, SIXTY_CENTS, TEN_X + 1], &clock);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun overlapping_bands_abort() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(
        &mut config,
        &admin_cap,
        vector[FORTY_CENTS, FIFTY_CENTS + 1, TWO_X, FIFTY_CENTS, SIXTY_CENTS, THREE_X],
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidFeeBands)]
fun unsorted_bands_abort() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(
        &mut config,
        &admin_cap,
        vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X, FORTY_CENTS, FIFTY_CENTS, THREE_X],
        &clock,
    );
    abort 999
}

// === Event ===

/// Every set emits the whole post-state table, and a clear emits it empty.
#[test]
fun setting_and_clearing_emit_the_post_state_table() {
    let (scenario, admin_cap, config_id, clock) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    set(&mut config, &admin_cap, vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X], &clock);
    set(&mut config, &admin_cap, vector[], &clock);
    let events = event::events_by_type<config_events::FeeBandsUpdated>();
    assert_eq!(events.length(), TWO_EVENTS);
    let set_event = ExpectedFeeBandsUpdated {
        bands: vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X],
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[0]), bcs::to_bytes(&set_event));
    let cleared = ExpectedFeeBandsUpdated {
        bands: vector[],
        onchain_timestamp_ms: EVENT_TIMESTAMP_MS,
    };
    assert_eq!(bcs::to_bytes(&events[1]), bcs::to_bytes(&cleared));
    finish(scenario, admin_cap, config, clock);
}
