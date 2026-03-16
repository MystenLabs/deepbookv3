// DeepBook V3 constants, mirroring the TypeScript SDK's `constants.ts`.
// Source of truth: ts-sdks/packages/deepbook-v3/src/utils/constants.ts

// ---------------------------------------------------------------------------
// Scalars & limits
// ---------------------------------------------------------------------------

/// 10^9 — float scalar used for price conversions on-chain.
pub const FLOAT_SCALAR: u64 = 1_000_000_000;

/// 10^6 — DEEP token decimal scalar.
pub const DEEP_SCALAR: u64 = 1_000_000;

/// Maximum timestamp value (effectively "no expiry").
pub const MAX_TIMESTAMP: u64 = 1_844_674_407_370_955_161;

/// Default gas budget: 1 SUI in MIST. Unused gas is refunded.
pub const GAS_BUDGET: u64 = 1_000_000_000;

/// Sui Clock object — always at address 0x6, shared since genesis (version 1).
pub const SUI_CLOCK_OBJECT_ID: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000006";

// ---------------------------------------------------------------------------
// Conversion helpers (mirrors ts-sdk conversion.ts)
// ---------------------------------------------------------------------------

/// Convert a human-readable quantity to the on-chain u64 representation.
///
/// Example: `convert_quantity(10.0, &MAINNET_SUI)` → 10_000_000_000
///
/// Formula: `value * coin.scalar`
pub fn convert_quantity(value: f64, coin: &Coin) -> u64 {
    (value * coin.scalar as f64).round() as u64
}

/// Convert a human-readable price to the on-chain u64 representation.
///
/// The price is in quote asset per base asset terms
/// (e.g., "1.5 USDC per SUI" → `convert_price(1.5, &MAINNET_USDC, &MAINNET_SUI)`).
///
/// Formula: `value * FLOAT_SCALAR * quote_coin.scalar / base_coin.scalar`
pub fn convert_price(value: f64, quote_coin: &Coin, base_coin: &Coin) -> u64 {
    (value * FLOAT_SCALAR as f64 * quote_coin.scalar as f64 / base_coin.scalar as f64).round()
        as u64
}

// ---------------------------------------------------------------------------
// Order types
// ---------------------------------------------------------------------------

pub const NO_RESTRICTION: u8 = 0;
pub const IMMEDIATE_OR_CANCEL: u8 = 1;
pub const FILL_OR_KILL: u8 = 2;
pub const POST_ONLY: u8 = 3;

// ---------------------------------------------------------------------------
// Self-matching options
// ---------------------------------------------------------------------------

pub const SELF_MATCHING_ALLOWED: u8 = 0;
pub const CANCEL_TAKER: u8 = 1;
pub const CANCEL_MAKER: u8 = 2;

// ---------------------------------------------------------------------------
// Network configuration
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
pub struct PackageIds {
    pub deepbook_package_id: &'static str,
    pub registry_id: &'static str,
    pub deep_treasury_id: &'static str,
}

#[derive(Clone, Copy)]
pub struct Coin {
    pub coin_type: &'static str,
    pub scalar: u64,
}

/// SUI coin type (same on all networks).
const SUI_COIN_TYPE: &str =
    "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI";

impl Coin {
    /// Returns true if this is the native SUI coin.
    pub fn is_sui(&self) -> bool {
        self.coin_type == SUI_COIN_TYPE
    }
}

