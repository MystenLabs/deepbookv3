use anyhow::{anyhow, Result};
use std::str::FromStr;
use sui_sdk::SuiClient;
use sui_types::{
    base_types::{ObjectID, SequenceNumber, SuiAddress},
    programmable_transaction_builder::ProgrammableTransactionBuilder,
    transaction::{Argument, CallArg, Command, ObjectArg, ProgrammableMoveCall, TransactionKind},
    type_input::TypeInput,
    TypeTag,
};

const MARGIN_POOL_MODULE: &str = "margin_pool";
const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";

/// Normalize asset type by ensuring the address has a 0x prefix.
/// The DB stores types like "abc123::module::Type" but TypeTag parser needs "0xabc123::module::Type"
fn normalize_asset_type(asset_type: &str) -> String {
    if asset_type.starts_with("0x") || asset_type.starts_with("0X") {
        asset_type.to_string()
    } else {
        format!("0x{}", asset_type)
    }
}

#[derive(Debug, Clone)]
pub struct MarginPoolState {
    pub pool_id: String,
    pub asset_type: String,
    pub total_supply: u64,
    pub total_borrow: u64,
    pub vault_balance: u64,
    pub supply_cap: u64,
    pub interest_rate: u64,
    pub available_withdrawal: u64,
}

pub struct MarginRpcClient {
    sui_client: SuiClient,
    margin_package_id: ObjectID,
}

impl MarginRpcClient {
    pub fn new(sui_client: SuiClient, margin_package_id: &str) -> Result<Self> {
        let package_id = ObjectID::from_hex_literal(margin_package_id)
            .map_err(|e| anyhow!("Invalid margin package ID: {}", e))?;
        Ok(Self {
            sui_client,
            margin_package_id: package_id,
        })
    }

    pub async fn get_pool_state(&self, pool_id: &str, asset_type: &str) -> Result<MarginPoolState> {
        let pool_object_id = ObjectID::from_hex_literal(pool_id)
            .map_err(|e| anyhow!("Invalid pool ID '{}': {}", pool_id, e))?;

        // Get the pool object to find its initial_shared_version
        let pool_object = self
            .sui_client
            .read_api()
            .get_object_with_options(
                pool_object_id,
                sui_json_rpc_types::SuiObjectDataOptions::full_content().with_owner(),
            )
            .await?;

        let pool_data = pool_object
            .data
            .as_ref()
            .ok_or_else(|| anyhow!("Pool {} not found", pool_id))?;

        let initial_shared_version = match &pool_data.owner {
            Some(sui_types::object::Owner::Shared {
                initial_shared_version,
            }) => *initial_shared_version,
            _ => return Err(anyhow!("Pool {} is not a shared object", pool_id)),
        };

        // Parse the asset type for type arguments
        // The asset_type from DB may be missing the 0x prefix, so normalize it
        let normalized_asset_type = normalize_asset_type(asset_type);
        let type_tag = TypeTag::from_str(&normalized_asset_type)
            .map_err(|e| anyhow!("Invalid asset type '{}': {}", normalized_asset_type, e))?;

        // Query all the view functions in a single PTB
        let state = self
            .query_pool_state(pool_object_id, initial_shared_version, &type_tag)
            .await?;

        Ok(MarginPoolState {
            pool_id: pool_object_id.to_hex_literal(),
            asset_type: normalized_asset_type,
            total_supply: state.0,
            total_borrow: state.1,
            vault_balance: state.2,
            supply_cap: state.3,
            interest_rate: state.4,
            available_withdrawal: state.5,
        })
    }

    async fn query_pool_state(
        &self,
        pool_id: ObjectID,
        initial_shared_version: SequenceNumber,
        type_tag: &TypeTag,
    ) -> Result<(u64, u64, u64, u64, u64, u64)> {
        let mut ptb = ProgrammableTransactionBuilder::new();

        // Input 0: Pool object
        let pool_input = CallArg::Object(ObjectArg::SharedObject {
            id: pool_id,
            initial_shared_version,
            mutability: sui_types::transaction::SharedObjectMutability::Immutable,
        });
        ptb.input(pool_input)?;

        // Input 1: Clock object (for get_available_withdrawal)
        let clock_id = ObjectID::from_hex_literal(SUI_CLOCK_OBJECT_ID)?;
        let clock_input = CallArg::Object(ObjectArg::SharedObject {
            id: clock_id,
            initial_shared_version: SequenceNumber::from_u64(1),
            mutability: sui_types::transaction::SharedObjectMutability::Immutable,
        });
        ptb.input(clock_input)?;

        let type_input = TypeInput::from(type_tag.clone());
        let type_args = vec![type_input];

        // Command 0: total_supply<Asset>(pool)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "total_supply".to_string(),
            type_arguments: type_args.clone(),
            arguments: vec![Argument::Input(0)],
        })));

        // Command 1: total_borrow<Asset>(pool)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "total_borrow".to_string(),
            type_arguments: type_args.clone(),
            arguments: vec![Argument::Input(0)],
        })));

        // Command 2: vault_balance<Asset>(pool)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "vault_balance".to_string(),
            type_arguments: type_args.clone(),
            arguments: vec![Argument::Input(0)],
        })));

        // Command 3: supply_cap<Asset>(pool)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "supply_cap".to_string(),
            type_arguments: type_args.clone(),
            arguments: vec![Argument::Input(0)],
        })));

        // Command 4: interest_rate<Asset>(pool)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "interest_rate".to_string(),
            type_arguments: type_args.clone(),
            arguments: vec![Argument::Input(0)],
        })));

        // Command 5: get_available_withdrawal<Asset>(pool, clock)
        ptb.command(Command::MoveCall(Box::new(ProgrammableMoveCall {
            package: self.margin_package_id,
            module: MARGIN_POOL_MODULE.to_string(),
            function: "get_available_withdrawal".to_string(),
            type_arguments: type_args,
            arguments: vec![Argument::Input(0), Argument::Input(1)],
        })));

        let builder = ptb.finish();
        let tx = TransactionKind::ProgrammableTransaction(builder);

        let result = self
            .sui_client
            .read_api()
            .dev_inspect_transaction_block(SuiAddress::default(), tx, None, None, None)
            .await?;

        let results = result
            .results
            .ok_or_else(|| anyhow!("No results from dev_inspect_transaction_block"))?;

        // Extract each u64 result
        let total_supply = self.extract_u64(&results, 0, "total_supply")?;
        let total_borrow = self.extract_u64(&results, 1, "total_borrow")?;
        let vault_balance = self.extract_u64(&results, 2, "vault_balance")?;
        let supply_cap = self.extract_u64(&results, 3, "supply_cap")?;
        let interest_rate = self.extract_u64(&results, 4, "interest_rate")?;
        let available_withdrawal = self.extract_u64(&results, 5, "get_available_withdrawal")?;

        Ok((
            total_supply,
            total_borrow,
            vault_balance,
            supply_cap,
            interest_rate,
            available_withdrawal,
        ))
    }

    fn extract_u64(
        &self,
        results: &[sui_json_rpc_types::SuiExecutionResult],
        index: usize,
        func_name: &str,
    ) -> Result<u64> {
        let result = results
            .get(index)
            .ok_or_else(|| anyhow!("Missing result for {}", func_name))?;

        let bytes = result
            .return_values
            .first()
            .ok_or_else(|| anyhow!("No return value for {}", func_name))?;

        let value: u64 = bcs::from_bytes(&bytes.0)
            .map_err(|e| anyhow!("Failed to deserialize {} result: {}", func_name, e))?;

        Ok(value)
    }
}
