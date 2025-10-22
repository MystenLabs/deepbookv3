use url::Url;

pub mod handlers;
pub(crate) mod models;

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Package addresses for different environments
const MAINNET_PACKAGES: &[&str] = &[
    "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809",
    "0xcaf6ba059d539a97646d47f0b9ddf843e138d215e2a12ca1f4585d386f7aec3a",
];

const TESTNET_PACKAGES: &[&str] =
    &["0x16c4e050b9b19b25ce1365b96861bc50eb7e58383348a39ea8a8e1d063cfef73"];

const MAINNET_MARGIN_PACKAGE: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000000";
const TESTNET_MARGIN_PACKAGE: &str =
    "0x442d21fd044b90274934614c3c41416c83582f42eaa8feb4fecea301aa6bdd54";

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

    /// Get all package addresses (DeepBook + Margin) for this environment
    fn get_all_package_strings(&self) -> Vec<&str> {
        let (packages, margin_package) = match self {
            DeepbookEnv::Mainnet => (MAINNET_PACKAGES, MAINNET_MARGIN_PACKAGE),
            DeepbookEnv::Testnet => (TESTNET_PACKAGES, TESTNET_MARGIN_PACKAGE),
        };

        let mut all_packages = packages.to_vec();
        
        // Add margin package if it's not the zero address
        if margin_package != "0x0000000000000000000000000000000000000000000000000000000000000000" {
            all_packages.push(margin_package);
        }
        
        all_packages
    }

    pub fn package_ids(&self) -> Vec<sui_types::base_types::ObjectID> {
        use std::str::FromStr;
        use sui_types::base_types::ObjectID;

        self.get_all_package_strings()
            .iter()
            .map(|pkg| ObjectID::from_str(pkg).unwrap())
            .collect()
    }

    pub fn package_addresses(&self) -> Vec<move_core_types::account_address::AccountAddress> {
        use move_core_types::account_address::AccountAddress;
        use std::str::FromStr;

        self.get_all_package_strings()
            .iter()
            .map(|pkg| AccountAddress::from_str(pkg).unwrap())
            .collect()
    }
}
