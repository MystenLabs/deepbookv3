// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use anyhow::{anyhow, Result};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use std::str::FromStr;
use sui_types::{
    base_types::{ObjectID, ObjectRef, SequenceNumber, SuiAddress},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, TransactionKind},
    type_input::TypeInput,
    TypeTag,
};

const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";
const MARGIN_POOL_MODULE: &str = "margin_pool";
const MARGIN_REGISTRY_MODULE: &str = "margin_registry";

/// Normalize asset type by ensuring the address has a 0x prefix.
pub fn normalize_asset_type(asset_type: &str) -> String {
    if asset_type.starts_with("0x") || asset_type.starts_with("0X") {
        asset_type.to_string()
    } else {
        format!("0x{}", asset_type)
    }
}

/// Build a deposit PTB (Programmable Transaction Block) for margin lending.
///
/// Commands:
/// 0. placeholder::coin<Asset>() → Coin (Slush wallet replaces with actual coin sourcing)
/// 1. mint_supplier_cap(registry, clock) → SupplierCap
/// 2. supply<Asset>(pool, registry, &supplier_cap, coin, option::none(), clock) → u64
/// 3. TransferObjects([SupplierCap], sender)
pub fn build_deposit_ptb(
    margin_package_id: &str,
    pool_id: &str,
    pool_initial_shared_version: u64,
    registry_id: &str,
    registry_initial_shared_version: u64,
    asset_type: &str,
    sender: &str,
) -> Result<String> {
    let package_id = ObjectID::from_hex_literal(margin_package_id)
        .map_err(|e| anyhow!("Invalid margin package ID: {}", e))?;
    let pool_object_id =
        ObjectID::from_hex_literal(pool_id).map_err(|e| anyhow!("Invalid pool ID: {}", e))?;
    let registry_object_id = ObjectID::from_hex_literal(registry_id)
        .map_err(|e| anyhow!("Invalid registry ID: {}", e))?;
    let sender_address =
        SuiAddress::from_str(sender).map_err(|e| anyhow!("Invalid sender address: {}", e))?;
    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    let normalized_asset = normalize_asset_type(asset_type);
    let type_tag = TypeTag::from_str(&normalized_asset)
        .map_err(|e| anyhow!("Invalid asset type '{}': {}", normalized_asset, e))?;
    let type_input = TypeInput::from(type_tag);

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: Pool (shared mutable - supply mutates pool state)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: pool_object_id,
        initial_shared_version: SequenceNumber::from_u64(pool_initial_shared_version),
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 1: Registry (shared immutable)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: registry_object_id,
        initial_shared_version: SequenceNumber::from_u64(registry_initial_shared_version),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // Input 2: Clock (shared immutable, initial_shared_version = 1)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // Input 3: sender (pure address for TransferObjects)
    ptb.input(CallArg::Pure(bcs::to_bytes(&sender_address)?))?;

    // Input 4: Option::None for referral parameter
    // option::none() is represented as BCS-serialized Option<ObjectID>::None = vec![0]
    ptb.input(CallArg::Pure(vec![0]))?;

    // Command 0: Placeholder coin<Asset>() - Slush wallet replaces this
    let placeholder_package = ObjectID::from_hex_literal("0x0")?;
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: placeholder_package,
        module: "placeholder".to_string(),
        function: "coin".to_string(),
        type_arguments: vec![type_input.clone()],
        arguments: vec![],
    })));

    // Command 1: mint_supplier_cap(registry, clock) → SupplierCap
    // FIX for PR#870 bug (a): includes registry argument
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: package_id,
        module: MARGIN_REGISTRY_MODULE.to_string(),
        function: "mint_supplier_cap".to_string(),
        type_arguments: vec![],
        arguments: vec![
            Argument::Input(1), // registry
            Argument::Input(2), // clock
        ],
    })));

    // Command 2: supply<Asset>(pool, registry, &supplier_cap, coin, option::none(), clock) → u64
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: package_id,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "supply".to_string(),
        type_arguments: vec![type_input],
        arguments: vec![
            Argument::Input(0),  // pool
            Argument::Input(1),  // registry
            Argument::Result(1), // supplier_cap (from mint_supplier_cap)
            Argument::Result(0), // coin (from placeholder)
            Argument::Input(4),  // option::none() referral
            Argument::Input(2),  // clock
        ],
    })));

    // Command 3: TransferObjects([SupplierCap], sender)
    // FIX for PR#870 bug (b): transfers the minted SupplierCap to the sender
    ptb.command(Command::TransferObjects(
        vec![Argument::Result(1)], // SupplierCap from mint_supplier_cap
        Argument::Input(3),        // sender address
    ));

    let builder = ptb.finish();
    let tx_kind = TransactionKind::ProgrammableTransaction(builder);
    let bytes = bcs::to_bytes(&tx_kind)?;
    Ok(BASE64_STANDARD.encode(bytes))
}

