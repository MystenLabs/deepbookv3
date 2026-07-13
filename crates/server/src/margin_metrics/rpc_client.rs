use crate::grpc;
use anyhow::{anyhow, Result};
use std::str::FromStr;
use sui_rpc::Client;
use sui_sdk_types::TypeTag;

const MARGIN_POOL_MODULE: &str = "margin_pool";

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
    pub supply_share_price: u64,
    pub borrow_share_price: u64,
}

pub struct MarginRpcClient {
    sui_client: Client,
    margin_package_id: String,
}

impl MarginRpcClient {
    pub fn new(sui_client: Client, margin_package_id: &str) -> Self {
        Self {
            sui_client,
            margin_package_id: margin_package_id.to_string(),
        }
    }

    pub async fn get_pool_state(&self, pool_id: &str, asset_type: &str) -> Result<MarginPoolState> {
        // Get the pool object to find its initial_shared_version
        let initial_shared_version =
            grpc::initial_shared_version(&self.sui_client, pool_id).await?;

        // Parse the asset type for type arguments
        // The asset_type from DB may be missing the 0x prefix, so normalize it
        let normalized_asset_type = normalize_asset_type(asset_type);
        let type_tag = TypeTag::from_str(&normalized_asset_type)
            .map_err(|e| anyhow!("Invalid asset type '{}': {}", normalized_asset_type, e))?;

        // Query all the view functions in a single PTB
        let state = self
            .query_pool_state(pool_id, initial_shared_version, &type_tag)
            .await?;

        Ok(MarginPoolState {
            pool_id: pool_id.to_string(),
            asset_type: normalized_asset_type,
            total_supply: state.0,
            total_borrow: state.1,
            vault_balance: state.2,
            supply_cap: state.3,
            interest_rate: state.4,
            available_withdrawal: state.5,
            supply_share_price: state.6,
            borrow_share_price: state.7,
        })
    }

    async fn query_pool_state(
        &self,
        pool_id: &str,
        initial_shared_version: u64,
        type_tag: &TypeTag,
    ) -> Result<(u64, u64, u64, u64, u64, u64, u64, u64)> {
        let mut ptb = grpc::read_only_tx();

        // Input 0: Pool object
        let pool = ptb.object(grpc::shared_input(pool_id, initial_shared_version)?);
        // Input 1: Clock object (for get_available_withdrawal)
        let clock = ptb.object(grpc::clock_input());

        let type_args = vec![type_tag.clone()];
        let call = |name: &str| {
            grpc::function(
                &self.margin_package_id,
                MARGIN_POOL_MODULE,
                name,
                type_args.clone(),
            )
        };

        // Command 0: total_supply<Asset>(pool)
        ptb.move_call(call("total_supply")?, vec![pool]);
        // Command 1: total_borrow<Asset>(pool)
        ptb.move_call(call("total_borrow")?, vec![pool]);
        // Command 2: vault_balance<Asset>(pool)
        ptb.move_call(call("vault_balance")?, vec![pool]);
        // Command 3: supply_cap<Asset>(pool)
        ptb.move_call(call("supply_cap")?, vec![pool]);
        // Command 4: interest_rate<Asset>(pool)
        ptb.move_call(call("interest_rate")?, vec![pool]);
        // Command 5: get_available_withdrawal<Asset>(pool, clock)
        ptb.move_call(call("get_available_withdrawal")?, vec![pool, clock]);
        // Command 6: supply_ratio<Asset>(pool)
        ptb.move_call(call("supply_ratio")?, vec![pool]);
        // Command 7: borrow_ratio<Asset>(pool)
        ptb.move_call(call("borrow_ratio")?, vec![pool]);

        let results = grpc::simulate_returns(&self.sui_client, ptb).await?;

        // Extract each u64 result
        let total_supply = extract_u64(&results, 0, "total_supply")?;
        let total_borrow = extract_u64(&results, 1, "total_borrow")?;
        let vault_balance = extract_u64(&results, 2, "vault_balance")?;
        let supply_cap = extract_u64(&results, 3, "supply_cap")?;
        let interest_rate = extract_u64(&results, 4, "interest_rate")?;
        let available_withdrawal = extract_u64(&results, 5, "get_available_withdrawal")?;
        let supply_share_price = extract_u64(&results, 6, "supply_ratio")?;
        let borrow_share_price = extract_u64(&results, 7, "borrow_ratio")?;

        Ok((
            total_supply,
            total_borrow,
            vault_balance,
            supply_cap,
            interest_rate,
            available_withdrawal,
            supply_share_price,
            borrow_share_price,
        ))
    }
}

fn extract_u64(results: &[Vec<Vec<u8>>], index: usize, func_name: &str) -> Result<u64> {
    let bytes = results
        .get(index)
        .ok_or_else(|| anyhow!("Missing result for {}", func_name))?
        .first()
        .ok_or_else(|| anyhow!("No return value for {}", func_name))?;

    bcs::from_bytes(bytes).map_err(|e| anyhow!("Failed to deserialize {} result: {}", func_name, e))
}
