/// Example: Deposit coins into a BalanceManager.
///
/// ┌─────────────────────────────────────────────────────────────────┐
/// │  CONFIGURE YOUR DEPOSIT HERE                                    │
/// ├─────────────────────────────────────────────────────────────────┤
/// │  DEPOSIT_COIN   — coin name: "SUI", "USDC", "DEEP", etc.      │
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
use deepbook_scripts::sui_utils::*;
use sui_sdk::types::{
    base_types::ObjectID,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall},
    type_input::TypeInput,
    TypeTag,
};

// ═══════════════════════════════════════════════════════════════════════
// CONFIGURE YOUR DEPOSIT HERE
// ═══════════════════════════════════════════════════════════════════════

const DEPOSIT_COIN: &str = "SUI";
const DEPOSIT_AMOUNT: f64 = 10.0;

// ═══════════════════════════════════════════════════════════════════════

#[tokio::main]
async fn main() -> Result<()> {
    let active = get_active_env()?;
    let package_ids = get_package_ids(&active.alias)?;

    let coin = get_coin(&active.alias, DEPOSIT_COIN).ok_or_else(|| {
        anyhow!("Unknown coin '{}' on {}", DEPOSIT_COIN, active.alias)
    })?;

    let balance_manager_id_str = required_env("BALANCE_MANAGER_ID")?;
    let gas_budget: u64 = env_or("GAS_BUDGET", &GAS_BUDGET.to_string()).parse()?;
    let deposit_on_chain = convert_quantity(DEPOSIT_AMOUNT, &coin);

    let sui = connect(&active).await?;
    let sender = active.address;
    println!("Network: {}", active.alias);
    println!("Sender (active address): {sender}");

    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;
    let balance_manager_id = ObjectID::from_hex_literal(&balance_manager_id_str)?;
    let bm_version = get_shared_object_version(&sui, balance_manager_id).await?;

    println!("Deposit: {} {} ({} on-chain)", DEPOSIT_AMOUNT, DEPOSIT_COIN, deposit_on_chain);

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Input 0: BalanceManager (&mut)
    ptb.input(CallArg::Object(ObjectArg::SharedObject {
        id: balance_manager_id,
        initial_shared_version: bm_version,
        mutability: sui_types::transaction::SharedObjectMutability::Mutable,
    }))?;

    // Get the coin to deposit.
    // For SUI: split from the gas coin (always available).
    // For other coins: fetch a Coin<T> from the wallet and split from it.
    let deposit_coin_arg = if coin.is_sui() {
        let amount = ptb.pure(deposit_on_chain)?;
        ptb.command(Command::SplitCoins(Argument::GasCoin, vec![amount]));
        Argument::Result(0)
    } else {
        let coin_type_tag = TypeTag::from_str(coin.coin_type)?;
        let wallet_coins = sui
            .coin_read_api()
            .get_coins(sender, Some(coin_type_tag.to_string()), None, None)
            .await?;
        let source_coin = wallet_coins.data.into_iter().next().ok_or_else(|| {
            anyhow!("No {} coins found in wallet for {sender}", DEPOSIT_COIN)
        })?;

        ptb.input(CallArg::Object(ObjectArg::ImmOrOwnedObject(
            source_coin.object_ref(),
        )))?;

        let amount = ptb.pure(deposit_on_chain)?;
        ptb.command(Command::SplitCoins(Argument::Input(1), vec![amount]));
        Argument::Result(0)
    };

    // balance_manager::deposit<T>(bm, coin, ctx)
    let coin_type_input = TypeInput::from(TypeTag::from_str(coin.coin_type)?);
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "deposit".to_string(),
        type_arguments: vec![coin_type_input],
        arguments: vec![Argument::Input(0), deposit_coin_arg],
    })));

    sign_and_execute(&sui, sender, ptb, gas_budget).await?;
    Ok(())
}
