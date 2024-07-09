import dotenv from "dotenv";
import path from "path";

// Specify the path to the .env file
const envPath = path.resolve(__dirname, '../.env');
dotenv.config({ path: envPath });

import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui.js/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui.js/keypairs/secp256r1';
import { checkManagerBalance, createAndShareBalanceManager, depositIntoManager, withdrawAllFromManager, withdrawFromManager } from "./transactions/balanceManager";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getSigner, getSignerFromPK, signAndExecuteWithClientAndSigner } from "./utils/utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { bcs } from "@mysten/sui.js/bcs";
import { accountOpenOrders, addDeepPricePoint, burnDeep, cancelAllOrders, cancelOrder, claimRebates, getBaseQuantityOut,
    getLevel2Range, getLevel2TicksFromMid, getPoolIdByAssets, getQuoteQuantityOut, midPrice, placeLimitOrder, placeMarketOrder,
    swapExactBaseForQuote, swapExactQuoteForBase, vaultBalances, whitelisted } from "./transactions/deepbook";
import { createPoolAdmin, unregisterPoolAdmin, updateDisabledVersions } from "./transactions/deepbookAdmin";
import { stake, submitProposal, unstake, vote } from "./transactions/governance";
import { DeepBookConfig, LARGE_TIMESTAMP } from "./utils/config";
import { BalanceManager, CoinKey, OrderType, PoolKey, SelfMatchingOptions, PlaceLimitOrderParams,
    PlaceMarketOrderParams, ProposalParams, SwapParams, CreatePoolAdminParams, Environment } from "./utils/interfaces";

