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
import { OrderType, SelfMatchingOptions, MANAGER_ADDRESSES } from "./coinConstants";
import { bcs } from "@mysten/sui.js/bcs";
import { accountOpenOrders, addDeepPricePoint, burnDeep, cancelAllOrders, cancelOrder, claimRebates, getBaseQuantityOut,
    getLevel2Range, getLevel2TicksFromMid, getPoolIdByAssets, getQuoteQuantityOut, midPrice, placeLimitOrder, placeMarketOrder,
    swapExactBaseForQuote, swapExactQuoteForBase, vaultBalances, whiteListed } from "./deepbook";
import { createPoolAdmin, unregisterPoolAdmin, updateDisabledVersions } from "./deepbookAdmin";
import { stake, submitProposal, unstake, vote } from "./governance";
import { CoinKey, DeepBookConfig, LARGE_TIMESTAMP, PoolKey } from "./config";

/// DeepBook Client. If a private key is provided, then all transactions
/// will be signed with that key. Otherwise, the default key will be used.
/// Placing orders requires a balance manager to be set.
/// Client is initialized with default Coins and Pools. To trade on more pools,
/// new coins / pools must be added to the client.
export class DeepBookClient {
    #client: SuiClient;
    #signer: Ed25519Keypair | Secp256k1Keypair | Secp256r1Keypair;
    #balanceManagers: { [key: string]: { address: string, tradeCapId: string | null } } = {};
    #config: DeepBookConfig = new DeepBookConfig();

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
        if (mergeCoins) {
            await this.#config.init(this.#client, this.getActiveAddress(), { signer: this.#signer });
        } else {
            await this.#config.init(this.#client, this.getActiveAddress());
        }
        this.initBalanceManagers();
    }

    getActiveAddress() {
        return this.#signer.getPublicKey().toSuiAddress();
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

    getConfig() {
        return this.#config;
    }

    /// Balance Manager
    async createAndShareBalanceManager() {
        let txb = new TransactionBlock();
        createAndShareBalanceManager(txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async depositIntoManager(managerName: string, amountToDeposit: number, coinKey: CoinKey) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        depositIntoManager(managerName, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(managerName: string, amountToWithdraw: number, coinKey: CoinKey) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        withdrawFromManager(managerName, amountToWithdraw, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(managerName: string, coinKey: CoinKey) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        withdrawAllFromManager(managerName, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(managerName: string, coinKey: CoinKey) {
        if (!this.#balanceManagers.hasOwnProperty(managerName)) {
            throw new Error(`Balance manager with name ${managerName} not found.`);
        }

        const coin = this.#config.getCoin(coinKey);

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
        poolKey: PoolKey,
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
            expiration = LARGE_TIMESTAMP;
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

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        placeLimitOrder(pool, managerName, clientOrderId, price, quantity, isBid, expiration, orderType, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async placeMarketOrder(
        poolKey: PoolKey,
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

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        placeMarketOrder(pool, managerName, clientOrderId, quantity, isBid, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelOrder(
        poolKey: PoolKey,
        managerName: string,
        clientOrderId: number,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        cancelOrder(pool, managerName, clientOrderId, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelAllOrders(
        poolKey: PoolKey,
        managerName: string,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        cancelAllOrders(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactBaseForQuote(
        poolKey: PoolKey,
        baseKey: CoinKey,
        baseAmount: number,
        deepAmount: number,
    ) {
        let pool = this.#config.getPool(poolKey);
        let baseCoinId = this.#config.getCoin(baseKey).coinId;
        let deepCoinId = this.#config.getCoin(CoinKey.DEEP).coinId;

        let txb = new TransactionBlock();
        swapExactBaseForQuote(pool, baseAmount, baseCoinId, deepAmount, deepCoinId, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactQuoteForBase(
        poolKey: PoolKey,
        quoteKey: CoinKey,
        quoteAmount: number,
        deepAmount: number,
    ) {
        let pool = this.#config.getPool(poolKey);
        let quoteCoinId = this.#config.getCoin(quoteKey).coinId;
        let deepCoinId = this.#config.getCoin(CoinKey.DEEP).coinId;

        let txb = new TransactionBlock();
        swapExactQuoteForBase(pool, quoteAmount, quoteCoinId, deepAmount, deepCoinId, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async addDeepPricePoint(
        targetPoolKey: PoolKey,
        referencePoolKey: PoolKey,
    ) {
        let targetPool = this.#config.getPool(targetPoolKey);
        let referencePool = this.#config.getPool(referencePoolKey);
        let txb = new TransactionBlock();
        addDeepPricePoint(targetPool, referencePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async claimRebates(
        poolKey: PoolKey,
        managerName: string,
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        claimRebates(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async burnDeep(
        poolKey: PoolKey,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        burnDeep(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async midPrice(
        poolKey: PoolKey,
    ): Promise<number> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        return await midPrice(pool, txb);
    }

    async whitelisted(
        poolKey: PoolKey,
    ): Promise<boolean> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        return await whiteListed(pool, txb);
    }

    async getQuoteQuantityOut(
        poolKey: PoolKey,
        baseQuantity: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        await getQuoteQuantityOut(pool, baseQuantity, txb);
    }

    async getBaseQuantityOut(
        poolKey: PoolKey,
        quoteQuantity: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        await getBaseQuantityOut(pool, quoteQuantity, txb);
    }

    async accountOpenOrders(
        poolKey: PoolKey,
        managerName: string
    ) {
        this.validateBalanceManager(managerName);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        await accountOpenOrders(pool, managerName, txb);
    }

    async getLevel2Range(
        poolKey: PoolKey,
        priceLow: number,
        priceHigh: number,
        isBid: boolean,
    ): Promise<string[][]> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        return getLevel2Range(pool, priceLow, priceHigh, isBid, txb);
    }

    async getLevel2TicksFromMid(
        poolKey: PoolKey,
        ticks: number,
    ): Promise<string[][]> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        return getLevel2TicksFromMid(pool, ticks, txb);
    }

    async vaultBalances(
        poolKey: PoolKey,
    ): Promise<number[]> {
        let pool = this.#config.getPool(poolKey);
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
        baseCoinKey: CoinKey,
        quoteCoinKey: CoinKey,
        tickSize: number,
        lotSize: number,
        minSize: number,
        whitelisted: boolean,
        stablePool: boolean,
    ) {
        let txb = new TransactionBlock();
        let baseCoin = this.#config.getCoin(baseCoinKey);
        let quoteCoin = this.#config.getCoin(quoteCoinKey);
        let deepCoinId = this.#config.getCoin(CoinKey.DEEP).coinId;
        createPoolAdmin(baseCoin, quoteCoin, deepCoinId, tickSize, lotSize, minSize, whitelisted, stablePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unregisterPoolAdmin(
        poolKey: PoolKey,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        unregisterPoolAdmin(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async updateDisabledVersions(
        poolKey: PoolKey,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        updateDisabledVersions(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async stake(
        poolKey: PoolKey,
        managerName: string,
        amount: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        stake(pool, managerName, amount, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unstake(
        poolKey: PoolKey,
        managerName: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        unstake(pool, managerName, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async submitProposal(
        poolKey: PoolKey,
        managerName: string,
        takerFee: number,
        makerFee: number,
        stakeRequired: number,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        submitProposal(pool, managerName, takerFee, makerFee, stakeRequired, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async vote(
        poolKey: PoolKey,
        managerName: string,
        proposal_id: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        vote(pool, managerName, proposal_id, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async signAndExecute(txb: TransactionBlock) {
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
    let client = new DeepBookClient("testnet", process.env.PRIVATE_KEY!);
    await client.init(false); // true to merge coins of the same type
    console.log(client.getConfig().coins);

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
