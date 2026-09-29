// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admits market deployers and stores the admin minimum claim window.
/// Package init mints AdminCap and transfers it to the publisher.
module venue::deployer_registry;

use sui::{event, table::{Self, Table}, vec_set::{Self, VecSet}};
use venue::{
    admin::{Self, AdminCap},
    deployer_admin::{Self, DeployerAdminCap},
    publisher::{Self, PublisherCap},
};

const EBps: u64 = 0;
const EUnknownType: u64 = 1;
const EUnknownDeployer: u64 = 2;
const EVaultExists: u64 = 3;
const EStopped: u64 = 4;
const ETypeMissing: u64 = 5;

const BPS: u64 = 10_000;
const DEFAULT_MIN_CLAIM_WINDOW_MS: u64 = 86_400_000;

public struct DeployerRegistry has key {
    id: UID,
    min_claim_window_ms: u64,
    deployers: Table<ID, Deployer>,
    types: Table<ID, vector<u8>>,
}

public struct Deployer has store {
    admin: address,
    type_ids: VecSet<ID>,
    enclave_ids: VecSet<ID>,
    vault_id: Option<ID>,
    vault_cap: u64,
    fee_public_key: vector<u8>,
    fee_recipient: address,
    enclave_required: bool,
    wallet_fee_bps: u64,
    withdraw_share_bps: u64,
    deposit_fee_bps: u64,
    rebalance_bps: u64,
    market_cap_ceiling: Option<u64>,
    paused: bool,
    stopped: bool,
}

public struct DeployerAdmitted has copy, drop {
    deployer_id: ID,
    admin: address,
    sender: address,
}

public struct MinClaimWindowSet has copy, drop {
    min_claim_window_ms: u64,
    sender: address,
}

