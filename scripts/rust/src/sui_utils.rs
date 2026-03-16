use anyhow::{anyhow, Result};
use sui_sdk::types::base_types::{ObjectID, SequenceNumber, SuiAddress};

/// Active environment info read from `~/.sui/sui_config/client.yaml`.
pub struct ActiveEnv {
    pub alias: String,
    pub rpc: String,
    pub address: SuiAddress,
}

fn read_client_yaml() -> Result<serde_yaml::Value> {
    let config_path = dirs::home_dir()
        .ok_or_else(|| anyhow!("Cannot determine home directory"))?
        .join(".sui/sui_config/client.yaml");

    let contents = std::fs::read_to_string(&config_path).map_err(|e| {
        anyhow!(
            "Failed to read {:?}: {}. Run `sui client` first to initialize.",
            config_path,
            e
        )
    })?;

    Ok(serde_yaml::from_str(&contents)?)
}

/// Read the active address from `~/.sui/sui_config/client.yaml`,
/// matching the behavior of `sui client active-address`.
pub fn get_active_address() -> Result<SuiAddress> {
    let yaml = read_client_yaml()?;

    let addr_str = yaml
        .get("active_address")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("No active_address found in client.yaml"))?;

    addr_str
        .parse::<SuiAddress>()
        .map_err(|e| anyhow!("Invalid active_address '{}': {}", addr_str, e))
}

/// Read the active environment (alias, RPC URL) and active address from
/// `~/.sui/sui_config/client.yaml`, matching `sui client active-env`.
pub fn get_active_env() -> Result<ActiveEnv> {
    let yaml = read_client_yaml()?;

    let address = {
        let addr_str = yaml
            .get("active_address")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow!("No active_address found in client.yaml"))?;
        addr_str
            .parse::<SuiAddress>()
            .map_err(|e| anyhow!("Invalid active_address '{}': {}", addr_str, e))?
    };

    let active_alias = yaml
        .get("active_env")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("No active_env found in client.yaml"))?;

    let envs = yaml
        .get("envs")
        .and_then(|v| v.as_sequence())
        .ok_or_else(|| anyhow!("No envs found in client.yaml"))?;

    for env in envs {
        let alias = env.get("alias").and_then(|v| v.as_str()).unwrap_or("");
        if alias == active_alias {
            let rpc = env
                .get("rpc")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("No rpc found for env '{}'", alias))?;
            return Ok(ActiveEnv {
                alias: alias.to_string(),
                rpc: rpc.to_string(),
                address,
            });
        }
    }

    Err(anyhow!(
        "Active env '{}' not found in client.yaml envs list",
        active_alias
    ))
}

/// Fetch the `initial_shared_version` of a shared object from on-chain.
///
/// Every shared object on Sui has an `initial_shared_version` recorded when it
/// was first shared. The runtime needs this to schedule transactions, so we
/// must include it when referencing a shared object in a PTB.
pub async fn get_shared_object_version(
    sui: &sui_sdk::SuiClient,
    object_id: ObjectID,
) -> Result<SequenceNumber> {
    let resp = sui
        .read_api()
        .get_object_with_options(
            object_id,
            sui_sdk::rpc_types::SuiObjectDataOptions::new().with_owner(),
        )
        .await?;

    let data = resp
        .data
        .as_ref()
        .ok_or_else(|| anyhow!("Object {} not found on chain", object_id))?;

    match &data.owner {
        Some(sui_types::object::Owner::Shared {
            initial_shared_version,
        }) => Ok(*initial_shared_version),
        _ => Err(anyhow!("Object {} is not a shared object", object_id)),
    }
}