/// Look up a coin by its short name (e.g. "SUI", "USDC", "DEEP") for a given network.
pub fn get_coin(network: &str, name: &str) -> Option<Coin> {
    let name_upper = name.to_uppercase();
    match network {
        "mainnet" => match name_upper.as_str() {
            "SUI" => Some(MAINNET_SUI),
            "DEEP" => Some(MAINNET_DEEP),
            "USDC" => Some(MAINNET_USDC),
            "WAL" => Some(MAINNET_WAL),
            "SUIUSDE" => Some(MAINNET_SUIUSDE),
            "XBTC" => Some(MAINNET_XBTC),
            "USDSUI" => Some(MAINNET_USDSUI),
            "WUSDC" => Some(MAINNET_WUSDC),
            "WETH" => Some(MAINNET_WETH),
            "BETH" => Some(MAINNET_BETH),
            "WBTC" => Some(MAINNET_WBTC),
            "WUSDT" => Some(MAINNET_WUSDT),
            "NS" => Some(MAINNET_NS),
            "TYPUS" => Some(MAINNET_TYPUS),
            "AUSD" => Some(MAINNET_AUSD),
            "USDT" => Some(MAINNET_USDT),
            _ => None,
        },
        "testnet" => match name_upper.as_str() {
            "SUI" => Some(TESTNET_SUI),
            "DEEP" => Some(TESTNET_DEEP),
            "DBUSDC" => Some(TESTNET_DBUSDC),
            "DBTC" => Some(TESTNET_DBTC),
            "DBUSDT" => Some(TESTNET_DBUSDT),
            "WAL" => Some(TESTNET_WAL),
            _ => None,
        },
        _ => None,
    }
}

/// Look up a pool by its key (e.g. "SUI_USDC", "DEEP_SUI") for a given network.
pub fn get_pool(network: &str, key: &str) -> Option<Pool> {
    let key_upper = key.to_uppercase();
    match network {
        "mainnet" => match key_upper.as_str() {
            "DEEP_SUI" => Some(MAINNET_POOL_DEEP_SUI),
            "SUI_USDC" => Some(MAINNET_POOL_SUI_USDC),
            "DEEP_USDC" => Some(MAINNET_POOL_DEEP_USDC),
            "WUSDT_USDC" => Some(MAINNET_POOL_WUSDT_USDC),
            "WUSDC_USDC" => Some(MAINNET_POOL_WUSDC_USDC),
            "BETH_USDC" => Some(MAINNET_POOL_BETH_USDC),
            "NS_USDC" => Some(MAINNET_POOL_NS_USDC),
            "NS_SUI" => Some(MAINNET_POOL_NS_SUI),
            "TYPUS_SUI" => Some(MAINNET_POOL_TYPUS_SUI),
            "SUI_AUSD" => Some(MAINNET_POOL_SUI_AUSD),
            "AUSD_USDC" => Some(MAINNET_POOL_AUSD_USDC),
            "DRF_SUI" => Some(MAINNET_POOL_DRF_SUI),
            "SEND_USDC" => Some(MAINNET_POOL_SEND_USDC),
            "WAL_USDC" => Some(MAINNET_POOL_WAL_USDC),
            "WAL_SUI" => Some(MAINNET_POOL_WAL_SUI),
            "XBTC_USDC" => Some(MAINNET_POOL_XBTC_USDC),
            "IKA_USDC" => Some(MAINNET_POOL_IKA_USDC),
            "LZWBTC_USDC" => Some(MAINNET_POOL_LZWBTC_USDC),
            "USDT_USDC" => Some(MAINNET_POOL_USDT_USDC),
            "SUIUSDE_USDC" => Some(MAINNET_POOL_SUIUSDE_USDC),
            "SUI_SUIUSDE" => Some(MAINNET_POOL_SUI_SUIUSDE),
            "SUI_USDSUI" => Some(MAINNET_POOL_SUI_USDSUI),
            "USDSUI_USDC" => Some(MAINNET_POOL_USDSUI_USDC),
            "ALKIMI_SUI" => Some(MAINNET_POOL_ALKIMI_SUI),
            _ => None,
        },
        "testnet" => match key_upper.as_str() {
            "DEEP_SUI" => Some(TESTNET_POOL_DEEP_SUI),
            "SUI_DBUSDC" => Some(TESTNET_POOL_SUI_DBUSDC),
            "DEEP_DBUSDC" => Some(TESTNET_POOL_DEEP_DBUSDC),
            "DBUSDT_DBUSDC" => Some(TESTNET_POOL_DBUSDT_DBUSDC),
            "WAL_DBUSDC" => Some(TESTNET_POOL_WAL_DBUSDC),
            "WAL_SUI" => Some(TESTNET_POOL_WAL_SUI),
            "DBTC_DBUSDC" => Some(TESTNET_POOL_DBTC_DBUSDC),
            _ => None,
        },
        _ => None,
    }
}

