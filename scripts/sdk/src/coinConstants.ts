import { getActiveAddress } from "./utils";

// Update env, package IDs, manager id as needed
export const ENV = 'testnet';
export const DEEPBOOK_PACKAGE_ID = `0x16dfa5d75e978a3ec535188e904cb1fc238baff8bc1a7ac9a0d73e04559efad9`;
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
