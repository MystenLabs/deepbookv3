import { getActiveAddress } from "./utils";

// Update env, package IDs, manager id as needed
export const ENV = 'testnet';
export const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;
export const REGISTRY_ID = `0x14614dfc9243fcb2ef7ac51efed5c6284ca701d55216e1f42b3eb22c541feaa6`;
export const DEEP_TREASURY_ID = `0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb`;
export const MY_ADDRESS = getActiveAddress();

// Admin only
export const ADMINCAP_ID = `0x30314edf9cfa6057722746f31b0973225b38437589b067d4ca6ad263cef9186a`;

export interface Coin {
    address: string;
    type: string;
    scalar: number;
    coinId: string;
}

// Define coins using the structure
export const Coins: { [key: string]: Coin } = {
    ASLAN: {
        address: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c`,
        type: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`,
        scalar: 1000000,
        coinId: `0xsome_aslan_coin_id` // Update with actual ID
    },
    TONY: {
        address: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c`,
        type: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`,
        scalar: 1000000,
        coinId: `0xd5dd3f2623fd809bf691362b6838efc7b84e12c49741299787439f755e5ee765`
    },
    DEEP: {
        address: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8`,
        type: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`,
        scalar: 1000000,
        coinId: `0x363fc7964af3ce74ec92ba37049601ffa88dfa432c488130b340b52d58bdcf50`
    },
    SUI: {
        address: `0x0000000000000000000000000000000000000000000000000000000000000002`,
        type: `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`,
        scalar: 1000000000,
        coinId: `0x0064c4fd7c1c8f56ee8fb1d564bcd1c32a274156b942fd0ea25d605e3d2c5315`
    }
    // Add more coins as needed
};

export interface Pool {
    address: string;
    baseCoin: Coin;
    quoteCoin: Coin;
}

// Define the pools using the interface
export const Pools: { [key: string]: Pool } = {
    TONY_SUI_POOL: {
        address: `0x92083a73031ad86c6df401dc4a59b5dfa589db5937a921c2ec72a5629b715154`,
        baseCoin: Coins.TONY,
        quoteCoin: Coins.SUI,
    },
    DEEP_SUI_POOL: {
        address: `0x9c29aa70749297fe4fc35403ae743cc8883ad26ba77b9ba214dbff7d5f9a5395`,
        baseCoin: Coins.DEEP,
        quoteCoin: Coins.SUI,
    },
    // Add more pools as needed
};

/// Immutable Constants ///
export const Constants = {
    FLOAT_SCALAR: 1000000000,
    POOL_CREATION_FEE: 10000 * 1000000,
    LARGE_TIMESTAMP: 1844674407370955161,
    GAS_BUDGET: 0.5 * 1000000000, // Adjust based on benchmarking
};

// Trading constants
export enum OrderType {
    NO_RESTRICTION,
    IMMEDIATE_OR_CANCEL,
    FILL_OR_KILL,
    POST_ONLY,
};

// Self matching options
export enum SelfMatchingOptions {
    SELF_MATCHING_ALLOWED,
    CANCEL_TAKER,
    CANCEL_MAKER,
};
