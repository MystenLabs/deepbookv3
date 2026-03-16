/// Example: Place a limit order on DeepBook V3 using the Sui Rust SDK.
///
/// This demonstrates the full flow:
///   1. Fetch shared object versions from on-chain (no hardcoding needed)
///   2. Build a PTB with `generate_proof_as_owner` + `place_limit_order`
///   3. Sign with a local keystore
///   4. Execute on chain
///
/// Required environment variables:
///   BALANCE_MANAGER_ID   - Your BalanceManager shared object ID
///
/// Optional environment variables:
///   GAS_BUDGET           - Gas budget in MIST (default: 1_000_000_000 = 1 SUI)
///
/// Automatically uses the active env and address from `sui client`.
///
/// Usage (DEEP/SUI pool):
///   BALANCE_MANAGER_ID=0x... cargo run --example place_limit_order
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
        base_types::{ObjectID, SequenceNumber},
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

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn required_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| anyhow!("Missing required env var: {}", key))
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
    // ── 1. Read active env from ~/.sui/sui_config/client.yaml ───────────
    let active = get_active_env()?;
    let (package_ids, pool, base_coin, quote_coin) = match active.alias.as_str() {
        "mainnet" => (
            MAINNET_PACKAGE_IDS,
            MAINNET_POOL_DEEP_SUI,
            MAINNET_DEEP,
            MAINNET_SUI,
        ),
        "testnet" => (
            TESTNET_PACKAGE_IDS,
            TESTNET_POOL_DEEP_SUI,
            TESTNET_DEEP,
            TESTNET_SUI,
        ),
        other => return Err(anyhow!("Unsupported network '{}'. Expected 'mainnet' or 'testnet'.", other)),
    };

    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;

    // ── 2. Connect to Sui RPC ───────────────────────────────────────────
    let sui = SuiClientBuilder::default().build(&active.rpc).await?;
    println!("Network: {}", active.alias);
    println!("RPC: {}", active.rpc);
    println!("Sender (active address): {}", active.address);

    let sender = active.address;
    let keystore_path = sui_config_dir()?.join(SUI_KEYSTORE_FILENAME);
    let keystore = FileBasedKeystore::load_or_create(&keystore_path)?;

    // ── 4. Parse object IDs ─────────────────────────────────────────────
    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;
    let pool_id = ObjectID::from_hex_literal(pool.address)?;
    let balance_manager_id = ObjectID::from_hex_literal(&balance_manager_id_str)?;
    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    println!("Pool: {} ({}/{})", pool.address, pool.base_coin, pool.quote_coin);
    println!("BalanceManager: {balance_manager_id_str}");

    // ── 5. Fetch initial_shared_version for each shared object ──────────
    //
    // Rather than hardcoding these, we look them up on-chain. Each shared
    // object has a version stamped when it was first shared — the Sui
    // scheduler needs this to correctly sequence transactions.
    println!("Fetching shared object versions...");
    let pool_version = get_shared_object_version(&sui, pool_id).await?;
    let bm_version = get_shared_object_version(&sui, balance_manager_id).await?;
    println!("  Pool version: {:?}, BalanceManager version: {:?}", pool_version, bm_version);

    // ── 6. Build the Programmable Transaction Block ─────────────────────
    let mut ptb = ProgrammableTransactionBuilder::new();

    // --- Shared object inputs ---
    //
    // Shared objects need three pieces of info:
    //   - id: the object's address
    //   - initial_shared_version: fetched above from on-chain
    //   - mutability: Mutable if the Move function takes `&mut`, Immutable if `&`

    // Input 0: Pool<BaseAsset, QuoteAsset> (&mut — place_limit_order writes to it)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: pool_id,
        initial_shared_version: pool_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 1: BalanceManager (&mut — balances are debited/credited)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 2: Clock (&, immutable — used for timestamp checks)
    // The Clock is always at 0x6 and was shared at version 1 (genesis).
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // --- Type arguments: <BaseAsset, QuoteAsset> ---
    //
    // Parse the coin type strings into TypeTag, then wrap in TypeInput.
    // TypeInput doesn't implement FromStr directly, so we go through TypeTag.
    let base_type = TypeInput::from(TypeTag::from_str(base_coin.coin_type)?);
    let quote_type = TypeInput::from(TypeTag::from_str(quote_coin.coin_type)?);

    // --- Command 0: generate_proof_as_owner(balance_manager) → TradeProof ---
    //
    // This proves the sender owns the BalanceManager. The returned TradeProof
    // is passed into place_limit_order as authorization.
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "generate_proof_as_owner".to_string(),
        type_arguments: vec![],
        arguments: vec![Argument::Input(1)], // balance_manager
    })));

    // --- Pure inputs for order parameters ---
    //
    // These are scalar values serialized via BCS. ptb.pure() handles the
    // serialization for standard types (u8, u64, bool, etc.).
    let client_order_id = ptb.pure(1u64)?;
    let order_type = ptb.pure(NO_RESTRICTION)?;
    let self_matching_option = ptb.pure(SELF_MATCHING_ALLOWED)?;
    let price = ptb.pure(1_000_000u64)?; // price in quote lots
    let quantity = ptb.pure(10_000_000u64)?; // quantity in base lots
    let is_bid = ptb.pure(true)?; // true = buy, false = sell
    let pay_with_deep = ptb.pure(true)?; // pay fees in DEEP token
    let expire_timestamp = ptb.pure(MAX_TIMESTAMP)?; // no expiry

    // --- Command 1: place_limit_order<BaseAsset, QuoteAsset>(...) → OrderInfo ---
    //
    // Maps to the Move function signature at packages/deepbook/sources/pool.move:179
    //
    //   public fun place_limit_order<BaseAsset, QuoteAsset>(
    //       self: &mut Pool<BaseAsset, QuoteAsset>,   // Input(0) - pool
    //       balance_manager: &mut BalanceManager,      // Input(1) - balance_manager
    //       trade_proof: &TradeProof,                  // Result(0) - from command 0
    //       client_order_id: u64,
    //       order_type: u8,
    //       self_matching_option: u8,
    //       price: u64,
    //       quantity: u64,
    //       is_bid: bool,
    //       pay_with_deep: bool,
    //       expire_timestamp: u64,
    //       clock: &Clock,                             // Input(2) - clock
    //       ctx: &TxContext,                            // auto-injected by runtime
    //   ): OrderInfo
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "pool".to_string(),
        function: "place_limit_order".to_string(),
        type_arguments: vec![base_type, quote_type],
        arguments: vec![
            Argument::Input(0),  // pool
            Argument::Input(1),  // balance_manager
            Argument::Result(0), // trade_proof (output of command 0)
            client_order_id,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            Argument::Input(2), // clock
            // Note: &TxContext is auto-injected by the runtime — do NOT pass it
        ],
    })));

    let builder = ptb.finish();

    // ── 7. Select a gas coin and build TransactionData ──────────────────
    //
    // Gas budget is denominated in MIST (1 SUI = 1_000_000_000 MIST).
    // The budget is a ceiling — unused gas is refunded.
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

    // ── 8. Sign ─────────────────────────────────────────────────────────
    let signature = keystore
        .sign_secure(&sender, &tx_data, Intent::sui_transaction())
        .await?;

    // ── 9. Execute ──────────────────────────────────────────────────────
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
