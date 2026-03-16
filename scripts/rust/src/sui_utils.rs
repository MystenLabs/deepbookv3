use anyhow::{anyhow, Result};
use shared_crypto::intent::Intent;
use sui_config::{sui_config_dir, SUI_KEYSTORE_FILENAME};
use sui_keys::keystore::{AccountKeystore, FileBasedKeystore};
use sui_sdk::{
    rpc_types::{SuiTransactionBlockEffectsAPI, SuiTransactionBlockResponseOptions},
    types::{
        base_types::{ObjectID, SequenceNumber, SuiAddress},
        programmable_transaction_builder::ProgrammableTransactionBuilder,
        transaction::{Transaction, TransactionData},
    },
    SuiClient, SuiClientBuilder,
};

use crate::constants::{PackageIds, MAINNET_PACKAGE_IDS, TESTNET_PACKAGE_IDS};

// ---------------------------------------------------------------------------
// Environment helpers
// ---------------------------------------------------------------------------

pub fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

pub fn required_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| anyhow!("Missing required env var: {}", key))
}

// ---------------------------------------------------------------------------
// Sui CLI config
// ---------------------------------------------------------------------------

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

/// Resolve package IDs for the given network alias.
pub fn get_package_ids(network: &str) -> Result<PackageIds> {
    match network {
        "mainnet" => Ok(MAINNET_PACKAGE_IDS),
        "testnet" => Ok(TESTNET_PACKAGE_IDS),
        other => Err(anyhow!(
            "Unsupported network '{}'. Expected 'mainnet' or 'testnet'.",
            other
        )),
    }
}

// ---------------------------------------------------------------------------
// On-chain helpers
// ---------------------------------------------------------------------------

/// Fetch the `initial_shared_version` of a shared object from on-chain.
pub async fn get_shared_object_version(
    sui: &SuiClient,
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

// ---------------------------------------------------------------------------
// Transaction helpers
// ---------------------------------------------------------------------------

/// Connect to the Sui RPC for the given active environment.
pub async fn connect(active: &ActiveEnv) -> Result<SuiClient> {
    Ok(SuiClientBuilder::default().build(&active.rpc).await?)
}

/// Load the local keystore.
pub fn load_keystore() -> Result<FileBasedKeystore> {
    let path = sui_config_dir()?.join(SUI_KEYSTORE_FILENAME);
    FileBasedKeystore::load_or_create(&path)
}

/// Build, sign, and execute a PTB. Returns the transaction digest.
pub async fn sign_and_execute(
    sui: &SuiClient,
    sender: SuiAddress,
    ptb: ProgrammableTransactionBuilder,
    gas_budget: u64,
) -> Result<String> {
    let keystore = load_keystore()?;

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
        ptb.finish(),
        gas_budget,
        gas_price,
    );

    println!(
        "Gas budget: {} MIST ({:.4} SUI)",
        gas_budget,
        gas_budget as f64 / 1e9
    );

    let signature = keystore
        .sign_secure(&sender, &tx_data, Intent::sui_transaction())
        .await?;

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

        let created = effects.created();
        for obj_ref in created {
            println!("Created object: {}", obj_ref.object_id());
        }
    }

    Ok(response.digest.to_string())
}