fun init(ctx: &mut TxContext) {
    let registry = DeployerRegistry {
        id: object::new(ctx),
        min_claim_window_ms: DEFAULT_MIN_CLAIM_WINDOW_MS,
        deployers: table::new(ctx),
        types: table::new(ctx),
    };
    transfer::share_object(registry);
    transfer::public_transfer(admin::new(ctx), ctx.sender());
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Returns the earliest claim window Publish may store.
public fun min_claim_window_ms(registry: &DeployerRegistry): u64 {
    registry.min_claim_window_ms
}

/// Sets the earliest claim window Publish may store.
public fun set_min_claim_window(
    registry: &mut DeployerRegistry,
    _cap: &AdminCap,
    min_claim_window_ms: u64,
    ctx: &TxContext,
) {
    registry.min_claim_window_ms = min_claim_window_ms;
    event::emit(MinClaimWindowSet { min_claim_window_ms, sender: ctx.sender() });
}

/// Inserts the deployer row and transfers both caps to `admin`.
/// `deployer_vault::admit` is the external call. It shares the vault.
public(package) fun admit(
    registry: &mut DeployerRegistry,
    _cap: &AdminCap,
    admin: address,
    type_ids: vector<ID>,
    enclave_ids: vector<ID>,
    vault_cap: u64,
    fee_public_key: vector<u8>,
    fee_recipient: address,
    wallet_fee_bps: u64,
    withdraw_share_bps: u64,
    deposit_fee_bps: u64,
    rebalance_bps: u64,
    market_cap_ceiling: Option<u64>,
    ctx: &mut TxContext,
): ID {
    assert_bps(wallet_fee_bps);
    assert_bps(withdraw_share_bps);
    assert_bps(deposit_fee_bps);
    assert_bps(rebalance_bps);
    let mut i = 0;
    while (i < type_ids.length()) {
        assert!(registry.types.contains(type_ids[i]), EUnknownType);
        i = i + 1;
    };
    let uid = object::new(ctx);
    let deployer_id = uid.to_inner();
    uid.delete();
    registry.deployers.add(
        deployer_id,
        Deployer {
            admin,
            type_ids: to_set(&type_ids),
            enclave_ids: to_set(&enclave_ids),
            vault_id: option::none(),
            vault_cap,
            fee_public_key,
            fee_recipient,
            enclave_required: false,
            wallet_fee_bps,
            withdraw_share_bps,
            deposit_fee_bps,
            rebalance_bps,
            market_cap_ceiling,
            paused: false,
            stopped: false,
        },
    );
    publisher::transfer_to(publisher::mint(deployer_id, ctx), admin);
    deployer_admin::transfer_to(deployer_admin::mint(deployer_id, ctx), admin);
    event::emit(DeployerAdmitted { deployer_id, admin, sender: ctx.sender() });
    deployer_id
}

/// Replaces the deployer's allowlists, fee terms, and ceilings.
public fun update(
    registry: &mut DeployerRegistry,
    _cap: &AdminCap,
    deployer_id: ID,
    type_ids: vector<ID>,
    enclave_ids: vector<ID>,
    vault_cap: u64,
    fee_public_key: vector<u8>,
    fee_recipient: address,
    wallet_fee_bps: u64,
    withdraw_share_bps: u64,
    deposit_fee_bps: u64,
    rebalance_bps: u64,
    market_cap_ceiling: Option<u64>,
) {
    assert_bps(wallet_fee_bps);
    assert_bps(withdraw_share_bps);
    assert_bps(deposit_fee_bps);
    assert_bps(rebalance_bps);
    let mut i = 0;
    while (i < type_ids.length()) {
        assert!(registry.types.contains(type_ids[i]), EUnknownType);
        i = i + 1;
    };
    let deployer = registry.borrow_mut(deployer_id);
    deployer.type_ids = to_set(&type_ids);
    deployer.enclave_ids = to_set(&enclave_ids);
    deployer.vault_cap = vault_cap;
    deployer.fee_public_key = fee_public_key;
    deployer.fee_recipient = fee_recipient;
    deployer.wallet_fee_bps = wallet_fee_bps;
    deployer.withdraw_share_bps = withdraw_share_bps;
    deployer.deposit_fee_bps = deposit_fee_bps;
    deployer.rebalance_bps = rebalance_bps;
    deployer.market_cap_ceiling = market_cap_ceiling;
}

/// Stops new markets and new deposits for this deployer.
public fun stop(registry: &mut DeployerRegistry, _cap: &AdminCap, deployer_id: ID) {
    registry.borrow_mut(deployer_id).stopped = true;
}

/// Blocks opens, exits, and new markets while set.
public fun pause(registry: &mut DeployerRegistry, _cap: &AdminCap, deployer_id: ID) {
    registry.borrow_mut(deployer_id).paused = true;
}

/// Clears the deployer pause flag.
public fun resume(registry: &mut DeployerRegistry, _cap: &AdminCap, deployer_id: ID) {
    registry.borrow_mut(deployer_id).paused = false;
}

/// Removes a stopped deployer that has no vault.
public fun remove(registry: &mut DeployerRegistry, _cap: &AdminCap, deployer_id: ID) {
    assert!(registry.stopped(deployer_id), EStopped);
    assert!(registry.vault_id(deployer_id).is_none(), EVaultExists);
    let Deployer { .. } = registry.deployers.remove(deployer_id);
}

public fun vault_id(registry: &DeployerRegistry, deployer_id: ID): Option<ID> {
    registry.borrow(deployer_id).vault_id
}

public fun rebalance_bps(registry: &DeployerRegistry, deployer_id: ID): u64 {
    registry.borrow(deployer_id).rebalance_bps
}

public fun wallet_fee_bps(registry: &DeployerRegistry, deployer_id: ID): u64 {
    registry.borrow(deployer_id).wallet_fee_bps
}

public fun withdraw_share_bps(registry: &DeployerRegistry, deployer_id: ID): u64 {
    registry.borrow(deployer_id).withdraw_share_bps
}

public fun deposit_fee_bps(registry: &DeployerRegistry, deployer_id: ID): u64 {
    registry.borrow(deployer_id).deposit_fee_bps
}

public fun fee_public_key(registry: &DeployerRegistry, deployer_id: ID): vector<u8> {
    registry.borrow(deployer_id).fee_public_key
}

public fun enclave_required(registry: &DeployerRegistry, deployer_id: ID): bool {
    registry.borrow(deployer_id).enclave_required
}

/// Turns Nautilus settlement on or off for this deployer.
/// Off means the publisher cap settles. On means Settle accepts only the enclave stored at Publish.
public fun set_enclave_required(
    registry: &mut DeployerRegistry,
    _cap: &AdminCap,
    deployer_id: ID,
    required: bool,
) {
    registry.borrow_mut(deployer_id).enclave_required = required;
}

public fun fee_recipient(registry: &DeployerRegistry, deployer_id: ID): address {
    registry.borrow(deployer_id).fee_recipient
}

public fun vault_cap(registry: &DeployerRegistry, deployer_id: ID): u64 {
    registry.borrow(deployer_id).vault_cap
}

public fun paused(registry: &DeployerRegistry, deployer_id: ID): bool {
    registry.borrow(deployer_id).paused
}

public fun stopped(registry: &DeployerRegistry, deployer_id: ID): bool {
    registry.borrow(deployer_id).stopped
}

public fun has_enclave(registry: &DeployerRegistry, deployer_id: ID, enclave_id: ID): bool {
    registry.borrow(deployer_id).enclave_ids.contains(&enclave_id)
}

public fun has_type(registry: &DeployerRegistry, deployer_id: ID, type_id: ID): bool {
    registry.borrow(deployer_id).type_ids.contains(&type_id)
}

public fun type_exists(registry: &DeployerRegistry, type_id: ID): bool {
    registry.types.contains(type_id)
}

public fun market_cap_ceiling(registry: &DeployerRegistry, deployer_id: ID): Option<u64> {
    registry.borrow(deployer_id).market_cap_ceiling
}

public(package) fun add_type(
    registry: &mut DeployerRegistry,
    name: vector<u8>,
    ctx: &mut TxContext,
): ID {
    let uid = object::new(ctx);
    let type_id = uid.to_inner();
    uid.delete();
    registry.types.add(type_id, name);
    type_id
}

public(package) fun delete_type(registry: &mut DeployerRegistry, type_id: ID): vector<u8> {
    assert!(registry.types.contains(type_id), ETypeMissing);
    registry.types.remove(type_id)
}

public(package) fun attach_vault(registry: &mut DeployerRegistry, deployer_id: ID, vault_id: ID) {
    let deployer = registry.borrow_mut(deployer_id);
    assert!(!deployer.stopped, EStopped);
    assert!(deployer.vault_id.is_none(), EVaultExists);
    deployer.vault_id = option::some(vault_id);
}

fun borrow(registry: &DeployerRegistry, deployer_id: ID): &Deployer {
    assert!(registry.deployers.contains(deployer_id), EUnknownDeployer);
    registry.deployers.borrow(deployer_id)
}

fun borrow_mut(registry: &mut DeployerRegistry, deployer_id: ID): &mut Deployer {
    assert!(registry.deployers.contains(deployer_id), EUnknownDeployer);
    registry.deployers.borrow_mut(deployer_id)
}

fun assert_bps(bps: u64) {
    assert!(bps <= BPS, EBps);
}

fun to_set(ids: &vector<ID>): VecSet<ID> {
    let mut set = vec_set::empty();
    let mut i = 0;
    while (i < ids.length()) {
        set.insert(ids[i]);
        i = i + 1;
    };
    set
}
