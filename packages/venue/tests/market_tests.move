// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module venue::market_tests;

use account::{account::{Self, AccountWrapper}, account_registry::AccountRegistry};
use enclave::enclave::{Self, Enclave};
use std::unit_test::assert_eq;
use sui::{clock::Clock, coin::Coin, test_scenario::{Self as test, Scenario, return_shared, return_to_address}};
use venue::{
    admin::AdminCap,
    deployer_admin::DeployerAdminCap,
    deployer_registry::{Self, DeployerRegistry},
    deployer_vault::Vault,
    index_market::{Self, IndexMarket},
    index_ticket::{Self, VenueApp},
    market_phase,
    publisher::{Self, PublisherCap},
    world::{Self, USDC},
};

const SCALE: u64 = 1_000_000_000;
const CENT: u64 = 10_000_000;
const PK: vector<u8> = x"ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c";
const SIG_RESULT: vector<u8> =
    x"08ce5963e358ae333f6d3ab45a1f69df3cb61ad1383374f58c616ea76add1b9acc4c4090ef1ac034d2cdd510fd500d4c40822ec0d3e1f51f0f9d3ecd57ee4108";

#[test]
fun empty_market_rebalance_stops_at_the_band_target() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), 5_000);
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let deployer_id = vault.deployer_id();
    let enclave_id = object::id(&enclave);
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[enclave_id], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    market.rebalance(&mut vault, &registry);
    assert_eq!(market.cash(), 1_000);
    assert_eq!(vault.cash(), 4_000);
    market.rebalance(&mut vault, &registry);
    assert_eq!(market.cash(), 1_000);
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun deployer_lowers_the_market_cap_and_rebalance_follows() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), 5_000);
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::sync());
    let deployer_cap = scenario.take_from_sender<DeployerAdminCap>();
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let clock = world::clock(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let deployer_id = vault.deployer_id();
    let enclave_id = object::id(&enclave);
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[enclave_id], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    // 10 percent of a 2,000 cap is 200. The vault still holds the other 4,800.
    market.set_market_cap(&registry, &deployer_cap, 2_000);
    market.rebalance(&mut vault, &registry);
    assert_eq!(market.cash(), 200);
    assert_eq!(vault.cash(), 4_800);
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    return_to_address(world::sync(), deployer_cap);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::ECap)]
fun a_zero_market_cap_aborts() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::sync());
    let deployer_cap = scenario.take_from_sender<DeployerAdminCap>();
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let clock = world::clock(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[object::id(&enclave)], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    market.set_market_cap(&registry, &deployer_cap, 0);
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    return_to_address(world::sync(), deployer_cap);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun exit_prices_from_the_live_std() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[object::id(&enclave)], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, s(55), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    market.rebalance(&mut vault, &registry);
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(4), clock.timestamp_ms(), &clock);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    clock.set_for_testing(1_100_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(16), clock.timestamp_ms(), &clock);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    let first = market.open_ticket(0);
    let second = market.open_ticket(1);
    assert_eq!(index_ticket::std(wrapper.load_account(), first), s(4));
    assert_eq!(index_ticket::std(wrapper.load_account(), second), s(16));
    clock.set_for_testing(1_200_000);
    market.publish_mid(&mut vault, &publisher, s(92), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, first, 0, &clock, scenario.ctx());
    // Both tickets exit at the live standard deviation of 8. The curve table prices that exit at 109.92.
    assert_eq!(round_cents(market.last_paid()), 10992);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, second, 0, &clock, scenario.ctx());
    assert_eq!(round_cents(market.last_paid()), 10992);
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun claim_pays_the_capped_distance_from_the_result() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[object::id(&enclave)], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, s(55), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    market.end_as_publisher(&publisher, &clock);
    clock.set_for_testing(2_000_000);
    registry.set_enclave_required(&cap, deployer_id, true);
    market.settle(&mut vault, &registry, &enclave, s(88), 2_000_000, SIG_RESULT, &clock, scenario.ctx());
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    assert_eq!(market.last_paid(), s(75));
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::EWindow)]
fun publish_rejects_a_short_claim_window() {
    let (mut scenario, type_id) = world::start();
    scenario.next_tx(world::sync());
    let publisher = scenario.take_from_sender<PublisherCap>();
    let registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, 0, 100, 0, 0, 10_000, 1, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    market.destroy_for_testing(&mut vault);
    enclave.destroy();
    abort 999
}

