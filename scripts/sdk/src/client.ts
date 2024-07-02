import dotenv from "dotenv";
import path from "path";

// Specify the path to the .env file
const envPath = path.resolve(__dirname, '../.env');
dotenv.config({ path: envPath });

import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui.js/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui.js/keypairs/secp256r1';
import { checkManagerBalance, createAndShareBalanceManager, depositIntoManager, withdrawAllFromManager, withdrawFromManager } from "./balanceManager";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getSigner, getSignerFromPK, signAndExecuteWithClientAndSigner, validateAddressThrow } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { Coin, Coins, OrderType, Pool, Pools, SelfMatchingOptions, MANAGER_ADDRESSES, Constants } from "./coinConstants";
import { bcs } from "@mysten/sui.js/bcs";
import { accountOpenOrders, addDeepPricePoint, burnDeep, cancelAllOrders, cancelOrder, claimRebates, getBaseQuantityOut,
    getLevel2Range, getLevel2TicksFromMid, getPoolIdByAssets, getQuoteQuantityOut, midPrice, placeLimitOrder, placeMarketOrder,
    swapExactBaseForQuote, swapExactQuoteForBase, vaultBalances, whiteListed } from "./deepbook";
import { createPoolAdmin, unregisterPoolAdmin, updateDisabledVersions } from "./deepbookAdmin";
import { stake, submitProposal, unstake, vote } from "./governance";

/// DeepBook Client. If a private key is provided, then all transactions
/// will be signed with that key. Otherwise, the default key will be used.
/// Placing orders requires a balance manager to be set.
/// Client is initialized with default Coins and Pools. To trade on more pools,
/// new coins / pools must be added to the client.
export class DeepBookClient {
    #client: SuiClient;
    #signer: Ed25519Keypair | Secp256k1Keypair | Secp256r1Keypair;
    #balanceManagers: { [key: string]: { address: string, tradeCapId: string | null } } = {};
    #coins: { [key: string]: Coin } = {};
    #pools: { [key: string]: Pool } = {};

    constructor(
        network: "mainnet" | "testnet" | "devnet" | "localnet",
        privateKey?: string,
    ) {
        this.#client = new SuiClient({ url: getFullnodeUrl(network) });
        if (!privateKey) {
            this.#signer = getSigner();
        } else {
            this.#signer = getSignerFromPK(privateKey);
        }
    }

    async init(mergeCoins: boolean) {
        await this.initCoins();  // Initialize only the SUI coin
        if (mergeCoins) {
            const suiCoinId = this.#coins["SUI"].coinId;
            for (const coinKey in Coins) {
                if (Object.prototype.hasOwnProperty.call(this.#coins, coinKey)) {
                    await this.mergeAllCoins(this.#coins[coinKey].type, suiCoinId);
                }
            }
        }
        await this.initCoins();  // Initialize all coins to get correct new coin IDs
        this.initPools();
        this.initBalanceManagers();
    }

    getActiveAddress() {
        return this.#signer.getPublicKey().toSuiAddress();
    }

    async getOwnedCoin(coinType: string) {
        const coins = await this.#client.getCoins({
            owner: this.getActiveAddress(),
            coinType: coinType,
            limit: 1,
        });

        if (coins.data.length > 0) {
            return coins.data[0].coinObjectId;
        } else {
            return null;
        }
    }

    // Merge all owned coins of a specific type into a single coin.
    async mergeAllCoins(
        coinType: string,
        gasCoinId: string,
    ): Promise<void> {
        let moreCoinsToMerge = true;
        while (moreCoinsToMerge) {
            moreCoinsToMerge = await this.mergeOwnedCoins(coinType, gasCoinId);
        }
    }