/// Build a withdraw PTB for margin lending.
///
/// Commands:
/// 0. withdraw<Asset>(pool, registry, &supplier_cap, amount_option, clock) → Coin<Asset>
/// 1. TransferObjects([Coin<Asset>], sender)
pub fn build_withdraw_ptb(
    margin_package_id: &str,
    pool_id: &str,
    pool_initial_shared_version: u64,
    registry_id: &str,
    registry_initial_shared_version: u64,
    supplier_cap_ref: ObjectRef,
    asset_type: &str,
    amount: Option<u64>,
    sender: &str,
) -> Result<String> {
    let package_id = ObjectID::from_hex_literal(margin_package_id)
        .map_err(|e| anyhow!("Invalid margin package ID: {}", e))?;
    let pool_object_id =
        ObjectID::from_hex_literal(pool_id).map_err(|e| anyhow!("Invalid pool ID: {}", e))?;
    let registry_object_id = ObjectID::from_hex_literal(registry_id)
        .map_err(|e| anyhow!("Invalid registry ID: {}", e))?;
    let sender_address =
        SuiAddress::from_str(sender).map_err(|e| anyhow!("Invalid sender address: {}", e))?;
    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    let normalized_asset = normalize_asset_type(asset_type);
    let type_tag = TypeTag::from_str(&normalized_asset)
        .map_err(|e| anyhow!("Invalid asset type '{}': {}", normalized_asset, e))?;
    let type_input = TypeInput::from(type_tag);

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: Pool (shared mutable - withdraw mutates pool state)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: pool_object_id,
        initial_shared_version: SequenceNumber::from_u64(pool_initial_shared_version),
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 1: Registry (shared immutable)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: registry_object_id,
        initial_shared_version: SequenceNumber::from_u64(registry_initial_shared_version),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // Input 2: SupplierCap (ImmOrOwnedObject - owned by the user)
    ptb.input(CallArg::Object(ObjectArg::ImmOrOwnedObject(
        supplier_cap_ref,
    )))?;

    // Input 3: Clock (shared immutable, initial_shared_version = 1)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // Input 4: amount (Option<u64>)
    ptb.input(CallArg::Pure(bcs::to_bytes(&amount)?))?;

    // Input 5: sender address (pure)
    ptb.input(CallArg::Pure(bcs::to_bytes(&sender_address)?))?;

    // Command 0: withdraw<Asset>(pool, registry, &supplier_cap, amount_option, clock) → Coin<Asset>
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: package_id,
        module: MARGIN_POOL_MODULE.to_string(),
        function: "withdraw".to_string(),
        type_arguments: vec![type_input],
        arguments: vec![
            Argument::Input(0), // pool
            Argument::Input(1), // registry
            Argument::Input(2), // supplier_cap
            Argument::Input(4), // amount option
            Argument::Input(3), // clock
        ],
    })));

    // Command 1: TransferObjects([Coin<Asset>], sender)
    // FIX for PR#870 bug (c): transfers the returned Coin to the sender
    ptb.command(Command::TransferObjects(
        vec![Argument::Result(0)], // Coin<Asset> from withdraw
        Argument::Input(5),        // sender address
    ));

    let builder = ptb.finish();
    let tx_kind = TransactionKind::ProgrammableTransaction(builder);
    let bytes = bcs::to_bytes(&tx_kind)?;
    Ok(BASE64_STANDARD.encode(bytes))
}
