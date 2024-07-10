import { SuiClient } from "@mysten/sui.js/client";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecuteWithClientAndSigner } from "./utils";
import { Keypair } from "@mysten/sui.js/cryptography";
import { Coin, Pool, Config } from "./interfaces";
import { DBUSDC_ID_TESTNET, DBUSDC_KEY, DBUSDC_SCALAR_TESTNET, DBUSDC_TYPE_TESTNET, DBWETH_DBUSDC_ID_TESTNET, DBWETH_DBUSDC_KEY, DBWETH_ID_TESTNET, DBWETH_KEY, DBWETH_SCALAR_TESTNET, DBWETH_TYPE_TESTNET, DEEPBOOK_PACKAGE_ID_MAINNET, DEEPBOOK_PACKAGE_ID_TESTNET, DEEP_DBWETH_ID_TESTNET, DEEP_DBWETH_KEY, DEEP_ID_MAINNET, DEEP_ID_TESTNET, DEEP_KEY, DEEP_SCALAR_MAINNET, DEEP_SCALAR_TESTNET, DEEP_SUI_ID_TESTNET, DEEP_SUI_KEY, DEEP_TREASURY_ID_MAINNET, DEEP_TREASURY_ID_TESTNET, DEEP_TYPE_MAINNET, DEEP_TYPE_TESTNET, REGISTRY_ID_MAINNET, REGISTRY_ID_TESTNET, SUI_DBUSDC_ID_TESTNET, SUI_DBUSDC_KEY, SUI_ID_MAINNET, SUI_ID_TESTNET, SUI_KEY, SUI_SCALAR_MAINNET, SUI_SCALAR_TESTNET, SUI_TYPE_MAINNET, SUI_TYPE_TESTNET, USDC_ID_MAINNET, USDC_KEY, USDC_SCALAR_MAINNET, USDC_TYPE_MAINNET, WETH_ID_MAINNET, WETH_KEY, WETH_SCALAR_MAINNET, WETH_TYPE_MAINNET } from "./constants";

const getConfig = (): Config => {
    let env = process.env.ENV;
    if (!env || !["mainnet", "testnet", "devnet", "localnet"].includes(env)) {
        throw new Error(`Invalid ENV value: ${process.env.ENV}`);
    }

    switch (env) {
        case "mainnet":
            return {
                DEEPBOOK_PACKAGE_ID: DEEPBOOK_PACKAGE_ID_MAINNET,
                REGISTRY_ID: REGISTRY_ID_MAINNET,
                DEEP_TREASURY_ID: DEEP_TREASURY_ID_MAINNET
            };
        case "testnet":
            return {
                DEEPBOOK_PACKAGE_ID: DEEPBOOK_PACKAGE_ID_TESTNET,
                REGISTRY_ID: REGISTRY_ID_TESTNET,
                DEEP_TREASURY_ID: DEEP_TREASURY_ID_TESTNET,
            };
        default:
            throw new Error(`Invalid environment: ${env}`);
    }
};

export const { DEEPBOOK_PACKAGE_ID, REGISTRY_ID, DEEP_TREASURY_ID } = getConfig();

export class DeepBookConfig {
    coins: { [key: string]: Coin } = {};
    pools: { [key: string]: Pool } = {};

    constructor() {}

    async init(suiClient: SuiClient, signer: Keypair, merge: boolean) {
        let env = process.env.ENV;
        if (!env) {
            env = "testnet";
        }
        if (env === "testnet") {
            await this.initCoinsTestnet(suiClient, signer, merge);
            this.initPoolsTestnet();
        } else if (env === "mainnet") {
            await this.initCoinsMainnet(suiClient, signer, merge);
            this.initPoolsMainnet();
        }
    }

    async initCoinsTestnet(suiClient: SuiClient, signer: Keypair, merge: boolean) {
        this.coins[DEEP_KEY] = {
            key: DEEP_KEY,
            address: DEEP_ID_TESTNET,
            type: DEEP_TYPE_TESTNET,
            scalar: DEEP_SCALAR_TESTNET,
            coinId: ``
        };
        this.coins[SUI_KEY] = {
            key: SUI_KEY,
            address: SUI_ID_TESTNET,
            type: SUI_TYPE_TESTNET,
            scalar: SUI_SCALAR_TESTNET,
            coinId: ``
        };
        this.coins[DBUSDC_KEY] = {
            key: DBUSDC_KEY,
            address: DBUSDC_ID_TESTNET,
            type: DBUSDC_TYPE_TESTNET,
            scalar: DBUSDC_SCALAR_TESTNET,
            coinId: ``
        };
        this.coins[DBWETH_KEY] = {
            key: DBWETH_KEY,
            address: DBWETH_ID_TESTNET,
            type: DBWETH_TYPE_TESTNET,
            scalar: DBWETH_SCALAR_TESTNET,
            coinId: ``
        }
        await this.fetchCoinData(suiClient, signer, merge);
    }

