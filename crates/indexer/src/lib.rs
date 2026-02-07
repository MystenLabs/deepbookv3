use url::Url;

pub mod handlers;
pub(crate) mod models;
pub mod traits;

pub const NOT_MAINNET_PACKAGE: &str = "<not on mainnet>";

pub const MAINNET_REMOTE_STORE_URL: &str = "https://checkpoints.mainnet.sui.io";
pub const TESTNET_REMOTE_STORE_URL: &str = "https://checkpoints.testnet.sui.io";

// Package addresses for different environments
const MAINNET_PACKAGES: &[&str] = &[
    "0xb29d83c26cdd2a64959263abbcfc4a6937f0c9fccaf98580ca56faded65be244",
    "0x2c8d603bc51326b8c13cef9dd07031a408a48dddb541963357661df5d3204809",
    "0xcaf6ba059d539a97646d47f0b9ddf843e138d215e2a12ca1f4585d386f7aec3a",
    "0x00c1a56ec8c4c623a848b2ed2f03d23a25d17570b670c22106f336eb933785cc",
    "0x2d93777cc8b67c064b495e8606f2f8f5fd578450347bbe7b36e0bc03963c1c40", // Latest
];

const TESTNET_PACKAGES: &[&str] = &[
    "0x467e34e75debeea8b89d03aea15755373afc39a7c96c9959549c7f5f689843cf",
    "0x5d520a3e3059b68530b2ef4080126dbb5d234e0afd66561d0d9bd48127a06044",
    "0xcd40faffa91c00ce019bfe4a4b46f8d623e20bf331eb28990ee0305e9b9f3e3c",
    "0x16c4e050b9b19b25ce1365b96861bc50eb7e58383348a39ea8a8e1d063cfef73",
    "0xc483dba510597205749f2e8410c23f19be31a710aef251f353bc1b97755efd4d",
    "0x5da5bbf6fb097d108eaf2c2306f88beae4014c90a44b95c7e76a6bfccec5f5ee",
    "0xa3886aaa8aa831572dd39549242ca004a438c3a55967af9f0387ad2b01595068",
    "0x9592ac923593f37f4fed15ee15f760ebd4c39729f53ee3e8c214de7a17157769",
    "0x984757fc7c0e6dd5f15c2c66e881dd6e5aca98b725f3dbd83c445e057ebb790a",
    "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982",
    "0x926c446869fa175ec3b0dbf6c4f14604d86a415c1fccd8c8f823cfc46a29baed",
    "0xa0936c6ea82fbfc0356eedc2e740e260dedaaa9f909a0715b1cc31e9a8283719",
    "0x9ae1cbfb7475f6a4c2d4d3273335459f8f9d265874c4d161c1966cdcbd4e9ebc",
    "0xb48d47cb5f56d0f489f48f186d06672df59d64bd2f514b2f0ba40cbb8c8fd487",
    "0xbc331f09e5c737d45f074ad2d17c3038421b3b9018699e370d88d94938c53d28",
    "0x23018638bb4f11ef9ffb0de922519bea52f960e7a5891025ca9aaeeaff7d5034",
    "0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c", // Latest
];

// Mainnet margin package is not yet deployed - using placeholder
// This will cause the indexer to fail fast if margin modules are requested on mainnet
// When the margin package is deployed on mainnet, replace this with the actual address
const MAINNET_MARGIN_PACKAGES: &[&str] =
    &["0x97d9473771b01f77b0940c589484184b49f6444627ec121314fae6a6d36fb86b"];
const TESTNET_MARGIN_PACKAGES: &[&str] = &[
    "0xb8620c24c9ea1a4a41e79613d2b3d1d93648d1bb6f6b789a7c8f261c94110e4b",
    "0xf978cf2b601c24e40ef82b6e51512b448696b44cb014c0a1162422aa8b9cb811",
    "0x16d781c327a919dc55390f5cc60d58c7ec4535bb317e88850961222bbd5d4d9e",
    "0xbf9e1b079fa68ffc54a84533b1c3d357019178b19e9901f262fb925454425177",
    "0xe673d499eb03f1c31e8079dc73a700f2f085ff7b69c4aff396fad52d07ae6338",
    "0x229d3cdbb327082a5c6773e8344b16c4040b360235e3cda75e1f232d4e9184cb",
    "0x3d02a90ae1d2eff63ca8ae9bfd89ffa0f7e12d780563259c8271833c270ae842",
    "0x3ca7f6ee86b42ebe05ab8de70fbc96832e65615f64f10dbdc1820fa599904c7b",
    "0xb284008ea0a6ac0a68c41f50a631207cd8d9c197ba0884e0df29ea204256777e",
    "0xc21637e41d3db1c7ca6258fb4de567ba09d4e41610da44a148b26e99b68e11b5",
    "0xf0a090340d74ea598d59868378f27d2cc5e46a562ec3a5b26b5117572905d9f3",
    "0x32e32dd608c4d83f82c64331a547bcb4bbfb819d4591197f2fe442b1661873d8",
    "0xd6a42f4df4db73d68cbeb52be66698d2fe6a9464f45ad113ca52b0c6ebd918b6",
];

