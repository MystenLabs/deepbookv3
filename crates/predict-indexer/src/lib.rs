use url::Url;

pub mod handlers;
pub mod models;
pub mod traits;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Predict package addresses (placeholders until deployment)
const MAINNET_PREDICT_PACKAGES: &[&str] = &[];
const TESTNET_PREDICT_PACKAGES: &[&str] = &[
    "0x0000000000000000000000000000000000000000000000000000000000000000", // Placeholder
];

#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum DeepbookEnv {
    Mainnet,
    Testnet,
}

impl DeepbookEnv {
    pub fn remote_store_url(&self) -> Url {
        let url = match self {
            DeepbookEnv::Mainnet => MAINNET_REMOTE_STORE_URL,
            DeepbookEnv::Testnet => TESTNET_REMOTE_STORE_URL,
        };
        Url::parse(url).unwrap()
    }

    pub fn package_ids(&self) -> Vec<sui_types::base_types::ObjectID> {
        use std::str::FromStr;
        use sui_types::base_types::ObjectID;

        match self {
            DeepbookEnv::Mainnet => MAINNET_PREDICT_PACKAGES,
            DeepbookEnv::Testnet => TESTNET_PREDICT_PACKAGES,
        }
        .iter()
        .map(|pkg| ObjectID::from_str(pkg).unwrap_or(ObjectID::ZERO))
        .collect()
    }

    pub fn package_addresses(&self) -> Vec<move_core_types::account_address::AccountAddress> {
        use move_core_types::account_address::AccountAddress;
        use std::str::FromStr;

        match self {
            DeepbookEnv::Mainnet => MAINNET_PREDICT_PACKAGES,
            DeepbookEnv::Testnet => TESTNET_PREDICT_PACKAGES,
        }
        .iter()
        .map(|pkg| AccountAddress::from_str(pkg).unwrap_or(AccountAddress::ZERO))
        .collect()
    }
}
