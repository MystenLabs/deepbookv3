// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sui's coin deny list with the test USDC made a regulated coin, as Circle's
/// Mainnet USDC is: a `DenyCapV2<USDC>` that may also pause the coin globally.
/// The in-repo USDC is unregulated, so without this every deny-list read is
/// false. Each change starts a new epoch, because Sui's own receive check and
/// Predict's reads both use the current epoch's list, which a change reaches
/// only from the next epoch.
///
/// Move tests do not run Sui's end-of-transaction receive check, so a send to
/// a denied address would not abort here. The tests assert instead that
/// nothing is sent to one.
#[test_only]
module deepbook_predict::usdc_deny_list;

use deepbook_predict::test_constants;
use std::unit_test::destroy;
use sui::{
    coin::{Self, DenyCapV2},
    coin_registry,
    deny_list::{Self, DenyList},
    test_scenario::{Scenario, return_shared},
    test_utils
};
use usdc::usdc::USDC;

/// Holds the test USDC's deny cap.
const DENY_CAP_HOLDER: address = @0xDE41;
/// Sui's deny list sits at this fixed system address.
const DENY_LIST_ADDRESS: address = @0x403;
/// Only the system address may create the deny list.
const SYSTEM: address = @0x0;

/// Share Sui's deny list and make the test USDC regulated. Leaves the scenario
/// in a new transaction by the admin.
public fun setup(scenario: &mut Scenario) {
    scenario.next_tx(SYSTEM);
    deny_list::create_for_testing(scenario.ctx());
    let (mut builder, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<USDC>(),
        6,
        b"USDC".to_string(),
        b"USDC".to_string(),
        b"Regulated test USDC".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let deny_cap = builder.make_regulated(true, scenario.ctx());
    let metadata_cap = builder.finalize(scenario.ctx());
    transfer::public_transfer(deny_cap, DENY_CAP_HOLDER);
    destroy(treasury_cap);
    destroy(metadata_cap);
    scenario.next_tx(test_constants::admin());
}

public fun deny_list_id(): ID { object::id_from_address(DENY_LIST_ADDRESS) }

public fun take(scenario: &Scenario): DenyList {
    scenario.take_shared_by_id<DenyList>(deny_list_id())
}

/// Deny `addr` and start the epoch it takes effect in.
public fun deny(scenario: &mut Scenario, addr: address) {
    let (mut list, mut cap) = take_with_cap(scenario);
    coin::deny_list_v2_add(&mut list, &mut cap, addr, scenario.ctx());
    put_back(scenario, list, cap);
}

/// Lift `addr`'s denial and start the epoch the lift takes effect in.
public fun undeny(scenario: &mut Scenario, addr: address) {
    let (mut list, mut cap) = take_with_cap(scenario);
    coin::deny_list_v2_remove(&mut list, &mut cap, addr, scenario.ctx());
    put_back(scenario, list, cap);
}

/// Pause or unpause USDC for every address and start the epoch it takes
/// effect in.
public fun set_global_pause(scenario: &mut Scenario, paused: bool) {
    let (mut list, mut cap) = take_with_cap(scenario);
    if (paused) {
        coin::deny_list_v2_enable_global_pause(&mut list, &mut cap, scenario.ctx());
    } else {
        coin::deny_list_v2_disable_global_pause(&mut list, &mut cap, scenario.ctx());
    };
    put_back(scenario, list, cap);
}

fun take_with_cap(scenario: &mut Scenario): (DenyList, DenyCapV2<USDC>) {
    scenario.next_tx(DENY_CAP_HOLDER);
    (take(scenario), scenario.take_from_sender<DenyCapV2<USDC>>())
}

fun put_back(scenario: &mut Scenario, list: DenyList, cap: DenyCapV2<USDC>) {
    return_shared(list);
    scenario.return_to_sender(cap);
    scenario.next_epoch(DENY_CAP_HOLDER);
}
