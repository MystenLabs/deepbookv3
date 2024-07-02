import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui.js/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui.js/keypairs/secp256r1';
import { checkManagerBalance, createAndShareBalanceManager, depositIntoManager, withdrawAllFromManager, withdrawFromManager } from "./balanceManager";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getSigner, getSignerFromPK, signAndExecuteWithClientAndSigner, validateAddressThrow } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { Coin, Coins, OrderType, Pool, Pools, SelfMatchingOptions } from "./coinConstants";
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
    #balanceManager: string;
    #coins: { [key: string]: Coin } = {};
    #pools: { [key: string]: Pool } = {};

    constructor(
        network: "mainnet" | "testnet" | "devnet" | "localnet",
        privateKey?: string,
        balanceManager?: string
    ) {
        this.#client = new SuiClient({ url: getFullnodeUrl(network) });
        if (!privateKey) {
            this.#signer = getSigner();
        } else {
            this.#signer = getSignerFromPK(privateKey);
        }
        if (!balanceManager) {
            this.#balanceManager = "";
        } else {
            validateAddressThrow(balanceManager, "balance manager");
            this.#balanceManager = balanceManager;
        }
        this.initCoins();
        this.initPools();
    }

    initCoins() {
        this.#coins[Coins.ASLAN.address] = Coins.ASLAN;
        this.#coins[Coins.TONY.address] = Coins.TONY;
        this.#coins[Coins.DEEP.address] = Coins.DEEP;
        this.#coins[Coins.SUI.address] = Coins.SUI;
    }

    addCoin(
        address: string,
        type: string,
        decimals: number,
        coinId: string
    ) {
        validateAddressThrow(address, "coin address");
        this.#coins[type] = {
            address: address,
            type: type,
            scalar: Math.pow(10, decimals),
            coinId: coinId
        };
    }

    getCoins() {
        return this.#coins;
    }

    initPools() {
        this.#pools[Pools.TONY_SUI_POOL.address] = Pools.TONY_SUI_POOL;
        this.#pools[Pools.DEEP_SUI_POOL.address] = Pools.DEEP_SUI_POOL;
    }

    addPool(
        poolName: string,
        poolAddress: string,
        baseCoinAddress: string,
        quoteCoinAddress: string,
    ) {
        validateAddressThrow(poolAddress, "pool address");
        let baseCoin = this.getCoin(baseCoinAddress);
        let quoteCoin = this.getCoin(quoteCoinAddress);

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
    setBalanceManager(balanceManager: string) {
        validateAddressThrow(balanceManager, "balance manager");
        this.#balanceManager = balanceManager;
    }

    async createAndShareBalanceManager() {
        let txb = new TransactionBlock();
        createAndShareBalanceManager(txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async depositIntoManager(amountToDeposit: number, coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");

        let txb = new TransactionBlock();
        let coin = this.getCoin(coinAddress);
        depositIntoManager(this.#balanceManager, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(amountToWithdraw: number, coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");

        let txb = new TransactionBlock();
        let coin = this.getCoin(coinAddress);
        withdrawFromManager(this.#balanceManager, amountToWithdraw, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");

        let txb = new TransactionBlock();
        let coin = this.getCoin(coinAddress);
        withdrawAllFromManager(this.#balanceManager, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");

        let txb = new TransactionBlock();
        let coin = this.getCoin(coinAddress);
        checkManagerBalance(this.#balanceManager, coin, txb);
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
        poolAddress: string,
        clientOrderId: number,
        price: number,
        quantity: number,
        isBid: boolean,
        orderType?: OrderType,
        selfMatchingOption?: SelfMatchingOptions,
        payWithDeep?: boolean,
    ) {
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
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        placeLimitOrder(pool, this.#balanceManager, clientOrderId, price, quantity, isBid, orderType, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async placeMarketOrder(
        poolAddress: string,
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
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        placeMarketOrder(pool, this.#balanceManager, clientOrderId, quantity, isBid, selfMatchingOption, payWithDeep, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelOrder(
        poolAddress: string,
        clientOrderId: number,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        cancelOrder(pool, this.#balanceManager, clientOrderId, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async cancelAllOrders(
        poolAddress: string,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        cancelAllOrders(pool, this.#balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactBaseForQuote(
        poolAddress: string,
        baseAmount: number,
        deepAmount: number,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        swapExactBaseForQuote(pool, baseAmount, deepAmount, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async swapExactQuoteForBase(
        poolAddress: string,
        quoteAmount: number,
        deepAmount: number,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        swapExactQuoteForBase(pool, quoteAmount, deepAmount, txb);

        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async addDeepPricePoint(
        targetPoolAddress: string,
        referencePoolAddress: string,
    ) {
        let targetPool = this.getPool(targetPoolAddress);
        let referencePool = this.getPool(referencePoolAddress);
        let txb = new TransactionBlock();
        addDeepPricePoint(targetPool, referencePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async claimRebates(
        poolAddress: string,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        claimRebates(pool, this.#balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async burnDeep(
        poolAddress: string,
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        burnDeep(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async midPrice(
        poolAddress: string,
    ): Promise<number> {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        return await midPrice(pool, txb);
    }

    async whitelisted(
        poolAddress: string
    ): Promise<boolean> {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        return await whiteListed(pool, txb);
    }

    async getQuoteQuantityOut(
        poolAddress: string,
        baseQuantity: number
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        await getQuoteQuantityOut(pool, baseQuantity, txb);
    }

    async getBaseQuantityOut(
        poolAddress: string,
        quoteQuantity: number
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        await getBaseQuantityOut(pool, quoteQuantity, txb);
    }

    async accountOpenOrders(
        poolAddress: string,
    ) {
        this.validateBalanceManager();

        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        await accountOpenOrders(pool, this.#balanceManager, txb);
    }

    async getLevel2Range(
        poolAddress: string,
        priceLow: number,
        priceHigh: number,
        isBid: boolean,
    ): Promise<string[][]> {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        return getLevel2Range(pool, priceLow, priceHigh, isBid, txb);
    }

    async getLevel2TicksFromMid(
        poolAddress: string,
        ticks: number,
    ): Promise<string[][]> {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();

        return getLevel2TicksFromMid(pool, ticks, txb);
    }

    async vaultBalances(
        poolAddress: string,
    ): Promise<number[]> {
        let pool = this.getPool(poolAddress);
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
        baseCoinAddress: string,
        quoteCoinAddress: string,
        tickSize: number,
        lotSize: number,
        minSize: number,
        whitelisted: boolean,
        stablePool: boolean,
    ) {
        let txb = new TransactionBlock();
        let baseCoin = this.getCoin(baseCoinAddress);
        let quoteCoin = this.getCoin(quoteCoinAddress);
        createPoolAdmin(baseCoin, quoteCoin, tickSize, lotSize, minSize, whitelisted, stablePool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unregisterPoolAdmin(
        poolAddress: string,
    ) {
        let pool = this.getPool(poolAddress)
        let txb = new TransactionBlock();
        unregisterPoolAdmin(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async updateDisabledVersions(
        poolAddress: string,
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        updateDisabledVersions(pool, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async stake(
        poolAddress: string,
        amount: number
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        stake(pool, this.#balanceManager, amount, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async unstake(
        poolAddress: string
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        unstake(pool, this.#balanceManager, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async submitProposal(
        poolAddress: string,
        takerFee: number,
        makerFee: number,
        stakeRequired: number,
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        submitProposal(pool, this.#balanceManager, takerFee, makerFee, stakeRequired, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async vote(
        poolAddress: string,
        proposal_id: string
    ) {
        let pool = this.getPool(poolAddress);
        let txb = new TransactionBlock();
        vote(pool, this.#balanceManager, proposal_id, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    getCoin(coinAddress: string) {
        if (!this.#coins[coinAddress]) {
            throw new Error(`Coin address ${coinAddress} not recognized, add it to the client first.`);
        }
        return this.#coins[coinAddress];
    }

    getPool(poolAddress: string) {
        if (!this.#pools[poolAddress]) {
            throw new Error(`Pool address ${poolAddress} not recognized, add it to the client first.`);
        }
        return this.#pools[poolAddress];
    }

    validateBalanceManager() {
        if (this.#balanceManager === "") {
            throw new Error("Balance manager not set, set it first.");
        }
    }
}
