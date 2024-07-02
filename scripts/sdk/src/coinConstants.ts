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
export const ADMINCAP_ID = `0x1f58a7627ec7a7d32ab51371d3b6e7ee8d1a4ad5c031fdefa371de651b7184e3`;

export interface Coin {
    address: string;
    type: string;
    scalar: number;
    coinId: string;
}

// Define coins using the structure
// Only fill in coinId if there's a specific coin user wishes to use
export const Coins: { [key: string]: Coin } = {
    DBUSDC: {
        address: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f`,
        type: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f::DBUSDC::DBUSDC`,
        scalar: 1000000,
        coinId: ``
    },
    DBWETH: {
        address: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f`,
        type: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f::DBWETH::DBWETH`,
        scalar: 100000000,
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
    DEEP_SUI_POOL: {
        address: `0x67800bae6808206915c7f09203a00031ce9ce8550008862dda3083191e3954ca`,
        baseCoin: Coins.DEEP,
        quoteCoin: Coins.SUI,
    },
    SUI_DBUSDC_POOL: {
        address: `0x9442afa775e90112448f26a8d58ca76f66cf46e4b77e74d6d85cea30bedc289c`,
        baseCoin: Coins.SUI,
        quoteCoin: Coins.DBUSDC,
    },
    DEEP_DBWETH_POOL: {
        address: `0xe8d0f3525518aaaae64f3832a24606a9eadde8572d058c45626a4ab2cbfae1eb`,
        baseCoin: Coins.DEEP,
        quoteCoin: Coins.DBWETH,
    },
    DBWETH_DBUSDC_POOL: {
        address: `0x31d41c00e99672b9f7896950fe24e4993f88fb30a8e05dcd75a24cefe7b7d2d1`,
        baseCoin: Coins.DBWETH,
        quoteCoin: Coins.DBUSDC,
    }
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
