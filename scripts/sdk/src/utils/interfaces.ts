export interface BalanceManager {
    address: string;
    tradeCap: string | undefined;
}

export interface Coin {
    key: CoinKey;
    address: string;
    type: string;
    scalar: number;
    coinId: string;
}

export interface Pool {
    address: string;
    baseCoin: Coin;
    quoteCoin: Coin;
}

export enum CoinKey {
    "DEEP",
    "SUI",
    "DBUSDC",
    "DBWETH",
}

export enum PoolKey {
    "DEEP_SUI",
    "SUI_DBUSDC",
    "DEEP_DBWETH",
    "DBWETH_DBUSDC",
}

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