#[derive(Clone, Copy)]
pub struct Pool {
    pub address: &'static str,
    pub base_coin: &'static str,
    pub quote_coin: &'static str,
}

// ---------------------------------------------------------------------------
// Testnet
// ---------------------------------------------------------------------------

pub const TESTNET_PACKAGE_IDS: PackageIds = PackageIds {
    deepbook_package_id:
        "0x22be4cade64bf2d02412c7e8d0e8beea2f78828b948118d46735315409371a3c",
    registry_id: "0x7c256edbda983a2cd6f946655f4bf3f00a41043993781f8674a7046e8c0e11d1",
    deep_treasury_id: "0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb",
};

pub const TESTNET_DEEP: Coin = Coin {
    coin_type: "0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP",
    scalar: 1_000_000,
};

pub const TESTNET_SUI: Coin = Coin {
    coin_type: "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
    scalar: 1_000_000_000,
};

pub const TESTNET_DBUSDC: Coin = Coin {
    coin_type:
        "0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDC::DBUSDC",
    scalar: 1_000_000,
};

pub const TESTNET_DBTC: Coin = Coin {
    coin_type: "0x6502dae813dbe5e42643c119a6450a518481f03063febc7e20238e43b6ea9e86::dbtc::DBTC",
    scalar: 100_000_000,
};

pub const TESTNET_DBUSDT: Coin = Coin {
    coin_type:
        "0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDT::DBUSDT",
    scalar: 1_000_000,
};

pub const TESTNET_WAL: Coin = Coin {
    coin_type: "0x9ef7676a9f81937a52ae4b2af8d511a28a0b080477c0c2db40b0ab8882240d76::wal::WAL",
    scalar: 1_000_000_000,
};

pub const TESTNET_POOL_DEEP_SUI: Pool = Pool {
    address: "0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f",
    base_coin: "DEEP",
    quote_coin: "SUI",
};

pub const TESTNET_POOL_SUI_DBUSDC: Pool = Pool {
    address: "0x1c19362ca52b8ffd7a33cee805a67d40f31e6ba303753fd3a4cfdfacea7163a5",
    base_coin: "SUI",
    quote_coin: "DBUSDC",
};

pub const TESTNET_POOL_DEEP_DBUSDC: Pool = Pool {
    address: "0xe86b991f8632217505fd859445f9803967ac84a9d4a1219065bf191fcb74b622",
    base_coin: "DEEP",
    quote_coin: "DBUSDC",
};

pub const TESTNET_POOL_DBUSDT_DBUSDC: Pool = Pool {
    address: "0x83970bb02e3636efdff8c141ab06af5e3c9a22e2f74d7f02a9c3430d0d10c1ca",
    base_coin: "DBUSDT",
    quote_coin: "DBUSDC",
};

pub const TESTNET_POOL_WAL_DBUSDC: Pool = Pool {
    address: "0xeb524b6aea0ec4b494878582e0b78924208339d360b62aec4a8ecd4031520dbb",
    base_coin: "WAL",
    quote_coin: "DBUSDC",
};

pub const TESTNET_POOL_WAL_SUI: Pool = Pool {
    address: "0x8c1c1b186c4fddab1ebd53e0895a36c1d1b3b9a77cd34e607bef49a38af0150a",
    base_coin: "WAL",
    quote_coin: "SUI",
};

pub const TESTNET_POOL_DBTC_DBUSDC: Pool = Pool {
    address: "0x0dce0aa771074eb83d1f4a29d48be8248d4d2190976a5241f66b43ec18fa34de",
    base_coin: "DBTC",
    quote_coin: "DBUSDC",
};

// ---------------------------------------------------------------------------
// Mainnet
// ---------------------------------------------------------------------------

pub const MAINNET_PACKAGE_IDS: PackageIds = PackageIds {
    deepbook_package_id:
        "0x337f4f4f6567fcd778d5454f27c16c70e2f274cc6377ea6249ddf491482ef497",
    registry_id: "0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d",
    deep_treasury_id: "0x032abf8948dda67a271bcc18e776dbbcfb0d58c8d288a700ff0d5521e57a1ffe",
};

