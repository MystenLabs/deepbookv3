use crate::DeepbookEnv;
use move_core_types::language_storage::StructTag as MoveStructTag;
use std::str::FromStr;
use sui_sdk_types::StructTag;
use sui_types::full_checkpoint_content::CheckpointTransaction;
use sui_types::transaction::{Command, TransactionDataAPI};

pub mod balances_handler;
pub mod deep_burned_handler;
pub mod flash_loan_handler;
pub mod margin_fees_handler;
pub mod margin_manager_operations_handler;
pub mod margin_pool_admin_handler;
pub mod margin_pool_operations_handler;
pub mod margin_registry_handler;
pub mod order_fill_handler;
pub mod order_update_handler;
pub mod pool_price_handler;
pub mod proposals_handler;
pub mod rebates_handler;
pub mod stakes_handler;
pub mod trade_params_update_handler;
pub mod vote_handler;

// Convert rust sdk struct tag to move struct tag.
pub(crate) fn convert_struct_tag(tag: StructTag) -> MoveStructTag {
    MoveStructTag::from_str(&tag.to_string()).unwrap()
}

pub(crate) fn is_deepbook_tx(tx: &CheckpointTransaction, env: DeepbookEnv) -> bool {
    let deepbook_addresses = env.package_addresses();
    let deepbook_packages = env.package_ids();

    // Check input objects against all known package versions
    let has_deepbook_input = tx.input_objects.iter().any(|obj| {
        obj.data
            .type_()
            .map(|t| deepbook_addresses.iter().any(|addr| t.address() == *addr))
            .unwrap_or_default()
    });

    if has_deepbook_input {
        return true;
    }

    // Check if transaction has deepbook events from any version
    if let Some(events) = &tx.events {
        let has_deepbook_event = events.data.iter().any(|event| {
            deepbook_addresses
                .iter()
                .any(|addr| event.type_.address == *addr)
        });

        if has_deepbook_event {
            return true;
        }
    }

    // Check if transaction calls a deepbook function from any version
    let txn_kind = tx.transaction.transaction_data().kind();
    let has_deepbook_call = txn_kind.iter_commands().any(|cmd| {
        if let Command::MoveCall(move_call) = cmd {
            deepbook_packages
                .iter()
                .any(|pkg| *pkg == move_call.package)
        } else {
            false
        }
    });

    has_deepbook_call
}

pub(crate) fn try_extract_move_call_package(tx: &CheckpointTransaction) -> Option<String> {
    let txn_kind = tx.transaction.transaction_data().kind();
    let first_command = txn_kind.iter_commands().next()?;
    if let Command::MoveCall(move_call) = first_command {
        Some(move_call.package.to_string())
    } else {
        None
    }
}
