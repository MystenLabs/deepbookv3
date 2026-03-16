/// Example: Deposit coins into a BalanceManager.
///
/// Automatically uses the active env and address from `sui client`.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  CONFIGURE YOUR DEPOSIT HERE                                    │
/// ├─────────────────────────────────────────────────────────────────┤
/// │  DEPOSIT_COIN  — coin name: "SUI", "USDC", "DEEP", etc.       │
/// │  DEPOSIT_AMOUNT — human-readable amount (e.g. 10.0 = 10 SUI)   │
/// └─────────────────────────────────────────────────────────────────┘
///
/// Required environment variables:
///   BALANCE_MANAGER_ID - Your BalanceManager shared object ID
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

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURE YOUR DEPOSIT HERE
// ═══════════════════════════════════════════════════════════════════════

/// Which coin to deposit. Use the short name: "SUI", "USDC", "DEEP", etc.
const DEPOSIT_COIN: &str = "SUI";

/// How much to deposit (human-readable). 10.0 = 10 tokens.
const DEPOSIT_AMOUNT: f64 = 10.0;

// ═══════════════════════════════════════════════════════════════════════

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

    let coin = get_coin(&active.alias, DEPOSIT_COIN).ok_or_else(|| {
        anyhow!(
            "Unknown coin '{}' on {}. Check constants.rs for available coins.",
            DEPOSIT_COIN,
            active.alias
        )
    })?;

    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;
    let deposit_on_chain = convert_quantity(DEPOSIT_AMOUNT, &coin);

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
        "Deposit: {} {} ({} on-chain)",
        DEPOSIT_AMOUNT, DEPOSIT_COIN, deposit_on_chain
    );

    // ── 4. Build the PTB ────────────────────────────────────────────────
    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: BalanceManager (&mut)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Get the coin to deposit.
    //
    // For SUI: split from the gas coin (always available).
    // For other coins: fetch a Coin<T> object from the sender's wallet and
    //   split the needed amount from it.
    let deposit_coin_arg = if coin.is_sui() {
        // SplitCoins(GasCoin, [amount]) → Coin<SUI>
        let amount = ptb.pure(deposit_on_chain)?;
        ptb.command(Command::SplitCoins(Argument::GasCoin, vec![amount]));
        Argument::Result(0)
    } else {
        // Fetch a Coin<T> from the wallet
        let coin_type_tag = TypeTag::from_str(coin.coin_type)?;
        let wallet_coins = sui
            .coin_read_api()
            .get_coins(sender, Some(coin_type_tag.to_string()), None, None)
            .await?;
        let source_coin = wallet_coins.data.into_iter().next().ok_or_else(|| {
            anyhow!(
                "No {} coins found in wallet for {sender}",
                DEPOSIT_COIN
            )
        })?;

        // Add the coin object as an owned input
        let coin_ref = source_coin.object_ref();
        ptb.input(CallArg::Object(ObjectArg::ImmOrOwnedObject(coin_ref)))?;

        // SplitCoins(Input(1), [amount]) → Coin<T>
        let amount = ptb.pure(deposit_on_chain)?;
        ptb.command(Command::SplitCoins(Argument::Input(1), vec![amount]));
        Argument::Result(0)
    };

    // Call balance_manager::deposit<T>(bm, coin, ctx)
    let coin_type_input = TypeInput::from(TypeTag::from_str(coin.coin_type)?);

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "deposit".to_string(),
        type_arguments: vec![coin_type_input],
        arguments: vec![
            Argument::Input(0), // balance_manager
            deposit_coin_arg,   // coin from SplitCoins
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