pub const MAINNET_DEEP: Coin = Coin {
    coin_type: "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP",
    scalar: 1_000_000,
};

pub const MAINNET_SUI: Coin = Coin {
    coin_type: "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI",
    scalar: 1_000_000_000,
};

pub const MAINNET_USDC: Coin = Coin {
    coin_type: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
    scalar: 1_000_000,
};

pub const MAINNET_WAL: Coin = Coin {
    coin_type: "0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL",
    scalar: 1_000_000_000,
};

pub const MAINNET_SUIUSDE: Coin = Coin {
    coin_type:
        "0x41d587e5336f1c86cad50d38a7136db99333bb9bda91cea4ba69115defeb1402::sui_usde::SUI_USDE",
    scalar: 1_000_000,
};

pub const MAINNET_XBTC: Coin = Coin {
    coin_type: "0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC",
    scalar: 100_000_000,
};

pub const MAINNET_USDSUI: Coin = Coin {
    coin_type:
        "0x44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1::usdsui::USDSUI",
    scalar: 1_000_000,
};

pub const MAINNET_WUSDC: Coin = Coin {
    coin_type:
        "0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN",
    scalar: 1_000_000,
};

pub const MAINNET_WETH: Coin = Coin {
    coin_type:
        "0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN",
    scalar: 100_000_000,
};

pub const MAINNET_BETH: Coin = Coin {
    coin_type: "0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH",
    scalar: 100_000_000,
};

pub const MAINNET_WBTC: Coin = Coin {
    coin_type:
        "0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN",
    scalar: 100_000_000,
};

pub const MAINNET_WUSDT: Coin = Coin {
    coin_type:
        "0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN",
    scalar: 1_000_000,
};

pub const MAINNET_NS: Coin = Coin {
    coin_type: "0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS",
    scalar: 1_000_000,
};

pub const MAINNET_TYPUS: Coin = Coin {
    coin_type:
        "0xf82dc05634970553615eef6112a1ac4fb7bf10272bf6cbe0f80ef44a6c489385::typus::TYPUS",
    scalar: 1_000_000_000,
};

pub const MAINNET_AUSD: Coin = Coin {
    coin_type: "0x2053d08c1e2bd02791056171aab0fd12bd7cd7efad2ab8f6b9c8902f14df2ff2::ausd::AUSD",
    scalar: 1_000_000,
};

pub const MAINNET_USDT: Coin = Coin {
    coin_type: "0x375f70cf2ae4c00bf37117d0c85a2c71545e6ee05c4a5c7d282cd66a4504b068::usdt::USDT",
    scalar: 1_000_000,
};