    // Merge all owned coins of a specific type into a single coin.
    // Returns true if there are more coins to be merged still,
    // false otherwise. Run this function in a while loop until it returns false.
    // A gas coin object ID must be explicitly provided to avoid merging it.
    async mergeOwnedCoins(
        coinType: string,
        gasCoinId: string,
    ): Promise<boolean> {
        // store all coin objects
        let coins = [];
        const data = await this.#client.getCoins({
            owner: this.getActiveAddress(),
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
        const gas = await this.#client.getObject({
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

        const res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });

        return true;
    }


    // Initialize coins in the client.
    async initCoins() {
        for (const coinKey in Coins) {
            if (Object.prototype.hasOwnProperty.call(Coins, coinKey)) {
                const coin = Coins[coinKey];
                if (!coin.coinId) {
                    const accountCoin = await this.getOwnedCoin(coin.type);
                    this.#coins[coinKey] = {
                        ...coin,
                        coinId: accountCoin || '',
                    };
                } else {
                    this.#coins[coinKey] = coin;
                }
            }
        }
    }

    initPools() {
        for (const poolName in Pools) {
            if (Object.prototype.hasOwnProperty.call(Pools, poolName)) {
                const pool = Pools[poolName];
                this.#pools[poolName] = pool;
            }
        }
    }

    initBalanceManagers() {
        for (const managerName in MANAGER_ADDRESSES) {
            if (Object.prototype.hasOwnProperty.call(MANAGER_ADDRESSES, managerName)) {
                const manager = MANAGER_ADDRESSES[managerName];
                this.#balanceManagers[managerName] = {
                    address: manager.address,
                    tradeCapId: manager.tradeCapId
                };
            }
        }
    }

    getCoins() {
        return this.#coins;
    }

    addPool(
        poolName: string,
        poolAddress: string,
        baseCoinAddress: string,
        quoteCoinAddress: string,
    ) {
        validateAddressThrow(poolAddress, "pool address");
        let baseCoin = this.#coins[baseCoinAddress];
        let quoteCoin = this.#coins[quoteCoinAddress];

        this.#pools[poolName] = {
            address: poolAddress,
            baseCoin,
            quoteCoin,
        };
    }

    getPools() {
        return this.#pools;
    }

    /// Balance Manager
    async createAndShareBalanceManager() {
        let txb = new TransactionBlock();
        createAndShareBalanceManager(txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async depositIntoManager(managerName: string, amountToDeposit: number, coinKey: string) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#coins[coinKey];
        if (!coin) {
            throw new Error(`Coin with key ${coinKey} not found.`);
        }

        validateAddressThrow(coin.address, "coin address");

        let txb = new TransactionBlock();
        depositIntoManager(managerName, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(managerName: string, amountToWithdraw: number, coinKey: string) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#coins[coinKey];
        if (!coin) {
            throw new Error(`Coin with key ${coinKey} not found.`);
        }

        validateAddressThrow(coin.address, "coin address");

        let txb = new TransactionBlock();
        withdrawFromManager(managerName, amountToWithdraw, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(managerName: string, coinKey: string) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#coins[coinKey];
        if (!coin) {
            throw new Error(`Coin with key ${coinKey} not found.`);
        }

        validateAddressThrow(coin.address, "coin address");

        let txb = new TransactionBlock();
        withdrawAllFromManager(managerName, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(managerName: string, coinKey: string) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#coins[coinKey];
        if (!coin) {
            throw new Error(`Coin with key ${coinKey} not found.`);
        }

        validateAddressThrow(coin.address, "coin address");

        let txb = new TransactionBlock();
        checkManagerBalance(managerName, coin, txb);
        let sender = normalizeSuiAddress(this.#signer.getPublicKey().toSuiAddress());
        const res = await this.#client.devInspectTransactionBlock({
            sender: sender,
            transactionBlock: txb
        });

        const bytes = res.results![0].returnValues![0][0];
        const parsed_balance = bcs.U64.parse(new Uint8Array(bytes));
        const balanceNumber = Number(parsed_balance);
        const adjusted_balance = balanceNumber / coin.scalar;

        console.log(`Manager balance for ${coin.type} is ${adjusted_balance.toString()}`); // Output the u64 number as a string
    }

    /// DeepBook
    async placeLimitOrder(
        poolName: string,
        managerName: string,
        clientOrderId: number,
        price: number,
        quantity: number,
        isBid: boolean,
        expiration?: number,
        orderType?: OrderType,
        selfMatchingOption?: SelfMatchingOptions,
        payWithDeep?: boolean,
    ) {
        if (expiration === undefined) {
            expiration = Constants.LARGE_TIMESTAMP;
        }
        if (orderType === undefined) {
            orderType = OrderType.NO_RESTRICTION;
        }
        if (selfMatchingOption === undefined) {
            selfMatchingOption = SelfMatchingOptions.SELF_MATCHING_ALLOWED;
        }
        if (payWithDeep === undefined) {
            payWithDeep = true;
        }

        if (!payWithDeep) {
            throw new Error("payWithDeep = false not yet supported.");
        }
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        placeLimitOrder(pool, managerName, clientOrderId, price, quantity, isBid, expiration, orderType, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async placeMarketOrder(
        poolName: string,
        managerName: string,
        clientOrderId: number,
        quantity: number,
        isBid: boolean,
        selfMatchingOption?: SelfMatchingOptions,
        payWithDeep?: boolean,
    ) {
        if (selfMatchingOption === undefined) {
            selfMatchingOption = SelfMatchingOptions.SELF_MATCHING_ALLOWED;
        }
        if (payWithDeep === undefined) {
            payWithDeep = true;
        }

        if (!payWithDeep) {
            throw new Error("payWithDeep = false not supported.");
        }
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        placeMarketOrder(pool, managerName, clientOrderId, quantity, isBid, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelOrder(
        poolName: string,
        managerName: string,
        clientOrderId: number,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        cancelOrder(pool, managerName, clientOrderId, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelAllOrders(
        poolName: string,
        managerName: string,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        cancelAllOrders(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactBaseForQuote(
        poolName: string,
        baseKey: string,
        baseAmount: number,
        deepAmount: number,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        let baseCoinId = this.#coins[baseKey].coinId;
        let deepCoinId = this.#coins["DEEP"].coinId;
        swapExactBaseForQuote(pool, baseAmount, baseCoinId, deepAmount, deepCoinId, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactQuoteForBase(
        poolName: string,
        quoteKey: string,
        quoteAmount: number,
        deepAmount: number,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        let quoteCoinId = this.#coins[quoteKey].coinId;
        let deepCoinId = this.#coins["DEEP"].coinId;
        swapExactQuoteForBase(pool, quoteAmount, quoteCoinId, deepAmount, deepCoinId, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async addDeepPricePoint(
        targetPoolName: string,
        referencePoolName: string,
    ) {
        let targetPool = this.#pools[targetPoolName];
        let referencePool = this.#pools[referencePoolName];
        let txb = new TransactionBlock();
        addDeepPricePoint(targetPool, referencePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async claimRebates(
        poolName: string,
        managerName: string,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        claimRebates(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async burnDeep(
        poolName: string,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        burnDeep(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async midPrice(
        poolName: string,
    ): Promise<number> {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        return await midPrice(pool, txb);
    }

    async whitelisted(
        poolName: string
    ): Promise<boolean> {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        return await whiteListed(pool, txb);
    }

    async getQuoteQuantityOut(
        poolName: string,
        baseQuantity: number
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        await getQuoteQuantityOut(pool, baseQuantity, txb);
    }

    async getBaseQuantityOut(
        poolName: string,
        quoteQuantity: number
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        await getBaseQuantityOut(pool, quoteQuantity, txb);
    }

    async accountOpenOrders(
        poolName: string,
        managerName: string
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        await accountOpenOrders(pool, managerName, txb);
    }

    async getLevel2Range(
        poolName: string,
        priceLow: number,
        priceHigh: number,
        isBid: boolean,
    ): Promise<string[][]> {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        return getLevel2Range(pool, priceLow, priceHigh, isBid, txb);
    }

    async getLevel2TicksFromMid(
        poolName: string,
        ticks: number,
    ): Promise<string[][]> {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        return getLevel2TicksFromMid(pool, ticks, txb);
    }

    async vaultBalances(
        poolName: string,
    ): Promise<number[]> {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();

        return vaultBalances(pool, txb);
    }

    async getPoolIdByAssets(
        baseType: string,
        quoteType: string,
    ): Promise<string> {
        let txb = new TransactionBlock();

        return getPoolIdByAssets(baseType, quoteType, txb);
    }

    /// DeepBook Admin
    async createPoolAdmin(
        baseCoinKey: string,
        quoteCoinKey: string,
        tickSize: number,
        lotSize: number,
        minSize: number,
        whitelisted: boolean,
        stablePool: boolean,
    ) {
        let txb = new TransactionBlock();
        let baseCoin = this.#coins[baseCoinKey];
        let quoteCoin = this.#coins[quoteCoinKey];
        let deepCoinId = this.#coins["DEEP"].coinId;
        createPoolAdmin(baseCoin, quoteCoin, deepCoinId, tickSize, lotSize, minSize, whitelisted, stablePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unregisterPoolAdmin(
        poolName: string,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        unregisterPoolAdmin(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async updateDisabledVersions(
        poolName: string,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        updateDisabledVersions(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async stake(
        poolName: string,
        managerName: string,
        amount: number
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        stake(pool, managerName, amount, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unstake(
        poolName: string,
        managerName: string
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        unstake(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async submitProposal(
        poolName: string,
        managerName: string,
        takerFee: number,
        makerFee: number,
        stakeRequired: number,
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        submitProposal(pool, managerName, takerFee, makerFee, stakeRequired, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async vote(
        poolName: string,
        managerName: string,
        proposal_id: string
    ) {
        let pool = this.#pools[poolName];
        let txb = new TransactionBlock();
        vote(pool, managerName, proposal_id, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    validateBalanceManager(
        managerName: string,
    ) {
        if (!this.#balanceManagers[managerName]) {
            throw new Error("Balance manager not set, set it first.");
        }
    }
}

const testClient = async () => {
    let client = new DeepBookClient("testnet");
    await client.init(false); // true to merge coins of the same type

    // await client.depositIntoManager("MANAGER_1", 10, "SUI");
    // await client.depositIntoManager("MANAGER_1", 1000, "DBUSDC");
    // await client.depositIntoManager("MANAGER_1", 1000, "DEEP");
    // await client.depositIntoManager("MANAGER_1", 100, "DBWETH");
    // await client.withdrawAllFromManager("MANAGER_1", "DBUSDC");
    // await client.createPoolAdmin("DBWETH", "DBUSDC", 0.001, 0.001, 0.1, false, false);
    // await client.addDeepPricePoint("DBWETH_DBUSDC_POOL", "DEEP_DBWETH_POOL");
    // await client.placeLimitOrder("DBWETH_DBUSDC_POOL", "MANAGER_1", 888, 2, 1, true);
    // await client.checkManagerBalance("MANAGER_1", "DBUSDC");
}

testClient();
