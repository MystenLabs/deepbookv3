use move_core_types::account_address::AccountAddress;
use std::str::FromStr;
use std::sync::Arc;
use sui_types::base_types::ObjectID;

pub mod handlers;
pub mod models;
pub mod traits;

pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

const TESTNET_PREDICT_PACKAGES: &[&str] = &[
    "0xff60b95aaaba6edae568ab65406e56f61336dcd274e9c51034f2849d9f5bbfa6",
];

#[derive(Debug, Clone)]
pub struct PredictConfig {
    pub account_addresses: Vec<AccountAddress>,
    pub object_ids: Vec<ObjectID>,
}

impl PredictConfig {
    pub fn new<I, S>(packages: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let (account_addresses, object_ids) = packages
            .into_iter()
            .map(|s| {
                let s = s.as_ref();
                (
                    AccountAddress::from_str(s).expect("invalid package address"),
                    ObjectID::from_str(s).expect("invalid package address"),
                )
            })
            .unzip();
        Self {
            account_addresses,
            object_ids,
        }
    }

    pub fn testnet() -> Arc<Self> {
        Arc::new(Self::new(TESTNET_PREDICT_PACKAGES.iter().copied()))
    }
}