/// DeepBook Client. If a private key is provided, then all transactions
/// will be signed with that key. Otherwise, the default key will be used.
/// Placing orders requires a balance manager to be set.
/// Client is initialized with default Coins and Pools. To trade on more pools,
/// new coins / pools must be added to the client.
export class DeepBookClient {
    #client: SuiClient;
    #signer: Ed25519Keypair | Secp256k1Keypair | Secp256r1Keypair;
    #balanceManagers: { [key: string]: BalanceManager } = {};
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
        await this.#config.init(this.#client, this.#signer, mergeCoins);
    }

    getActiveAddress() {
        return this.#signer.getPublicKey().toSuiAddress();
    }

    addBalanceManager(managerKey: string, managerId: string, tradeCapId?: string) {
        this.#balanceManagers[managerKey] = {
            address: managerId,
            tradeCap: tradeCapId
        };
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

    async depositIntoManager(managerKey: string, amountToDeposit: number, coinKey: CoinKey) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        depositIntoManager(balanceManager.address, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(managerKey: string, amountToWithdraw: number, coinKey: CoinKey) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        withdrawFromManager(balanceManager.address, amountToWithdraw, coin, recipient, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(managerKey: string, coinKey: CoinKey) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        withdrawAllFromManager(balanceManager.address, coin, recipient, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(managerKey: string, coinKey: CoinKey) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        checkManagerBalance(balanceManager.address, coin, txb);
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
    async placeLimitOrder(params: PlaceLimitOrderParams) {
        var {
            poolKey,
            managerKey,
            clientOrderId,
            price,
            quantity,
            isBid,
            expiration,
            orderType,
            selfMatchingOption,
            payWithDeep,
        } = params;

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
        let balanceManager = this.getBalanceManager(managerKey);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        placeLimitOrder(pool, balanceManager, clientOrderId, price, quantity, isBid, expiration, orderType, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async placeMarketOrder(params: PlaceMarketOrderParams) {
        var {
            poolKey,
            managerKey,
            clientOrderId,
            quantity,
            isBid,
            selfMatchingOption,
            payWithDeep,
        } = params;

        if (selfMatchingOption === undefined) {
            selfMatchingOption = SelfMatchingOptions.SELF_MATCHING_ALLOWED;
        }
        if (payWithDeep === undefined) {
            payWithDeep = true;
        }

        if (!payWithDeep) {
            throw new Error("payWithDeep = false not supported.");
        }
        let balanceManager = this.getBalanceManager(managerKey);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        placeMarketOrder(pool, balanceManager, clientOrderId, quantity, isBid, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelOrder(
        poolKey: PoolKey,
        managerKey: string,
        clientOrderId: number,
    ) {
        let balanceManager = this.getBalanceManager(managerKey);
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        cancelOrder(pool, balanceManager, clientOrderId, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelAllOrders(
        poolKey: PoolKey,
        managerKey: string,
    ) {
        let balanceManager = this.getBalanceManager(managerKey);
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        cancelAllOrders(pool, balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactBaseForQuote(params: SwapParams) {
        const {
            poolKey,
            coinKey: baseKey,
            amount: baseAmount,
            deepAmount,
        } = params;

        let pool = this.#config.getPool(poolKey);
        let baseCoinId = this.#config.getCoin(baseKey).coinId;
        let deepCoinId = this.#config.getCoin(CoinKey.DEEP).coinId;

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        swapExactBaseForQuote(pool, baseAmount, baseCoinId, deepAmount, deepCoinId, recipient, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactQuoteForBase(params: SwapParams) {
        const {
            poolKey,
            coinKey: quoteKey,
            amount: quoteAmount,
            deepAmount,
        } = params;

        let pool = this.#config.getPool(poolKey);
        let quoteCoinId = this.#config.getCoin(quoteKey).coinId;
        let deepCoinId = this.#config.getCoin(CoinKey.DEEP).coinId;

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        swapExactQuoteForBase(pool, quoteAmount, quoteCoinId, deepAmount, deepCoinId, recipient, txb);

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
        managerKey: string,
    ) {
        const balanceManager = this.getBalanceManager(managerKey);

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        claimRebates(pool, balanceManager, txb);
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
        return await whitelisted(pool, txb);
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
        managerKey: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        await accountOpenOrders(pool, managerKey, txb);
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
    async createPoolAdmin(params: CreatePoolAdminParams) {
        const {
            baseCoinKey,
            quoteCoinKey,
            tickSize,
            lotSize,
            minSize,
            whitelisted,
            stablePool,
        } = params;

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
        managerKey: string,
        amount: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        const balanceManager = this.getBalanceManager(managerKey);
        stake(pool, balanceManager, amount, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unstake(
        poolKey: PoolKey,
        managerKey: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        const balanceManager = this.getBalanceManager(managerKey);
        unstake(pool, balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async submitProposal(params: ProposalParams) {
        const {
            poolKey,
            managerKey,
            takerFee,
            makerFee,
            stakeRequired,
        } = params;

        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        const balanceManager = this.getBalanceManager(managerKey);
        submitProposal(pool, balanceManager, takerFee, makerFee, stakeRequired, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async vote(
        poolKey: PoolKey,
        managerKey: string,
        proposal_id: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        const balanceManager = this.getBalanceManager(managerKey);
        vote(pool, balanceManager, proposal_id, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async signAndExecute(txb: TransactionBlock) {
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    getBalanceManager(
        managerKey: string,
    ): BalanceManager {
        if (!this.#balanceManagers.hasOwnProperty(managerKey)) {
            throw new Error(`Balance manager with key ${managerKey} not found.`);
        }

        return this.#balanceManagers[managerKey];
    }
}

const testClient = async () => {
    let env = process.env.ENV as Environment;
    if (!env || !["mainnet", "testnet", "devnet", "localnet"].includes(env)) {
        throw new Error(`Invalid environment: ${process.env.ENV}`);
    }

    let client = new DeepBookClient(env, process.env.PRIVATE_KEY!);
    let mergeCoins = false;
    await client.init(mergeCoins);
    client.addBalanceManager("MANAGER_1", "0x0c34e41694c5347c7a45978d161b5d6b543bec80702fee6e002118f333dbdfaf");

    // await client.depositIntoManager("MANAGER_1", 10, CoinKey.SUI);
    // await client.withdrawAllFromManager("MANAGER_1", CoinKey.SUI);
    // await client.createPoolAdmin({
    //     baseCoinKey: CoinKey.DBWETH,
    //     quoteCoinKey: CoinKey.DBUSDC,
    //     tickSize: 0.001,
    //     lotSize: 0.001,
    //     minSize: 0.01,
    //     whitelisted: false,
    //     stablePool: false,
    // });
    // await client.addDeepPricePoint(PoolKey.DBWETH_DBUSDC, PoolKey.DEEP_DBWETH);
    // await client.checkManagerBalance("MANAGER_1", CoinKey.DBUSDC);
    // await client.placeLimitOrder({
    //     poolKey: PoolKey.DBWETH_DBUSDC,
    //     managerKey: 'MANAGER_1',
    //     clientOrderId: 888,
    //     price: 2,
    //     quantity: 1,
    //     isBid: true,
    // })
    // await client.placeMarketOrder({
    //     poolKey: PoolKey.DBWETH_DBUSDC,
    //     managerKey: 'MANAGER_1',
    //     clientOrderId: 888,
    //     quantity: 1,
    //     isBid: true,
    // })
    // await client.submitProposal({
    //     poolKey: PoolKey.DBWETH_DBUSDC,
    //     managerKey: 'MANAGER_1',
    //     takerFee: 0.003,
    //     makerFee: 0.002,
    //     stakeRequired: 1000,
    // });
    // await client.swapExactBaseForQuote({
    //     poolKey: PoolKey.DBWETH_DBUSDC,
    //     coinKey: CoinKey.DBWETH,
    //     amount: 1000,
    //     deepAmount: 500,
    // });
    // await client.swapExactQuoteForBase({
    //     poolKey: PoolKey.DBWETH_DBUSDC,
    //     coinKey: CoinKey.DBUSDC,
    //     amount: 1000,
    //     deepAmount: 500,
    // });
}

testClient();
