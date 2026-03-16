/// Example: Deposit SUI into a BalanceManager.
///
/// The PTB does two things:
///   1. Split 10 SUI from the gas coin → Coin<SUI>
///   2. Call `balance_manager::deposit<SUI>(bm, coin, ctx)`
///
/// Automatically uses the active env and address from `sui client`.
///
/// Required environment variables:
///   BALANCE_MANAGER_ID - Your BalanceManager shared object ID
///
/// Optional environment variables:
///   GAS_BUDGET - Gas budget in MIST (default: 1_000_000_000 = 1 SUI)
///
/// Usage:
///   BALANCE_MANAGER_ID=0x... cargo run --example deposit
use std::str::FromStr;

use anyhow::{anyhow, Result};
use deepbook_scripts::constants::*;
use deepbook_scripts::sui_utils::{get_active_env, get_shared_object_version};
use shared_crypto::intent::Intent;
use sui_config::{sui_config_dir, SUI_KEYSTORE_FILENAME};
use sui_keys::keystore::{AccountKeystore, FileBasedKeystore};
use sui_sdk::{
    rpc_types::{SuiTransactionBlockEffectsAPI, SuiTransactionBlockResponseOptions},
    types::{
        base_types::ObjectID,
        programmable_transaction_builder::ProgrammableTransactionBuilder,
        transaction::{
            Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, Transaction,
            TransactionData,
        },
        type_input::TypeInput,
        TypeTag,
    },
    SuiClientBuilder,
};

/// 10 SUI in MIST.
const DEPOSIT_AMOUNT: u64 = 10_000_000_000;

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn required_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| anyhow!("Missing required env var: {}", key))
}

#[tokio::main]
async fn main() -> Result<()> {
    // ── 1. Read active env ──────────────────────────────────────────────
    let active = get_active_env()?;
    let package_ids = match active.alias.as_str() {
        "mainnet" => MAINNET_PACKAGE_IDS,
        "testnet" => TESTNET_PACKAGE_IDS,
        other => {
            return Err(anyhow!(
                "Unsupported network '{}'. Expected 'mainnet' or 'testnet'.",
                other
            ))
        }
    };
    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;

    // ── 2. Connect to Sui RPC ───────────────────────────────────────────
    let sui = SuiClientBuilder::default().build(&active.rpc).await?;
    let sender = active.address;
    println!("Network: {}", active.alias);
    println!("RPC: {}", active.rpc);
    println!("Sender (active address): {sender}");

    let keystore_path = sui_config_dir()?.join(SUI_KEYSTORE_FILENAME);
    let keystore = FileBasedKeystore::load_or_create(&keystore_path)?;

    // ── 3. Parse object IDs and fetch shared versions ───────────────────
    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;
    let balance_manager_id = ObjectID::from_hex_literal(&balance_manager_id_str)?;
    let bm_version = get_shared_object_version(&sui, balance_manager_id).await?;

    println!("BalanceManager: {balance_manager_id_str}");
    println!(
        "Deposit amount: {} MIST ({:.4} SUI)",
        DEPOSIT_AMOUNT,
        DEPOSIT_AMOUNT as f64 / 1e9
    );

    // ── 4. Build the PTB ────────────────────────────────────────────────
    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: BalanceManager (&mut)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Command 0: SplitCoins(GasCoin, [amount]) → Coin<SUI>
    let amount = ptb.pure(DEPOSIT_AMOUNT)?;
    ptb.command(Command::SplitCoins(Argument::GasCoin, vec![amount]));

    // Command 1: balance_manager::deposit<SUI>(bm, coin, ctx)
    //
    // Move signature (packages/deepbook/sources/balance_manager.move:292):
    //   public fun deposit<T>(
    //       balance_manager: &mut BalanceManager,
    //       coin: Coin<T>,
    //       ctx: &mut TxContext,
    //   )
    let sui_type = TypeInput::from(TypeTag::from_str(
        "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
    )?);

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "deposit".to_string(),
        type_arguments: vec![sui_type],
        arguments: vec![
            Argument::Input(0),  // balance_manager
            Argument::Result(0), // coin from SplitCoins
        ],
    })));

    let builder = ptb.finish();

    // ── 5. Build TransactionData ────────────────────────────────────────
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

    // ── 6. Sign ─────────────────────────────────────────────────────────
    let signature = keystore
        .sign_secure(&sender, &tx_data, Intent::sui_transaction())
        .await?;

    // ── 7. Execute ──────────────────────────────────────────────────────
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
    }

    Ok(())
}
