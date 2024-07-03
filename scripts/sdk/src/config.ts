import { SuiClient } from "@mysten/sui.js/client";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecuteWithClientAndSigner } from "./utils";
import { Keypair } from "@mysten/sui.js/cryptography";

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
export const FLOAT_SCALAR = 1000000000;
export const POOL_CREATION_FEE = 10000 * 1000000;
export const LARGE_TIMESTAMP = 1844674407370955161;
export const GAS_BUDGET = 0.5 * 500000000; // Adjust based on benchmarking
export const DEEP_SCALAR = 1000000;
export const DEEPBOOK_PACKAGE_ID = `0xdc1b11f060e96cb30092991d361aff6d78a7c3e9df946df5850a26f9a96b8778`;
export const REGISTRY_ID = `0x57fea19ce09abf8879327507fa850753f7c6bd468a74971146c38e92aaa39e37`;
export const DEEP_TREASURY_ID = `0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb`;

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

export class DeepBookConfig {
    coins: { [key: string]: Coin } = {};
    pools: { [key: string]: Pool } = {};

    constructor() {}

    async init(suiClient: SuiClient, owner: string, merge?: { signer: Keypair }) {
        await this.initCoins(suiClient, owner, merge);
        this.initPools();
    }

    async initCoins(suiClient: SuiClient, owner: string, merge?: { signer: Keypair }) {
        this.coins[CoinKey.DEEP] = {
            key: CoinKey.DEEP,
            address: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8`,
            type: `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`,
            scalar: 1000000,
            coinId: ``
        };
        this.coins[CoinKey.SUI] = {
            key: CoinKey.SUI,
            address: `0x0000000000000000000000000000000000000000000000000000000000000002`,
            type: `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`,
            scalar: 1000000000,
            coinId: ``
        };
        this.coins[CoinKey.DBUSDC] = {
            key: CoinKey.DBUSDC,
            address: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f`,
            type: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f::DBUSDC::DBUSDC`,
            scalar: 1000000,
            coinId: ``
        };
        this.coins[CoinKey.DBWETH] = {
            key: CoinKey.DBWETH,
            address: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f`,
            type: `0xd5aa5b65d97ed7fc0c2b063689805353d56f64f7e8407ac3b95b7e6fdea2256f::DBWETH::DBWETH`,
            scalar: 100000000,
            coinId: ``
        }
        await this.fetchCoinData(suiClient, owner, merge);
    }

    async getOwnedCoin(suiClient: SuiClient, owner: string, coinType: string): Promise<string> {
        console.log(coinType);
        const res = await suiClient.getCoins({
            owner,
            coinType,
            limit: 1,
        });

        console.log(res);

        if (res.data.length > 0) {
            return res.data[0].coinObjectId;
        } else {
            return '';
        }
    }

    async fetchCoinData(suiClient: SuiClient, owner: string, merge?: { signer: Keypair }) {
        // if merge is true and signer provided, merge all whitelisted coins into one object.
        if (merge) {
            let gasCoinId = await this.getOwnedCoin(suiClient, owner, this.coins[CoinKey.SUI].type);
            if (gasCoinId === '') {
                throw new Error("Failed to find gas object. Cannot merge coins.");
            }
            for (const coinKey in this.coins) {
                await this.mergeAllCoins(suiClient, merge.signer, owner, this.coins[coinKey].type, gasCoinId);
            }
        }

        // fetch all coin object IDs and set them internally.
        for (const coinKey in this.coins) {
            const coin = this.coins[coinKey];
            if (!coin.coinId) {
                const accountCoin = await this.getOwnedCoin(suiClient, owner, coin.type);
                this.coins[coinKey] = {
                    ...coin,
                    coinId: accountCoin,
                };
            } else {
                this.coins[coinKey] = coin;
            }
        }
    }