#[test]
fun publisher_writes_the_mid_and_the_result_when_the_enclave_is_off() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 0, 0, s(8), clock.timestamp_ms(), &clock);
    assert_eq!(market.mid(), s(88));
    assert_eq!(market.std(), s(8));
    clock.set_for_testing(2_000_000);
    market.end_as_publisher(&publisher, &clock);
    market.settle_as_publisher(&mut vault, &registry, &publisher, s(88), &clock, scenario.ctx());
    assert_eq!(market.phase(), market_phase::settlement());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::EEnclave)]
fun publisher_settle_aborts_when_the_enclave_is_required() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let deployer_id = vault.deployer_id();
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.set_enclave_required(&cap, deployer_id, true);
    registry.update(
        &cap, deployer_id, vector[type_id], vector[object::id(&enclave)], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build(
        &registry, &vault, &publisher, &enclave, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    let mut clock = world::clock(&scenario);
    clock.set_for_testing(1_000_000);
    market.end_as_publisher(&publisher, &clock);
    market.settle_as_publisher(&mut vault, &registry, &publisher, s(88), &clock, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = index_market::EEnclave)]
fun enclave_settle_aborts_when_the_flag_is_off() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    let enclave = enclave::new_enclave_for_testing<VenueApp>(PK, scenario.ctx());
    let mut clock = world::clock(&scenario);
    clock.set_for_testing(1_000_000);
    market.end_as_publisher(&publisher, &clock);
    market.settle(&mut vault, &registry, &enclave, s(88), 2_000_000, SIG_RESULT, &clock, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = index_market::EEnclave)]
fun publish_without_an_enclave_aborts_when_the_flag_is_on() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.set_enclave_required(&cap, deployer_id, true);
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 1000, option::none(),
    );
    let market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000, scenario.ctx(),
    );
    market.destroy_for_testing(&mut vault);
    abort 0
}

#[test]
fun settle_pays_the_loss_from_the_fee_before_equity() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    let premium = index_ticket::premium(wrapper.load_account(), ticket_id);
    let fee = market.held_fees();
    let equity_before = vault.equity();
    market.end_as_publisher(&publisher, &clock);
    clock.set_for_testing(2_000_000);
    // Result at the cap. The written long claim for this ticket is 195.
    market.settle_as_publisher(&mut vault, &registry, &publisher, s(100), &clock, scenario.ctx());
    let claim = s(195);
    assert!(claim > premium, 0);
    let loss = claim - premium;
    assert!(fee < loss, 1);
    assert_eq!(vault.equity(), equity_before - (loss - fee));
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    assert_eq!(market.last_paid(), claim);
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun a_long_and_a_short_reserve_one_worst_claim() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(3000));
    fund(&mut scenario, world::alice(), s(2000));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, s(100), 0, 0, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(50), 0, 0, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, 0, s(10), s(2000), option::none(), &clock, scenario.ctx());
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 1, s(100), s(10), s(2000), option::none(), &clock, scenario.ctx());
    // Each ticket can claim 1,000 at its own end. Both ends still total 1,000.
    assert_eq!(market.owed(), s(1000));
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 0, option::none(),
    );
    market.rebalance(&mut vault, &registry);
    assert_eq!(market.cash(), s(1000));
    let vault_before = vault.cash();
    let long = market.open_ticket(0);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, long, 0, &clock, scenario.ctx());
    assert!(market.last_paid() > 0, 0);
    assert_eq!(market.owed(), s(1000));
    assert_eq!(market.cash(), s(1000));
    assert_eq!(vault_before - vault.cash(), market.last_paid());
    let short = market.open_ticket(0);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, short, 0, &clock, scenario.ctx());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::ECap)]
fun an_open_above_the_market_cap_aborts() {
    let (mut scenario, type_id) = world::start();
    fund(&mut scenario, world::alice(), s(2000));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, s(100), 0, 0, s(100), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(50), 0, 0, s(8), clock.timestamp_ms(), &clock);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 1, s(100), s(10), s(2000), option::none(), &clock, scenario.ctx());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun short_claim_at_zero_pays_the_full_width() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(3000));
    fund(&mut scenario, world::alice(), s(2000));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, s(100), 100, 100, s(3000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 1, s(100), s(10), s(2000), option::none(), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    let premium = index_ticket::premium(wrapper.load_account(), ticket_id);
    let fee = market.held_fees();
    let equity_before = vault.equity();
    market.end_as_publisher(&publisher, &clock);
    clock.set_for_testing(2_000_000);
    market.settle_as_publisher(&mut vault, &registry, &publisher, 0, &clock, scenario.ctx());
    let claim = s(1000);
    assert!(claim > premium, 0);
    let loss = claim - premium;
    assert!(fee < loss, 1);
    assert_eq!(vault.equity(), equity_before - (loss - fee));
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    assert_eq!(market.last_paid(), claim);
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun a_higher_mid_marks_the_vault_below_equity() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    clock.set_for_testing(1_100_000);
    market.publish_mid(&mut vault, &publisher, s(99), 100, 100, s(8), clock.timestamp_ms(), &clock);
    assert!(vault.nav() < vault.equity(), 0);
    assert_eq!(vault.total_shares(), vault.equity());
    market.end_as_publisher(&publisher, &clock);
    clock.set_for_testing(2_000_000);
    market.settle_as_publisher(&mut vault, &registry, &publisher, s(88), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::EWindow)]
