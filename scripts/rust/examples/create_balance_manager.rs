/// Example: Create a new BalanceManager and publicly share it.
///
/// This is typically the first step before placing orders on DeepBook.
/// The BalanceManager holds your balances for trading across all pools.
///
/// The PTB does two things:
///   1. Call `balance_manager::new()` → returns a BalanceManager value
///   2. Call `transfer::public_share_object<BalanceManager>(bm)` to share it
///
/// After execution, the new BalanceManager object ID is printed. Save it —
/// you'll need it for `place_limit_order` and other operations.
///
/// Automatically uses the active env and address from `sui client`.
///
/// Optional environment variables:
///   GAS_BUDGET - Gas budget in MIST (default: 1_000_000_000 = 1 SUI)
///
/// Usage:
///   cargo run --example create_balance_manager
use std::str::FromStr;

use anyhow::{anyhow, Result};
use deepbook_scripts::constants::*;
use deepbook_scripts::sui_utils::get_active_env;
use shared_crypto::intent::Intent;
use sui_config::{sui_config_dir, SUI_KEYSTORE_FILENAME};
use sui_keys::keystore::{AccountKeystore, FileBasedKeystore};
use sui_sdk::{
    rpc_types::{SuiTransactionBlockEffectsAPI, SuiTransactionBlockResponseOptions},
    types::{
        base_types::ObjectID,
        programmable_transaction_builder::ProgrammableTransactionBuilder,
        transaction::{Argument, Command, ProgrammableMoveCall, Transaction, TransactionData},
        type_input::TypeInput,
        TypeTag,
    },
    SuiClientBuilder,
};

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

#[tokio::main]
async fn main() -> Result<()> {
    // ── 1. Read active env from ~/.sui/sui_config/client.yaml ───────────
    let active = get_active_env()?;
    let package_ids = match active.alias.as_str() {
        "mainnet" => MAINNET_PACKAGE_IDS,
        "testnet" => TESTNET_PACKAGE_IDS,
        other => return Err(anyhow!("Unsupported network '{}'. Expected 'mainnet' or 'testnet'.", other)),
    };
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;

    // ── 2. Connect to Sui RPC ───────────────────────────────────────────
    let sui = SuiClientBuilder::default().build(&active.rpc).await?;
    println!("Network: {}", active.alias);
    println!("RPC: {}", active.rpc);
    println!("Sender (active address): {}", active.address);

    // ── 3. Load keystore for signing ────────────────────────────────────
    let keystore_path = sui_config_dir()?.join(SUI_KEYSTORE_FILENAME);
    let keystore = FileBasedKeystore::load_or_create(&keystore_path)?;

    // ── 4. Parse package ID ─────────────────────────────────────────────
    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;

    // ── 5. Build the PTB ────────────────────────────────────────────────
    let mut ptb = ProgrammableTransactionBuilder::new();

    // Command 0: balance_manager::new(ctx) → BalanceManager
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "new".to_string(),
        type_arguments: vec![],
        arguments: vec![],
    })));

    // Command 1: transfer::public_share_object<BalanceManager>(bm)
    let balance_manager_type = TypeInput::from(TypeTag::from_str(&format!(
        "{}::balance_manager::BalanceManager",
        package_ids.deepbook_package_id
    ))?);

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: ObjectID::from_hex_literal(
            "0x0000000000000000000000000000000000000000000000000000000000000002",
        )?,
        module: "transfer".to_string(),
        function: "public_share_object".to_string(),
        type_arguments: vec![balance_manager_type],
        arguments: vec![
            Argument::Result(0), // BalanceManager from command 0
        ],
    })));

    let builder = ptb.finish();

    // ── 6. Build TransactionData ────────────────────────────────────────
    let sender = active.address;
    let coins = sui
        .coin_read_api()
        .get_coins(sender, None, None, None)
        .await?;
    let gas_coin = coins
        .data
        .into_iter()
        .next()
        .ok_or_else(|| anyhow!("No gas coins found for {sender}"))?;

    let gas_price = sui.read_api().get_reference_gas_price().await?;

    let tx_data = TransactionData::new_programmable(
        sender,
        vec![gas_coin.object_ref()],
        builder,
        gas_budget,
        gas_price,
    );
    println!(
        "Gas budget: {} MIST ({:.4} SUI)",
        gas_budget,
        gas_budget as f64 / 1e9
    );

    // ── 7. Sign ─────────────────────────────────────────────────────────
    let signature = keystore
        .sign_secure(&sender, &tx_data, Intent::sui_transaction())
        .await?;

    // ── 8. Execute ──────────────────────────────────────────────────────
    println!("Executing transaction...");
    let response = sui
        .quorum_driver_api()
        .execute_transaction_block(
            Transaction::from_data(tx_data, vec![signature]),
            SuiTransactionBlockResponseOptions::full_content(),
            None,
        )
        .await?;

    println!("Transaction executed successfully!");
    println!("Digest: {}", response.digest);

    if let Some(effects) = &response.effects {
        println!("Status: {:?}", effects.status());
        println!(
            "Gas used: {} MIST",
            effects.gas_cost_summary().computation_cost
                + effects.gas_cost_summary().storage_cost
                - effects.gas_cost_summary().storage_rebate
        );

        let created = effects.created();
        for obj_ref in created {
            println!("Created object: {}", obj_ref.object_id());
            println!(
                "  → Use this as BALANCE_MANAGER_ID for place_limit_order"
            );
        }
    }

    Ok(())
}