    async initCoinsMainnet(suiClient: SuiClient, signer: Keypair, merge: boolean) {
        this.coins[DEEP_KEY] = {
            key: DEEP_KEY,
            address: DEEP_ID_MAINNET,
            type: DEEP_TYPE_MAINNET,
            scalar: DEEP_SCALAR_MAINNET,
            coinId: ``
        };
        this.coins[SUI_KEY] = {
            key: SUI_KEY,
            address: SUI_ID_MAINNET,
            type: SUI_TYPE_MAINNET,
            scalar: SUI_SCALAR_MAINNET,
            coinId: ``
        };
        this.coins[USDC_KEY] = {
            key: USDC_KEY,
            address: USDC_ID_MAINNET,
            type: USDC_TYPE_MAINNET,
            scalar: USDC_SCALAR_MAINNET,
            coinId: ``
        };
        this.coins[WETH_KEY] = {
            key: WETH_KEY,
            address: WETH_ID_MAINNET,
            type: WETH_TYPE_MAINNET,
            scalar: WETH_SCALAR_MAINNET,
            coinId: ``
        }
        await this.fetchCoinData(suiClient, signer, merge);
    }

    initPoolsTestnet() {
        this.pools[DEEP_SUI_KEY] = {
            address: DEEP_SUI_ID_TESTNET,
            baseCoin: this.coins[DEEP_KEY],
            quoteCoin: this.coins[SUI_KEY],
        };
        this.pools[SUI_DBUSDC_KEY] = {
            address: 0x95e7b7b9ac99327d1c1e2d0e650510849e64425c4b2fc676d49828f699024995,
            baseCoin: this.coins[SUI_KEY],
            quoteCoin: this.coins[DBUSDC_KEY],
        };
        this.pools[DEEP_DBWETH_KEY] = {
            address: DEEP_DBWETH_ID_TESTNET,
            baseCoin: this.coins[DEEP_KEY],
            quoteCoin: this.coins[DBWETH_KEY],
        };
        this.pools[DBWETH_DBUSDC_KEY] = {
            address: DBWETH_DBUSDC_ID_TESTNET,
            baseCoin: this.coins[DBWETH_KEY],
            quoteCoin: this.coins[DBUSDC_KEY],
        }
    }

    initPoolsMainnet() {
        this.pools[DEEP_SUI_KEY] = {
            address: ``,
            baseCoin: this.coins[DEEP_KEY],
            quoteCoin: this.coins[SUI_KEY],
        };
    }

    async getOwnedCoin(suiClient: SuiClient, signer: Keypair, coinType: string): Promise<string> {
        const owner = signer.toSuiAddress();
        const res = await suiClient.getCoins({
            owner,
            coinType,
            limit: 1,
        });

        if (res.data.length > 0) {
            return res.data[0].coinObjectId;
        } else {
            return '';
        }
    }

    async fetchCoinData(suiClient: SuiClient, signer: Keypair, merge: boolean) {
        // if merge is true and signer provided, merge all whitelisted coins into one object.
        if (merge) {
            let gasCoinId = await this.getOwnedCoin(suiClient, signer, this.coins[SUI_KEY].type);
            if (gasCoinId === '') {
                throw new Error("Failed to find gas object. Cannot merge coins.");
            }
            for (const coinKey in this.coins) {
                await this.mergeAllCoins(suiClient, signer, this.coins[coinKey].type, gasCoinId);
            }
        }

        // fetch all coin object IDs and set them internally.
        for (const coinKey in this.coins) {
            const coin = this.coins[coinKey];
            if (!coin.coinId) {
                const accountCoin = await this.getOwnedCoin(suiClient, signer, coin.type);
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
        coinType: string,
        gasCoinId: string,
    ): Promise<void> {
        let moreCoinsToMerge = true;
        const owner = signer.toSuiAddress();
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

    // Getters
    getCoin(key: string): Coin {
        const coin = this.coins[key];
        if (!coin) {
            throw new Error(`Coin not found for key: ${key}`);
        }

        return coin;
    }

    getPool(key: string): Pool {
        const pool = this.pools[key];
        if (!pool) {
            throw new Error(`Pool not found for key: ${key}`);
        }

        return pool;
    }
}

export { Pool };
