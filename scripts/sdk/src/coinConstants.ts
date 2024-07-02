import { getActiveAddress } from "./utils";

// Update env, package IDs, manager id as needed
export const ENV = 'testnet';
export const DEEPBOOK_PACKAGE_ID = `0xdc1b11f060e96cb30092991d361aff6d78a7c3e9df946df5850a26f9a96b8778`;
export const REGISTRY_ID = `0x57fea19ce09abf8879327507fa850753f7c6bd468a74971146c38e92aaa39e37`;
export const DEEP_TREASURY_ID = `0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb`;
export const MY_ADDRESS = getActiveAddress();

export const MANAGER_ADDRESSES: { [key: string]: { address: string, tradeCapId: string | null } } = {
    'MANAGER_1': { address: '0x0c34e41694c5347c7a45978d161b5d6b543bec80702fee6e002118f333dbdfaf', tradeCapId: null }, // Owner
    // Add more entries here as needed
    // 'managerName': { address: 'managerAddress', tradeCapId: 'tradeCapId' }, // For trader permissions
};

// Admin only
export const ADMINCAP_ID = `0xa210c26b2fffeaaff3d8415ace0523fb9113667adcfad1ffa4b88d26ae778b32`;

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
        coinId: `` // Update with actual ID
    },
    TONY: {
        address: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c`,
        type: `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`,
        scalar: 1000000,
        coinId: ``
    },
    DEEP: {
        address: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8`,
        type: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`,
        scalar: 1000000,
        coinId: ``
    },
    SUI: {
        address: `0x0000000000000000000000000000000000000000000000000000000000000002`,
        type: `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`,
        scalar: 1000000000,
        coinId: ``
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
        address: ``,
        baseCoin: Coins.TONY,
        quoteCoin: Coins.SUI,
    },
    DEEP_SUI_POOL: {
        address: `0x47c9cd29216b8109c1cfa38ac20044d8bbd386a79d40cd635dc7e6d5817efed2`,
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
