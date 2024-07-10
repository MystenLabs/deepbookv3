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
import { borrowBaseAsset, returnBaseAsset } from "./transactions/flashLoans";
import { DeepBookConfig } from "./utils/config";
import { BalanceManager, OrderType, SelfMatchingOptions, PlaceLimitOrderParams,
    PlaceMarketOrderParams, ProposalParams, SwapParams, CreatePoolAdminParams, Environment } from "./utils/interfaces";
import { DEEP_KEY, MAX_TIMESTAMP, DEEP_SCALAR } from "./utils/constants";

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

    async depositIntoManager(managerKey: string, amountToDeposit: number, coinKey: string) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        depositIntoManager(balanceManager.address, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(managerKey: string, amountToWithdraw: number, coinKey: string) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        withdrawFromManager(balanceManager.address, amountToWithdraw, coin, recipient, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(managerKey: string, coinKey: string) {
        const balanceManager = this.getBalanceManager(managerKey);
        const coin = this.#config.getCoin(coinKey);

        let txb = new TransactionBlock();
        const recipient = this.getActiveAddress();
        withdrawAllFromManager(balanceManager.address, coin, recipient, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(managerKey: string, coinKey: string) {
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
        const {
            poolKey,
            managerKey,
            clientOrderId,
            price,
            quantity,
            isBid,
            expiration = MAX_TIMESTAMP,
            orderType = OrderType.NO_RESTRICTION,
            selfMatchingOption = SelfMatchingOptions.SELF_MATCHING_ALLOWED,
            payWithDeep = true,
        } = params;

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
        const {
            poolKey,
            managerKey,
            clientOrderId,
            quantity,
            isBid,
            selfMatchingOption = SelfMatchingOptions.SELF_MATCHING_ALLOWED,
            payWithDeep = true,
        } = params;

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
        poolKey: string,
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
        poolKey: string,
        managerKey: string,
    ) {
        let balanceManager = this.getBalanceManager(managerKey);
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        cancelAllOrders(pool, balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    borrowBaseAsset(
        poolKey: string,
        borrowAmount: number,
        txb: TransactionBlock,
    ) {
        let pool = this.#config.getPool(poolKey);

        return borrowBaseAsset(pool, borrowAmount, txb);
    }

    returnBaseAsset(
        poolKey: string,
        borrowAmount: number,
        baseCoin: any,
        flashLoan: any,
        txb: TransactionBlock,
    ) {
        let pool = this.#config.getPool(poolKey);
        const borrowScalar = pool.baseCoin.scalar;

        const [baseCoinReturn] = txb.splitCoins(
            baseCoin,
            [txb.pure.u64(borrowAmount * borrowScalar)]
        );
        returnBaseAsset(pool, baseCoinReturn, flashLoan, txb);
        txb.transferObjects([baseCoin], this.getActiveAddress());
    }

    async signTransaction(txb: TransactionBlock) {
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactBaseForQuote(params: SwapParams, txb: TransactionBlock) {
        const {
            poolKey,
            coinKey: baseKey,
            amount: baseAmount,
            deepAmount,
            deepCoin,
        } = params;

        let pool = this.#config.getPool(poolKey);
        let baseCoinId = this.#config.getCoin(baseKey).coinId;
        let deepCoinId = this.#config.getCoin("DEEP").coinId;
        const baseScalar = pool.baseCoin.scalar;

        let baseCoin;
        if (pool.baseCoin.key === "SUI") {
            [baseCoin] = txb.splitCoins(
                txb.gas,
                [txb.pure.u64(baseAmount * baseScalar)]
            );
        } else {
            [baseCoin] = txb.splitCoins(
                txb.object(baseCoinId),
                [txb.pure.u64(baseAmount * baseScalar)]
            );
        }
        if (!deepCoin) {
            var [deepCoinInput] = txb.splitCoins(
                txb.object(deepCoinId),
                [txb.pure.u64(deepAmount * DEEP_SCALAR)]
            );
            return swapExactBaseForQuote(pool, baseCoin, deepCoinInput, txb);
        }

        return swapExactBaseForQuote(pool, baseCoin, deepCoin, txb);
    }

    async swapExactQuoteForBase(params: SwapParams, txb: TransactionBlock) {
        const {
            poolKey,
            coinKey: quoteKey,
            amount: quoteAmount,
            deepAmount,
            deepCoin,
        } = params;

        let pool = this.#config.getPool(poolKey);
        let quoteCoinId = this.#config.getCoin(quoteKey).coinId;
        let deepCoinId = this.#config.getCoin("DEEP").coinId
        const quoteScalar = pool.quoteCoin.scalar;

        let quoteCoin;
        if (pool.quoteCoin.key === "SUI") {
            [quoteCoin] = txb.splitCoins(
                txb.gas,
                [txb.pure.u64(quoteAmount * quoteScalar)]
            );
        } else {
            [quoteCoin] = txb.splitCoins(
                txb.object(quoteCoinId),
                [txb.pure.u64(quoteAmount * quoteScalar)]
            );
        }
        if (!deepCoin) {
            var [deepCoinInput] = txb.splitCoins(
                txb.object(deepCoinId),
                [txb.pure.u64(deepAmount * DEEP_SCALAR)]
            );
            return swapExactQuoteForBase(pool, quoteCoin, deepCoinInput, txb);
        }

        return swapExactQuoteForBase(pool, quoteCoin, deepCoin, txb);
    }

    async addDeepPricePoint(
        targetPoolKey: string,
        referencePoolKey: string,
    ) {
        let targetPool = this.#config.getPool(targetPoolKey);
        let referencePool = this.#config.getPool(referencePoolKey);
        let txb = new TransactionBlock();
        addDeepPricePoint(targetPool, referencePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async claimRebates(
        poolKey: string,
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
        poolKey: string,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        burnDeep(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async midPrice(
        poolKey: string,
    ): Promise<number> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        return await midPrice(pool, txb);
    }

    async whitelisted(
        poolKey: string,
    ): Promise<boolean> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        return await whitelisted(pool, txb);
    }

    async getQuoteQuantityOut(
        poolKey: string,
        baseQuantity: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        await getQuoteQuantityOut(pool, baseQuantity, txb);
    }

    async getBaseQuantityOut(
        poolKey: string,
        quoteQuantity: number
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        await getBaseQuantityOut(pool, quoteQuantity, txb);
    }

    async accountOpenOrders(
        poolKey: string,
        managerKey: string
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        await accountOpenOrders(pool, managerKey, txb);
    }

    async getLevel2Range(
        poolKey: string,
        priceLow: number,
        priceHigh: number,
        isBid: boolean,
    ): Promise<string[][]> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        return getLevel2Range(pool, priceLow, priceHigh, isBid, txb);
    }

    async getLevel2TicksFromMid(
        poolKey: string,
        ticks: number,
    ): Promise<string[][]> {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();

        return getLevel2TicksFromMid(pool, ticks, txb);
    }

    async vaultBalances(
        poolKey: string,
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
        let deepCoinId = this.#config.getCoin(DEEP_KEY).coinId;
        createPoolAdmin(baseCoin, quoteCoin, deepCoinId, tickSize, lotSize, minSize, whitelisted, stablePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unregisterPoolAdmin(
        poolKey: string,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        unregisterPoolAdmin(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async updateDisabledVersions(
        poolKey: string,
    ) {
        let pool = this.#config.getPool(poolKey);
        let txb = new TransactionBlock();
        updateDisabledVersions(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async stake(
        poolKey: string,
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
        poolKey: string,
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
        poolKey: string,
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

    // await client.cancelAllOrders("DEEP_SUI", "MANAGER_1");
    // await client.unregisterPoolAdmin("SUI_DBUSDC");
    // await client.depositIntoManager("MANAGER_1", 1000, "DEEP");
    // await client.withdrawAllFromManager("MANAGER_1", "DEEP");
    // await client.vaultBalances("DEEP_SUI");
    // await client.createPoolAdmin({
    //     baseCoinKey: "SUI",
    //     quoteCoinKey: "DBUSDC",
    //     tickSize: 0.001,
    //     lotSize: 0.001,
    //     minSize: 0.01,
    //     whitelisted: false,
    //     stablePool: false,
    // });
    // await client.addDeepPricePoint("SUI_DBUSDC", "DEEP_SUI");
    // await client.checkManagerBalance("MANAGER_1", "DEEP");
    // await client.placeLimitOrder({
    //     poolKey: "DEEP_SUI",
    //     managerKey: 'MANAGER_1',
    //     clientOrderId: 888,
    //     price: 3,
    //     quantity: 50,
    //     isBid: false,
    // })
    // await client.placeMarketOrder({
    //     poolKey: "DBWETH_DBUSDC",
    //     managerKey: 'MANAGER_1',
    //     clientOrderId: 888,
    //     quantity: 1,
    //     isBid: true,
    // })
    // await client.submitProposal({
    //     poolKey: "DBWETH_DBUSDC",
    //     managerKey: 'MANAGER_1',
    //     takerFee: 0.003,
    //     makerFee: 0.002,
    //     stakeRequired: 1000,
    // });
    // const txb = new TransactionBlock();
    // const [baseOut, quoteOut, deepOut] = await client.swapExactQuoteForBase({
    //     poolKey: "SUI_DBUSDC",
    //     coinKey: "DBUSDC",
    //     amount: 1,
    //     deepAmount: 10,
    // }, txb);
    // txb.transferObjects([baseOut, quoteOut, deepOut], client.getActiveAddress());
    // await client.signTransaction(txb);
    // await client.swapExactBaseForQuote({
    //     poolKey: "DBWETH_DBUSDC",
    //     coinKey: "DBWETH",
    //     amount: 1000,
    //     deepAmount: 500,
    // }, txb);
}

// testClient();
