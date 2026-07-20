// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns one Predict test scenario and the stable identities of its shared roots.
/// Shared and address-owned objects stay in scenario inventory; `OwnedResources`
/// holds only the test Clock that must survive across transactions and teardown.
#[test_only]
module deepbook_predict::test_world;

use account::account_registry::{Self as account_registry, AccountAdminCap, AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    market_lifecycle_cap::MarketLifecycleCap,
    pause_cap::PauseCap,
    plp::{Self as plp, PoolVault},
    protocol_config::ProtocolConfig,
    registry::{Self as predict_registry, Registry}
};
use propbook::registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap};
use sui::{
    accumulator::{Self as accumulator, AccumulatorRoot},
    clock::{Self as clock, Clock},
    test_scenario::{Self as test, Scenario, return_shared}
};

public struct World {
    scenario: Scenario,
    registry_id: ID,
    config_id: ID,
    vault_id: ID,
    account_registry_id: ID,
    oracle_registry_id: ID,
    accumulator_root_id: ID,
}

public struct OwnedResources {
    clock: Clock,
}

/// Initialize every shared protocol root. The first transaction must be the
/// system sender required by Sui's accumulator test constructor; initialization
/// then advances to `admin` and performs one identity-capture transaction.
public fun new(system_sender: address, admin: address, now_ms: u64): (World, OwnedResources) {
    let mut scenario = test::begin(system_sender);
    accumulator::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    account_registry::init_for_testing(scenario.ctx());
    let vault_id = plp::init_for_testing(scenario.ctx());
    let registry_id = predict_registry::init_for_testing(scenario.ctx());
    propbook_registry::init_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now_ms);

    scenario.next_tx(admin);
    let config = scenario.take_shared<ProtocolConfig>();
    let config_id = config.id();
    return_shared(config);
    let account_registry = scenario.take_shared<AccountRegistry>();
    let account_registry_id = object::id(&account_registry);
    return_shared(account_registry);
    let oracle_registry = scenario.take_shared<OracleRegistry>();
    let oracle_registry_id = oracle_registry.id();
    return_shared(oracle_registry);
    let accumulator_root = scenario.take_shared<AccumulatorRoot>();
    let accumulator_root_id = object::id(&accumulator_root);
    return_shared(accumulator_root);
    scenario.next_tx(admin);

    (
        World {
            scenario,
            registry_id,
            config_id,
            vault_id,
            account_registry_id,
            oracle_registry_id,
            accumulator_root_id,
        },
        OwnedResources { clock },
    )
}

public fun sender(world: &mut World): address { world.scenario.ctx().sender() }

public fun registry_id(world: &World): ID { world.registry_id }

public fun config_id(world: &World): ID { world.config_id }

public fun vault_id(world: &World): ID { world.vault_id }

public fun account_registry_id(world: &World): ID { world.account_registry_id }

public fun oracle_registry_id(world: &World): ID { world.oracle_registry_id }

public fun accumulator_root_id(world: &World): ID { world.accumulator_root_id }

public fun clock(resources: &OwnedResources): &Clock { &resources.clock }

public fun clock_mut(resources: &mut OwnedResources): &mut Clock {
    &mut resources.clock
}

public fun take_predict_admin_cap(world: &World): AdminCap {
    world.scenario.take_from_sender<AdminCap>()
}

public fun take_account_admin_cap(world: &World): AccountAdminCap {
    world.scenario.take_from_sender<AccountAdminCap>()
}

public fun return_account_admin_cap(world: &World, cap: AccountAdminCap) {
    world.scenario.return_to_sender(cap);
}

public fun return_predict_admin_cap(world: &World, cap: AdminCap) {
    world.scenario.return_to_sender(cap);
}

public fun take_propbook_admin_cap(world: &World): RegistryAdminCap {
    world.scenario.take_from_sender<RegistryAdminCap>()
}

public fun return_propbook_admin_cap(world: &World, cap: RegistryAdminCap) {
    world.scenario.return_to_sender(cap);
}

public fun take_lifecycle_cap(world: &World, id: ID): MarketLifecycleCap {
    world.scenario.take_from_sender_by_id<MarketLifecycleCap>(id)
}

public fun return_lifecycle_cap(world: &World, cap: MarketLifecycleCap) {
    world.scenario.return_to_sender(cap);
}

public fun take_pause_cap(world: &World, id: ID): PauseCap {
    world.scenario.take_from_sender_by_id<PauseCap>(id)
}

public fun return_pause_cap(world: &World, cap: PauseCap) {
    world.scenario.return_to_sender(cap);
}

public fun ctx(world: &mut World): &mut TxContext { world.scenario.ctx() }

public fun next_tx(world: &mut World, sender: address) {
    world.scenario.next_tx(sender);
}

public fun next_tx_with_gas_price(world: &mut World, sender: address, gas_price: u64) {
    let epoch = world.scenario.ctx().epoch();
    let epoch_timestamp_ms = world.scenario.ctx().epoch_timestamp_ms();
    let reference_gas_price = world.scenario.ctx().reference_gas_price();
    let builder = test::ctx_builder_from_sender(sender)
        .set_epoch(epoch)
        .set_epoch_timestamp(epoch_timestamp_ms)
        .set_reference_gas_price(reference_gas_price)
        .set_gas_price(gas_price);
    world.scenario.next_with_context(builder);
}

public fun next_tx_with_epoch(world: &mut World, sender: address, epoch: u64) {
    let epoch_timestamp_ms = world.scenario.ctx().epoch_timestamp_ms();
    let reference_gas_price = world.scenario.ctx().reference_gas_price();
    let gas_price = world.scenario.ctx().gas_price();
    let builder = test::ctx_builder_from_sender(sender)
        .set_epoch(epoch)
        .set_epoch_timestamp(epoch_timestamp_ms)
        .set_reference_gas_price(reference_gas_price)
        .set_gas_price(gas_price);
    world.scenario.next_with_context(builder);
}

public fun take_registry(world: &World): Registry {
    world.scenario.take_shared_by_id<Registry>(world.registry_id)
}

public fun take_config(world: &World): ProtocolConfig {
    world.scenario.take_shared_by_id<ProtocolConfig>(world.config_id)
}

public fun take_vault(world: &World): PoolVault {
    world.scenario.take_shared_by_id<PoolVault>(world.vault_id)
}

public fun take_account_registry(world: &World): AccountRegistry {
    world.scenario.take_shared_by_id<AccountRegistry>(world.account_registry_id)
}

public fun take_oracle_registry(world: &World): OracleRegistry {
    world.scenario.take_shared_by_id<OracleRegistry>(world.oracle_registry_id)
}

public fun take_accumulator_root(world: &World): AccumulatorRoot {
    world.scenario.take_shared_by_id<AccumulatorRoot>(world.accumulator_root_id)
}

public fun take_shared_by_id<T: key>(world: &World, id: ID): T {
    world.scenario.take_shared_by_id<T>(id)
}

public fun finish(world: World, resources: OwnedResources) {
    let World { scenario, .. } = world;
    let OwnedResources { clock } = resources;
    clock.destroy_for_testing();
    scenario.end();
}
