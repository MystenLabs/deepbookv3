// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Owns one Predict test scenario and the stable identities of its shared roots.
/// Shared objects stay in scenario inventory; `OwnedResources` holds only the
/// initialization artifacts that must survive across transactions and teardown.
#[test_only]
module deepbook_predict::test_world;

use account::account_registry::{Self as account_registry, AccountAdminCap, AccountRegistry};
use deepbook_predict::{
    admin::AdminCap,
    plp::{Self as plp, PLP, PoolVault},
    protocol_config::ProtocolConfig,
    registry::{Self as predict_registry, Registry}
};
use propbook::registry::{Self as propbook_registry, OracleRegistry, RegistryAdminCap};
use std::unit_test::destroy;
use sui::{
    accumulator::{Self as accumulator, AccumulatorRoot},
    clock::{Self as clock, Clock},
    coin_registry::MetadataCap,
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
    predict_admin_cap: AdminCap,
    account_admin_cap: AccountAdminCap,
    propbook_admin_cap: RegistryAdminCap,
    plp_metadata_cap: MetadataCap<PLP>,
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
    let account_admin_cap = scenario.take_from_sender<AccountAdminCap>();
    let predict_admin_cap = scenario.take_from_sender<AdminCap>();
    let propbook_admin_cap = scenario.take_from_sender<RegistryAdminCap>();
    let plp_metadata_cap = scenario.take_from_sender<MetadataCap<PLP>>();

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
        OwnedResources {
            clock,
            predict_admin_cap,
            account_admin_cap,
            propbook_admin_cap,
            plp_metadata_cap,
        },
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

public fun predict_admin_cap(resources: &OwnedResources): &AdminCap {
    &resources.predict_admin_cap
}

public fun propbook_admin_cap(resources: &OwnedResources): &RegistryAdminCap {
    &resources.propbook_admin_cap
}

public fun ctx(world: &mut World): &mut TxContext { world.scenario.ctx() }

public fun next_tx(world: &mut World, sender: address) {
    world.scenario.next_tx(sender);
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
    let OwnedResources {
        clock,
        predict_admin_cap,
        account_admin_cap,
        propbook_admin_cap,
        plp_metadata_cap,
    } = resources;
    clock.destroy_for_testing();
    destroy(plp_metadata_cap);
    destroy(propbook_admin_cap);
    destroy(account_admin_cap);
    destroy(predict_admin_cap);
    scenario.end();
}