pub const MAINNET_POOL_DEEP_SUI: Pool = Pool {
    address: "0xb663828d6217467c8a1838a03793da896cbe745b150ebd57d82f814ca579fc22",
    base_coin: "DEEP",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_SUI_USDC: Pool = Pool {
    address: "0xe05dafb5133bcffb8d59f4e12465dc0e9faeaa05e3e342a08fe135800e3e4407",
    base_coin: "SUI",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_DEEP_USDC: Pool = Pool {
    address: "0xf948981b806057580f91622417534f491da5f61aeaf33d0ed8e69fd5691c95ce",
    base_coin: "DEEP",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_WUSDT_USDC: Pool = Pool {
    address: "0x4e2ca3988246e1d50b9bf209abb9c1cbfec65bd95afdacc620a36c67bdb8452f",
    base_coin: "WUSDT",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_WUSDC_USDC: Pool = Pool {
    address: "0xa0b9ebefb38c963fd115f52d71fa64501b79d1adcb5270563f92ce0442376545",
    base_coin: "WUSDC",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_BETH_USDC: Pool = Pool {
    address: "0x1109352b9112717bd2a7c3eb9a416fff1ba6951760f5bdd5424cf5e4e5b3e65c",
    base_coin: "BETH",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_NS_USDC: Pool = Pool {
    address: "0x0c0fdd4008740d81a8a7d4281322aee71a1b62c449eb5b142656753d89ebc060",
    base_coin: "NS",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_NS_SUI: Pool = Pool {
    address: "0x27c4fdb3b846aa3ae4a65ef5127a309aa3c1f466671471a806d8912a18b253e8",
    base_coin: "NS",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_TYPUS_SUI: Pool = Pool {
    address: "0xe8e56f377ab5a261449b92ac42c8ddaacd5671e9fec2179d7933dd1a91200eec",
    base_coin: "TYPUS",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_SUI_AUSD: Pool = Pool {
    address: "0x183df694ebc852a5f90a959f0f563b82ac9691e42357e9a9fe961d71a1b809c8",
    base_coin: "SUI",
    quote_coin: "AUSD",
};

pub const MAINNET_POOL_AUSD_USDC: Pool = Pool {
    address: "0x5661fc7f88fbeb8cb881150a810758cf13700bb4e1f31274a244581b37c303c3",
    base_coin: "AUSD",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_WAL_USDC: Pool = Pool {
    address: "0x56a1c985c1f1123181d6b881714793689321ba24301b3585eec427436eb1c76d",
    base_coin: "WAL",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_WAL_SUI: Pool = Pool {
    address: "0x81f5339934c83ea19dd6bcc75c52e83509629a5f71d3257428c2ce47cc94d08b",
    base_coin: "WAL",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_XBTC_USDC: Pool = Pool {
    address: "0x20b9a3ec7a02d4f344aa1ebc5774b7b0ccafa9a5d76230662fdc0300bb215307",
    base_coin: "XBTC",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_IKA_USDC: Pool = Pool {
    address: "0xfa732993af2b60d04d7049511f801e79426b2b6a5103e22769c0cead982b0f47",
    base_coin: "IKA",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_LZWBTC_USDC: Pool = Pool {
    address: "0xf5142aafa24866107df628bf92d0358c7da6acc46c2f10951690fd2b8570f117",
    base_coin: "LZWBTC",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_USDT_USDC: Pool = Pool {
    address: "0xfc28a2fb22579c16d672a1152039cbf671e5f4b9f103feddff4ea06ef3c2bc25",
    base_coin: "USDT",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_SUIUSDE_USDC: Pool = Pool {
    address: "0x0fac1cebf35bde899cd9ecdd4371e0e33f44ba83b8a2902d69186646afa3a94b",
    base_coin: "SUIUSDE",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_SUI_SUIUSDE: Pool = Pool {
    address: "0x034f3a42e7348de2084406db7a725f9d9d132a56c68324713e6e623601fb4fd7",
    base_coin: "SUI",
    quote_coin: "SUIUSDE",
};

pub const MAINNET_POOL_SUI_USDSUI: Pool = Pool {
    address: "0x826eeacb2799726334aa580396338891205a41cf9344655e526aae6ddd5dc03f",
    base_coin: "SUI",
    quote_coin: "USDSUI",
};

pub const MAINNET_POOL_USDSUI_USDC: Pool = Pool {
    address: "0xa374264d43e6baa5aa8b35ff18ff24fdba7443b4bcb884cb4c2f568d32cdac36",
    base_coin: "USDSUI",
    quote_coin: "USDC",
};

pub const MAINNET_POOL_ALKIMI_SUI: Pool = Pool {
    address: "0x84752993c6dc6fce70e25ddeb4daddb6592d6b9b0912a0a91c07cfff5a721d89",
    base_coin: "ALKIMI",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_DRF_SUI: Pool = Pool {
    address: "0x126865a0197d6ab44bfd15fd052da6db92fd2eb831ff9663451bbfa1219e2af2",
    base_coin: "DRF",
    quote_coin: "SUI",
};

pub const MAINNET_POOL_SEND_USDC: Pool = Pool {
    address: "0x1fe7b99c28ded39774f37327b509d58e2be7fff94899c06d22b407496a6fa990",
    base_coin: "SEND",
    quote_coin: "USDC",
};