    // Merge all owned coins of a specific type into a single coin.
    async mergeAllCoins(
        suiClient: SuiClient,
        signer: Keypair,
        owner: string,
        coinType: string,
        gasCoinId: string,
    ): Promise<void> {
        let moreCoinsToMerge = true;
        while (moreCoinsToMerge) {
            moreCoinsToMerge = await this.mergeOwnedCoins(suiClient, signer, owner, coinType, gasCoinId);
        }
    }

    // Merge all owned coins of a specific type into a single coin.
    // Returns true if there are more coins to be merged still,
    // false otherwise. Run this function in a while loop until it returns false.
    // A gas coin object ID must be explicitly provided to avoid merging it.
    async mergeOwnedCoins(
        suiClient: SuiClient,
        signer: Keypair,
        owner: string,
        coinType: string,
        gasCoinId: string,
    ): Promise<boolean> {
        // store all coin objects
        let coins = [];
        const data = await suiClient.getCoins({
            owner,
            coinType,
        });

        if (!data || !data.data) {
            console.error(`Failed to fetch coins of type: ${coinType}`);
            return false;
        }

        coins.push(...data.data.map(coin => ({
            objectId: coin.coinObjectId,
            version: coin.version,
            digest: coin.digest,
        })));

        coins = coins.filter(coin => coin.objectId !== gasCoinId);

        // no need to merge anymore if there are no coins or just one coin left
        if (coins.length <= 1) {
            return false;
        }

        const baseCoin = coins[0];
        const otherCoins = coins.slice(1);

        if (!baseCoin) {
            console.error("Base coin is undefined for type:", coinType);
            return false;
        }

        const txb = new TransactionBlock();
        const gas = await suiClient.getObject({
            id: gasCoinId,
        });
        if (!gas || !gas.data) {
            throw new Error("Failed to find gas object.");
        }
        txb.setGasPayment([gas.data!]);

        txb.mergeCoins(txb.objectRef({
            objectId: baseCoin.objectId,
            version: baseCoin.version,
            digest: baseCoin.digest,
        }), otherCoins.map(coin => txb.objectRef({
            objectId: coin.objectId,
            version: coin.version,
            digest: coin.digest,
        })));

        const res = await signAndExecuteWithClientAndSigner(txb, suiClient, signer);
        console.dir(res, { depth: null });

        return true;
    }

    initPools() {
        this.pools[PoolKey.DEEP_SUI] = {
            address: `0x67800bae6808206915c7f09203a00031ce9ce8550008862dda3083191e3954ca`,
            baseCoin: this.coins[CoinKey.DEEP],
            quoteCoin: this.coins[CoinKey.SUI],
        };
        this.pools[PoolKey.SUI_DBUSDC] = {
            address: `0x9442afa775e90112448f26a8d58ca76f66cf46e4b77e74d6d85cea30bedc289c`,
            baseCoin: this.coins[CoinKey.SUI],
            quoteCoin: this.coins[CoinKey.DBUSDC],
        };
        this.pools[PoolKey.DEEP_DBWETH] = {
            address: `0xe8d0f3525518aaaae64f3832a24606a9eadde8572d058c45626a4ab2cbfae1eb`,
            baseCoin: this.coins[CoinKey.DEEP],
            quoteCoin: this.coins[CoinKey.DBWETH],
        };
        this.pools[PoolKey.DBWETH_DBUSDC] = {
            address: `0x31d41c00e99672b9f7896950fe24e4993f88fb30a8e05dcd75a24cefe7b7d2d1`,
            baseCoin: this.coins[CoinKey.DBWETH],
            quoteCoin: this.coins[CoinKey.DBUSDC],
        }
    }

    // Getters
    getCoin(key: CoinKey): Coin {
        const coin = this.coins[key];
        if (!coin) {
            throw new Error(`Coin not found for key: ${key}`);
        }

        return coin;
    }

    getPool(key: PoolKey): Pool {
        const pool = this.pools[key];
        if (!pool) {
            throw new Error(`Pool not found for key: ${key}`);
        }

        return pool;
    }
}