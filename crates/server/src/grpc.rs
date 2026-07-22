//! Sui full-node reads over gRPC (`sui.rpc.v2`).
//!
//! Replaces the JSON-RPC `read_api()` calls this server used until Sui deactivated JSON-RPC.
//! Three primitives cover every read we make: the latest checkpoint, a shared object's
//! `initial_shared_version`, and a read-only PTB's per-command return values.

use crate::error::DeepBookError;
use sui_rpc::field::{FieldMask, FieldMaskUtil};
use sui_rpc::proto::sui::rpc::v2::simulate_transaction_request::TransactionChecks;
use sui_rpc::proto::sui::rpc::v2::{
    owner::OwnerKind, GetObjectRequest, GetServiceInfoRequest, SimulateTransactionRequest,
};
use sui_rpc::Client;
use sui_sdk_types::{Address, Digest, Transaction, TypeTag};
use sui_transaction_builder::{Function, ObjectInput, TransactionBuilder};

/// Reads are unsigned and unpaid: nobody is charged, so the values are arbitrary. They exist
/// only because `TransactionBuilder::try_build` refuses to produce a transaction without them.
const READ_GAS_BUDGET: u64 = 50_000_000;
const READ_GAS_PRICE: u64 = 1000;

const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";

/// Height of the most recently executed checkpoint.
pub async fn latest_checkpoint(client: &Client) -> Result<u64, DeepBookError> {
    client
        .clone()
        .ledger_client()
        .get_service_info(GetServiceInfoRequest::default())
        .await?
        .into_inner()
        .checkpoint_height
        .ok_or_else(|| DeepBookError::rpc("Node returned no checkpoint height"))
}

/// The version a shared object was first shared at, needed to reference it as a PTB input.
///
/// `read_mask` is not optional in spirit: `GetObject` defaults to `object_id,version,digest`, so
/// without it `owner` comes back empty and this looks like "not a shared object".
pub async fn initial_shared_version(
    client: &Client,
    object_id: &str,
) -> Result<u64, DeepBookError> {
    let object = client
        .clone()
        .ledger_client()
        .get_object(
            GetObjectRequest::default()
                .with_object_id(object_id)
                .with_read_mask(FieldMask::from_paths(["owner"])),
        )
        .await?
        .into_inner()
        .object
        .ok_or_else(|| DeepBookError::rpc(format!("Object {object_id} not found")))?;

    let owner = object
        .owner
        .ok_or_else(|| DeepBookError::rpc(format!("Object {object_id} has no owner")))?;

    // `Owner.version` means `initial_shared_version` only for SHARED; for CONSENSUS_ADDRESS the
    // same field carries `start_version`, so the kind check is load-bearing, not defensive.
    if owner.kind() != OwnerKind::Shared {
        return Err(DeepBookError::rpc(format!(
            "Object {object_id} is not a shared object"
        )));
    }
    owner
        .version
        .ok_or_else(|| DeepBookError::rpc(format!("Shared object {object_id} has no version")))
}

/// Start a read-only PTB: sender `0x0`, no signature, no real gas — the `dev_inspect` posture.
pub fn read_only_tx() -> TransactionBuilder {
    let mut tx = TransactionBuilder::new();
    tx.set_sender(Address::ZERO);
    tx.set_gas_budget(READ_GAS_BUDGET);
    tx.set_gas_price(READ_GAS_PRICE);
    tx.add_gas_objects([ObjectInput::owned(Address::ZERO, 1, Digest::ZERO)]);
    tx
}

/// Reference a shared object immutably, the only way these read PTBs ever take one.
pub fn shared_input(
    object_id: &str,
    initial_shared_version: u64,
) -> Result<ObjectInput, DeepBookError> {
    let address: Address = object_id
        .parse()
        .map_err(|e| DeepBookError::bad_request(format!("Invalid object ID {object_id}: {e}")))?;
    Ok(ObjectInput::shared(
        address,
        initial_shared_version,
        false, // immutable
    ))
}

/// The `0x6` Clock, always shared at version 1.
pub fn clock_input() -> ObjectInput {
    let clock: Address = SUI_CLOCK_OBJECT_ID
        .parse()
        .expect("clock object ID is a valid address literal");
    ObjectInput::shared(clock, 1, false)
}

/// Resolve a Move function to call, with its type arguments.
pub fn function(
    package: &str,
    module: &str,
    name: &str,
    type_args: Vec<TypeTag>,
) -> Result<Function, DeepBookError> {
    let package: Address = package
        .parse()
        .map_err(|e| DeepBookError::bad_request(format!("Invalid package ID {package}: {e}")))?;
    let module = module
        .parse()
        .map_err(|e| DeepBookError::bad_request(format!("Invalid module {module}: {e}")))?;
    let name = name
        .parse()
        .map_err(|e| DeepBookError::bad_request(format!("Invalid function {name}: {e}")))?;
    Ok(Function::new(package, module, name).with_type_args(type_args))
}

/// Simulate a read-only PTB and return each command's BCS return values, indexed
/// `[command_index][return_value_index]` — the same bytes `dev_inspect` used to hand back.
pub async fn simulate_returns(
    client: &Client,
    builder: TransactionBuilder,
) -> Result<Vec<Vec<Vec<u8>>>, DeepBookError> {
    let mut transaction: Transaction = builder
        .try_build()
        .map_err(|e| DeepBookError::rpc(format!("Failed to build read transaction: {e}")))?;

    // `try_build` demands a gas coin, but address 0x0 owns none and the node resolves gas inputs
    // even when checks are disabled — a placeholder coin fails with "could not find object 0x0".
    // Sending no gas objects is what actually reproduces dev_inspect.
    transaction.gas_payment.objects.clear();

    let response = client
        .clone()
        .execution_client()
        .simulate_transaction(
            SimulateTransactionRequest::default()
                .with_transaction(transaction)
                // Without this mask `command_outputs` comes back empty rather than erroring.
                .with_read_mask(FieldMask::from_paths(["command_outputs"]))
                // Disabled checks let us call non-entry public view functions with no gas and no
                // real sender, exactly as dev_inspect did.
                .with_checks(TransactionChecks::Disabled),
        )
        .await?
        .into_inner();

    if response.command_outputs.is_empty() {
        return Err(DeepBookError::rpc("No results from simulate_transaction"));
    }

    Ok(response
        .command_outputs
        .into_iter()
        .map(|command| {
            command
                .return_values
                .into_iter()
                .filter_map(|output| output.value.and_then(|bcs| bcs.value).map(|b| b.to_vec()))
                .collect()
        })
        .collect())
}
