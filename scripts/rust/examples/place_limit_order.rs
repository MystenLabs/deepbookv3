/// Example: Place a limit order on DeepBook V3 using the Sui Rust SDK.
///
/// Automatically uses the active env and address from `sui client`.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  CONFIGURE YOUR ORDER HERE (constants below)                    │
/// ├─────────────────────────────────────────────────────────────────┤
/// │  POOL_KEY       — pool name: "SUI_USDC", "DEEP_SUI", etc.     │
/// │  PRICE          — price in quote per base (e.g. 1.0 USDC/SUI)  │
/// │  QUANTITY       — amount of base asset (e.g. 2.0 SUI)          │
/// │  IS_BID         — true = buy, false = sell                      │
/// │  PAY_WITH_DEEP  — true = pay fees in DEEP, false = input token │
/// │  ORDER_TYPE     — NO_RESTRICTION, POST_ONLY, etc.              │
/// └─────────────────────────────────────────────────────────────────┘
///
/// Required environment variables:
///   BALANCE_MANAGER_ID   - Your BalanceManager shared object ID
///
/// Usage:
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

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURE YOUR ORDER HERE
// ═══════════════════════════════════════════════════════════════════════

/// Pool to trade on. Use the key: "SUI_USDC", "DEEP_SUI", "DEEP_USDC", etc.
const POOL_KEY: &str = "SUI_USDC";

/// Price in quote asset per base asset (e.g. 1.0 = 1 USDC per SUI).
const PRICE: f64 = 1.0;

/// Quantity of base asset (e.g. 2.0 = 2 SUI).
const QUANTITY: f64 = 2.0;

/// true = buy (bid), false = sell (ask).
const IS_BID: bool = false;

/// true = pay fees in DEEP token, false = pay fees in input token.
const PAY_WITH_DEEP: bool = false;

/// Order type: NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY.
const ORDER_TYPE: u8 = NO_RESTRICTION;

// ═══════════════════════════════════════════════════════════════════════

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn required_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| anyhow!("Missing required env var: {}", key))
}

#[tokio::main]
async fn main() -> Result<()> {
    // ── 1. Read active env and resolve pool/coins from constants ─────────
    let active = get_active_env()?;
    let network = active.alias.as_str();

    let package_ids = match network {
        "mainnet" => MAINNET_PACKAGE_IDS,
        "testnet" => TESTNET_PACKAGE_IDS,
        other => return Err(anyhow!("Unsupported network '{}'. Expected 'mainnet' or 'testnet'.", other)),
    };

    let pool = get_pool(network, POOL_KEY).ok_or_else(|| {
        anyhow!("Unknown pool '{}' on {}. Check constants.rs for available pools.", POOL_KEY, network)
    })?;

    let base_coin = get_coin(network, pool.base_coin).ok_or_else(|| {
        anyhow!("Unknown coin '{}' on {}", pool.base_coin, network)
    })?;
    let quote_coin = get_coin(network, pool.quote_coin).ok_or_else(|| {
        anyhow!("Unknown coin '{}' on {}", pool.quote_coin, network)
    })?;

    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;

    // ── 2. Convert human-readable values to on-chain u64 ────────────────
    let price_on_chain = convert_price(PRICE, &quote_coin, &base_coin);
    let quantity_on_chain = convert_quantity(QUANTITY, &base_coin);

    // ── 3. Connect to Sui RPC ───────────────────────────────────────────
    let sui = SuiClientBuilder::default().build(&active.rpc).await?;
    let sender = active.address;
    println!("Network: {network}");
    println!("RPC: {}", active.rpc);
    println!("Sender (active address): {sender}");
    println!("Pool: {} ({}/{})", pool.address, pool.base_coin, pool.quote_coin);
    println!("BalanceManager: {balance_manager_id_str}");
    println!(
        "Order: {} {} {} @ {} {}/{}",
        if IS_BID { "BUY" } else { "SELL" },
        QUANTITY,
        pool.base_coin,
        PRICE,
        pool.quote_coin,
        pool.base_coin,
    );
    println!("  on-chain: price={}, quantity={}", price_on_chain, quantity_on_chain);
    println!("  pay_with_deep={}, order_type={}", PAY_WITH_DEEP, ORDER_TYPE);

    let keystore_path = sui_config_dir()?.join(SUI_KEYSTORE_FILENAME);
    let keystore = FileBasedKeystore::load_or_create(&keystore_path)?;

    // ── 4. Parse object IDs ─────────────────────────────────────────────
    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;
    let pool_id = ObjectID::from_hex_literal(pool.address)?;
    let balance_manager_id = ObjectID::from_hex_literal(&balance_manager_id_str)?;
    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    // ── 5. Fetch initial_shared_version for shared objects ──────────────
    println!("Fetching shared object versions...");
    let pool_version = get_shared_object_version(&sui, pool_id).await?;
    let bm_version = get_shared_object_version(&sui, balance_manager_id).await?;

    // ── 6. Build the Programmable Transaction Block ─────────────────────
    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: Pool (&mut)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: pool_id,
        initial_shared_version: pool_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 1: BalanceManager (&mut)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Input 2: Clock (&)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    // Type arguments: <BaseAsset, QuoteAsset>
    let base_type = TypeInput::from(TypeTag::from_str(base_coin.coin_type)?);
    let quote_type = TypeInput::from(TypeTag::from_str(quote_coin.coin_type)?);

    // Command 0: generate_proof_as_owner(balance_manager) → TradeProof
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "generate_proof_as_owner".to_string(),
        type_arguments: vec![],
        arguments: vec![Argument::Input(1)],
    })));

    // Pure inputs
    let client_order_id = ptb.pure(1u64)?;
    let order_type = ptb.pure(ORDER_TYPE)?;
    let self_matching_option = ptb.pure(SELF_MATCHING_ALLOWED)?;
    let price = ptb.pure(price_on_chain)?;
    let quantity = ptb.pure(quantity_on_chain)?;
    let is_bid = ptb.pure(IS_BID)?;
    let pay_with_deep = ptb.pure(PAY_WITH_DEEP)?;
    let expire_timestamp = ptb.pure(MAX_TIMESTAMP)?;

    // Command 1: place_limit_order<BaseAsset, QuoteAsset>(...)
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "pool".to_string(),
        function: "place_limit_order".to_string(),
        type_arguments: vec![base_type, quote_type],
        arguments: vec![
            Argument::Input(0),  // pool
            Argument::Input(1),  // balance_manager
            Argument::Result(0), // trade_proof
            client_order_id,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            pay_with_deep,
            expire_timestamp,
            Argument::Input(2), // clock
        ],
    })));

    let builder = ptb.finish();

    // ── 7. Build TransactionData ────────────────────────────────────────
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