fun open_aborts_when_the_mid_is_older_than_the_freshness_window() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 500, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    clock.set_for_testing(1_000_600);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    abort 0
}

#[test, expected_failure(abort_code = index_market::EWindow)]
fun void_aborts_before_the_pause_window() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.pause_as_admin(&cap, &clock);
    market.void(&mut vault, &registry, &clock, scenario.ctx());
    abort 0
}

#[test]
fun void_after_the_pause_window_returns_open_cash() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    let refund = index_ticket::open_cash(wrapper.load_account(), ticket_id);
    let equity_before = vault.equity();
    market.pause_as_admin(&cap, &clock);
    clock.set_for_testing(1_001_000);
    market.void(&mut vault, &registry, &clock, scenario.ctx());
    assert_eq!(vault.equity(), equity_before);
    assert_eq!(vault.nav(), vault.equity());
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    assert_eq!(market.last_paid(), refund);
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun void_after_pending_plus_the_void_window() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 5_000, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.end_as_publisher(&publisher, &clock);
    clock.set_for_testing(1_006_000);
    market.void(&mut vault, &registry, &clock, scenario.ctx());
    assert_eq!(market.phase(), market_phase::settlement());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test]
fun publish_keeps_the_wallet_fee_and_the_open_mid() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 10_000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    assert_eq!(market.wallet_fee_bps(), 10_000);
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    assert_eq!(market.sequence(), 1_000_000);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), option::none(), &clock, scenario.ctx());
    let ticket_id = market.open_ticket(0);
    assert_eq!(index_ticket::entry_mid(wrapper.load_account(), ticket_id), s(88));
    let fee = market.held_fees();
    assert!(fee > 0, 0);
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 0, 2000, 0, 10_000, option::none(),
    );
    assert_eq!(market.wallet_fee_bps(), 10_000);
    market.pause_as_admin(&cap, &clock);
    assert_eq!(market.phase(), market_phase::paused());
    market.rebalance(&mut vault, &registry);
    market.end_as_publisher(&publisher, &clock);
    assert_eq!(market.phase(), market_phase::pending());
    clock.set_for_testing(2_000_000);
    // A long at its floor pays nothing, so the whole open fee is the wallet remainder.
    market.settle_as_publisher(&mut vault, &registry, &publisher, s_floor(), &clock, scenario.ctx());
    market.claim(&accounts, &mut wrapper, ticket_id, scenario.ctx());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    let mut paid = 0;
    while (test::has_most_recent_for_address<Coin<USDC>>(world::fee())) {
        let coin = scenario.take_from_address<Coin<USDC>>(world::fee());
        paid = paid + coin.burn_for_testing();
    };
    assert_eq!(paid, fee);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::EPhase)]
fun a_paused_market_refuses_a_mid() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.pause_as_admin(&cap, &clock);
    market.publish_mid(&mut vault, &publisher, s(88), 0, 0, s(8), clock.timestamp_ms(), &clock);
    abort 99
}

#[test, expected_failure(abort_code = index_market::ESequence)]
fun a_mid_sequence_must_move_forward() {
    let (mut scenario, type_id) = world::start();
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, 100, 0, 0, 10_000, 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 0, 0, s(8), 5, &clock);
    market.publish_mid(&mut vault, &publisher, s(89), 0, 0, s(8), 5, &clock);
    abort 0
}

