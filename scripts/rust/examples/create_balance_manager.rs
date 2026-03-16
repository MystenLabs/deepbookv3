/// Example: Create a new BalanceManager and publicly share it.
///
/// Automatically uses the active env and address from `sui client`.
///
/// Usage:
///   cargo run --example create_balance_manager
use std::str::FromStr;

use anyhow::Result;
use deepbook_scripts::sui_utils::*;
use sui_sdk::types::{
    base_types::ObjectID,
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, Command, ProgrammableMoveCall},
    type_input::TypeInput,
    TypeTag,
};

#[tokio::main]
async fn main() -> Result<()> {
    let active = get_active_env()?;
    let package_ids = get_package_ids(&active.alias)?;
    let gas_budget: u64 = env_or("GAS_BUDGET", "1000000000").parse()?;

    let sui = connect(&active).await?;
    println!("Network: {}", active.alias);
    println!("Sender (active address): {}", active.address);

    let deepbook_package = ObjectID::from_hex_literal(package_ids.deepbook_package_id)?;

    let mut ptb = ProgrammableTransactionBuilder::new();

    // Command 0: balance_manager::new() → BalanceManager
    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: deepbook_package,
        module: "balance_manager".to_string(),
        function: "new".to_string(),
        type_arguments: vec![],
        arguments: vec![],
    })));

    // Command 1: transfer::public_share_object<BalanceManager>(bm)
    let bm_type = TypeInput::from(TypeTag::from_str(&format!(
        "{}::balance_manager::BalanceManager",
        package_ids.deepbook_package_id
    ))?);

    ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
        package: ObjectID::from_hex_literal(
            "0x0000000000000000000000000000000000000000000000000000000000000002",
        )?,
        module: "transfer".to_string(),
        function: "public_share_object".to_string(),
        type_arguments: vec![bm_type],
        arguments: vec![Argument::Result(0)],
    })));

    sign_and_execute(&sui, active.address, ptb, gas_budget).await?;
    Ok(())
}
