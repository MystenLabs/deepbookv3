use move_core_types::account_address::AccountAddress;
use std::str::FromStr;
use std::sync::Arc;
use sui_types::base_types::ObjectID;

pub mod handlers;
pub mod models;
pub mod traits;

pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

const TESTNET_PREDICT_PACKAGES: &[&str] = &[
    "0x0000000000000000000000000000000000000000000000000000000000000000",
];

pub const PREDICT_MODULES: &[&str] =
    &["oracle", "registry", "predict", "predict_manager"];

#[derive(Debug, Clone)]
pub struct PredictConfig {
    pub account_addresses: Vec<AccountAddress>,
    pub object_ids: Vec<ObjectID>,
}

impl PredictConfig {
    pub fn new(package_strs: &[&str]) -> Self {
        let account_addresses: Vec<AccountAddress> = package_strs
            .iter()
            .map(|s| AccountAddress::from_str(s).expect("invalid package address"))
            .collect();
        let object_ids: Vec<ObjectID> = package_strs
            .iter()
            .map(|s| ObjectID::from_str(s).expect("invalid package address"))
            .collect();
        Self {
            account_addresses,
            object_ids,
        }
    }

    pub fn testnet() -> Arc<Self> {
        Arc::new(Self::new(TESTNET_PREDICT_PACKAGES))
    }
}