#[test]
fun a_later_mid_replaces_the_ask_and_the_bid() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(3000));
    fund(&mut scenario, world::alice(), s(2000));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, 0, s(100), 0, 0, s(5000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    // Ask 1,000 bps is 10 percent. Bid 2,000 bps is 20 percent.
    market.publish_mid(&mut vault, &publisher, s(50), 2_000, 1_000, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, 0, s(10), s(5000), option::none(), &clock, scenario.ctx());
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 1, s(100), s(10), s(5000), option::none(), &clock, scenario.ctx());
    let long_premium = index_ticket::premium(wrapper.load_account(), market.open_ticket(0));
    let short_premium = index_ticket::premium(wrapper.load_account(), market.open_ticket(1));
    // The long pays 10 percent of its premium. The short pays 20 percent of its premium.
    assert_eq!(market.held_fees(), long_premium / 10 + short_premium / 5);
    let long = market.open_ticket(0);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, long, 0, &clock, scenario.ctx());
    let short = market.open_ticket(0);
    market.exit(&mut vault, &registry, &accounts, &mut wrapper, short, 0, &clock, scenario.ctx());
    market.destroy_for_testing(&mut vault);
    return_all(&mut scenario, cap, publisher, registry, vault, accounts, wrapper, clock);
    scenario.end();
}

#[test, expected_failure(abort_code = index_market::ESignature)]
fun a_fee_override_without_the_fee_key_aborts() {
    let (mut scenario, type_id) = world::start();
    deposit(&mut scenario, world::bob(), s(1000));
    fund(&mut scenario, world::alice(), s(500));
    give_alice_the_caps(&mut scenario);
    scenario.next_tx(world::alice());
    let cap = scenario.take_from_sender<AdminCap>();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let mut registry = scenario.take_shared<DeployerRegistry>();
    let mut vault = world::vault(&scenario);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(&scenario, &accounts, world::alice());
    let mut clock = world::clock(&scenario);
    let deployer_id = vault.deployer_id();
    registry.set_min_claim_window(&cap, 0, scenario.ctx());
    registry.update(
        &cap, deployer_id, vector[type_id], vector[], 10_000_000_000_000,
        vector[], world::fee(), 7000, 2000, 0, 10_000, option::none(),
    );
    let mut market = index_market::build_with_key(
        &registry, &vault, &publisher, type_id, s_floor(), s(100), 100, 100, s(1000), 0, 0, 9_000_000_000, 10_000_000_000, 1_000, 1_000,
        scenario.ctx(),
    );
    clock.set_for_testing(1_000_000);
    market.publish_mid(&mut vault, &publisher, s(88), 100, 100, s(8), clock.timestamp_ms(), &clock);
    market.rebalance(&mut vault, &registry);
    let fee = option::some(index_market::fee_override(50, 9_000_000_000, 1, vector[1]));
    market.open(&mut vault, &registry, &accounts, &mut wrapper, 0, s_floor(), s(10), s(1000), fee, &clock, scenario.ctx());
    abort 0
}

fun s(whole: u64): u64 { whole * SCALE }
fun s_floor(): u64 { 80 * SCALE + SCALE / 2 }
fun round_cents(amount: u64): u64 { (amount + CENT / 2) / CENT }

fun return_all(
    scenario: &mut Scenario,
    cap: AdminCap,
    publisher: PublisherCap,
    registry: DeployerRegistry,
    vault: Vault<USDC>,
    accounts: AccountRegistry,
    wrapper: AccountWrapper,
    clock: Clock,
) {
    return_to_address(world::alice(), cap);
    return_to_address(world::alice(), publisher);
    return_shared(registry);
    return_shared(vault);
    return_shared(accounts);
    return_shared(wrapper);
    return_shared(clock);
    scenario.next_tx(world::admin());
}

fun give_alice_the_caps(scenario: &mut Scenario) {
    scenario.next_tx(world::sync());
    let publisher = scenario.take_from_sender<PublisherCap>();
    publisher.transfer_to(world::alice());
    scenario.next_tx(world::admin());
    let cap = scenario.take_from_sender<AdminCap>();
    transfer::public_transfer(cap, world::alice());
}

fun deposit(scenario: &mut Scenario, owner: address, amount: u64) {
    fund(scenario, owner, amount);
    scenario.next_tx(owner);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(scenario, &accounts, owner);
    let mut vault = world::vault(scenario);
    let registry = scenario.take_shared<DeployerRegistry>();
    vault.deposit(&registry, &accounts, &mut wrapper, amount, scenario.ctx());
    return_shared(accounts);
    return_shared(vault);
    return_shared(registry);
    return_shared(wrapper);
}

fun fund(scenario: &mut Scenario, owner: address, amount: u64) {
    scenario.next_tx(owner);
    let accounts = scenario.take_shared<AccountRegistry>();
    let mut wrapper = world::wrapper(scenario, &accounts, owner);
    world::fund(&mut wrapper, amount, scenario.ctx());
    return_shared(accounts);
    return_shared(wrapper);
}
