use move_core_types::account_address::AccountAddress;
use move_core_types::language_storage::StructTag as MoveStructTag;
use move_types::MoveStruct;
use std::str::FromStr;
use sui_sdk_types::StructTag;
use sui_types::full_checkpoint_content::CheckpointTransaction;
use sui_types::transaction::{Command, TransactionDataAPI};

pub mod balances_handler;
pub mod flash_loan_handler;
pub mod order_fill_handler;
pub mod order_update_handler;
pub mod pool_price_handler;
pub mod proposals_handler;
pub mod rebates_handler;
pub mod stakes_handler;
pub mod trade_params_update_handler;
pub mod vote_handler;

const DEEPBOOK_PKG_ADDRESS: AccountAddress =
    AccountAddress::new(*crate::models::deepbook::registry::PACKAGE_ID.inner());

// Convert rust sdk struct tag to move struct tag.
pub(crate) fn convert_struct_tag(tag: StructTag) -> MoveStructTag {
    MoveStructTag::from_str(&tag.to_string()).unwrap()
}

pub(crate) fn is_deepbook_tx(tx: &CheckpointTransaction) -> bool {
    tx.input_objects.iter().any(|obj| {
        obj.data
            .type_()
            .map(|t| t.address() == DEEPBOOK_PKG_ADDRESS)
            .unwrap_or_default()
    })
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

fn struct_tag<T: MoveStruct>(
    package_id_override: Option<AccountAddress>,
) -> move_core_types::language_storage::StructTag {
    let mut event_type = convert_struct_tag(T::struct_type());
    if let Some(package_id_override) = package_id_override {
        event_type.address = package_id_override;
    }
    event_type
}
