/// Example: Place a limit order on DeepBook V3.
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
use deepbook_scripts::sui_utils::*;
use sui_sdk::types::{
    base_types::{ObjectID, SequenceNumber},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall},
    type_input::TypeInput,
    TypeTag,
};

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURE YOUR ORDER HERE
// ═══════════════════════════════════════════════════════════════════════

const POOL_KEY: &str = "SUI_USDC";
const PRICE: f64 = 1.0;
const QUANTITY: f64 = 2.0;
const IS_BID: bool = false;
const PAY_WITH_DEEP: bool = false;
const ORDER_TYPE: u8 = NO_RESTRICTION;

// ═══════════════════════════════════════════════════════════════════════

#[tokio::main]
async fn main() -> Result<()> {
    let active = get_active_env()?;
    let network = active.alias.as_str();
    let package_ids = get_package_ids(network)?;

    let pool = get_pool(network, POOL_KEY)
        .ok_or_else(|| anyhow!("Unknown pool '{}' on {}", POOL_KEY, network))?;
    let base_coin = get_coin(network, pool.base_coin)
        .ok_or_else(|| anyhow!("Unknown coin '{}'", pool.base_coin))?;
    let quote_coin = get_coin(network, pool.quote_coin)
        .ok_or_else(|| anyhow!("Unknown coin '{}'", pool.quote_coin))?;

    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;

    let price_on_chain = convert_price(PRICE, &quote_coin, &base_coin);
    let quantity_on_chain = convert_quantity(QUANTITY, &base_coin);

    let sui = connect(&active).await?;
    let sender = active.address;

    println!("Network: {network}");
    println!("Sender (active address): {sender}");
    println!("Pool: {} ({}/{})", pool.address, pool.base_coin, pool.quote_coin);
    println!(
        "Order: {} {} {} @ {} {}/{}",
        if IS_BID { "BUY" } else { "SELL" },
        QUANTITY, pool.base_coin, PRICE, pool.quote_coin, pool.base_coin,
    );
    println!("  on-chain: price={}, quantity={}", price_on_chain, quantity_on_chain);

    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;
    let pool_id = ObjectID::from_hex_literal(pool.address)?;
    let balance_manager_id = ObjectID::from_hex_literal(&balance_manager_id_str)?;
    let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;

    println!("Fetching shared object versions...");
    let pool_version = get_shared_object_version(&sui, pool_id).await?;
    let bm_version = get_shared_object_version(&sui, balance_manager_id).await?;

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Shared object inputs
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: pool_id,
        initial_shared_version: pool_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: clock_id,
        initial_shared_version: SequenceNumber::from_u64(1),
        mutability: sui_types::transaction::SharedObjectMutability::Immutable,
    }))?;

    let base_type = TypeInput::from(TypeTag::from_str(base_coin.coin_type)?);
    let quote_type = TypeInput::from(TypeTag::from_str(quote_coin.coin_type)?);

    // Command 0: generate_proof_as_owner
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

    // Command 1: place_limit_order
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

    sign_and_execute(&sui, sender, ptb, gas_budget).await?;
    Ok(())
}