// Module definitions
/// Core DeepBook modules that handle trading, orders, and pool management
pub const CORE_MODULES: &[&str] = &[
    "balance_manager",
    "order",
    "order_info",
    "vault",
    "deep_price",
    "state",
    "governance",
    "pool",
];

/// Margin trading modules that handle lending and borrowing
pub const MARGIN_MODULES: &[&str] = &[
    "margin_manager",
    "margin_pool",
    "margin_registry",
    "protocol_fees",
    "tpsl",
];

/// SUI system modules
pub const SUI_MODULES: &[&str] = &["sui"];

/// Enum representing different module types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleType {
    Core,
    Margin,
    Sui,
    Unknown,
}

/// Check if a module is a core DeepBook module
pub fn is_core_module(module: &str) -> bool {
    CORE_MODULES.contains(&module)
}

/// Check if a module is a margin trading module
pub fn is_margin_module(module: &str) -> bool {
    MARGIN_MODULES.contains(&module)
}

/// Check if a module is a SUI system module
pub fn is_sui_module(module: &str) -> bool {
    SUI_MODULES.contains(&module)
}

/// Get the module type (core, margin, sui, or unknown)
pub fn get_module_type(module: &str) -> ModuleType {
    if is_core_module(module) {
        ModuleType::Core
    } else if is_margin_module(module) {
        ModuleType::Margin
    } else if is_sui_module(module) {
        ModuleType::Sui
    } else {
        ModuleType::Unknown
    }
}

/// Get all known module names
pub fn get_all_known_modules() -> Vec<&'static str> {
    let mut modules = Vec::new();
    modules.extend_from_slice(CORE_MODULES);
    modules.extend_from_slice(MARGIN_MODULES);
    modules.extend_from_slice(SUI_MODULES);
    modules
}

/// Get all core module names
pub fn get_core_modules() -> &'static [&'static str] {
    CORE_MODULES
}

/// Get all margin module names
pub fn get_margin_modules() -> &'static [&'static str] {
    MARGIN_MODULES
}

/// Get all SUI module names
pub fn get_sui_modules() -> &'static [&'static str] {
    SUI_MODULES
}

/// Check if a margin package address is valid
pub fn is_valid_margin_package(package: &str) -> bool {
    package != NOT_MAINNET_PACKAGE
}

/// Check if any margin package addresses are valid for the given environment
pub fn is_valid_margin_packages(packages: &[&str]) -> bool {
    packages.iter().any(|&pkg| is_valid_margin_package(pkg))
}

/// Check if margin trading is supported in the given environment
pub fn is_margin_supported(env: DeepbookEnv) -> bool {
    match env {
        DeepbookEnv::Mainnet => is_valid_margin_packages(MAINNET_MARGIN_PACKAGES),
        DeepbookEnv::Testnet => is_valid_margin_packages(TESTNET_MARGIN_PACKAGES),
    }
}

/// Get the margin package addresses for the given environment
pub fn get_margin_package_addresses(env: DeepbookEnv) -> &'static [&'static str] {
    match env {
        DeepbookEnv::Mainnet => MAINNET_MARGIN_PACKAGES,
        DeepbookEnv::Testnet => TESTNET_MARGIN_PACKAGES,
    }
}

/// Get the first valid margin package address for the given environment with validation
pub fn get_margin_package_address(env: DeepbookEnv) -> Result<&'static str, String> {
    let packages = get_margin_package_addresses(env);

    // Find the first valid package
    for &package in packages {
        if is_valid_margin_package(package) {
            return Ok(package);
        }
    }

    Err(format!(
        "Margin trading is not supported on {:?}. \
        The margin package has not been deployed on this network.",
        env
    ))
}

/// Get all core package addresses for the given environment
pub fn get_core_package_addresses(env: DeepbookEnv) -> &'static [&'static str] {
    match env {
        DeepbookEnv::Mainnet => MAINNET_PACKAGES,
        DeepbookEnv::Testnet => TESTNET_PACKAGES,
    }
}

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
        let (packages, margin_packages) = match self {
            DeepbookEnv::Mainnet => (MAINNET_PACKAGES, MAINNET_MARGIN_PACKAGES),
            DeepbookEnv::Testnet => (TESTNET_PACKAGES, TESTNET_MARGIN_PACKAGES),
        };

        let mut all_packages = packages.to_vec();

        // Add margin packages if they're not invalid
        for &margin_package in margin_packages {
            if margin_package != NOT_MAINNET_PACKAGE {
                all_packages.push(margin_package);
            }
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
