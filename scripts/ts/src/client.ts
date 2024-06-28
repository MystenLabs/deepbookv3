import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { Secp256k1Keypair } from '@mysten/sui.js/keypairs/secp256k1';
import { Secp256r1Keypair } from '@mysten/sui.js/keypairs/secp256r1';
import { checkManagerBalance, createAndShareBalanceManager, depositIntoManager, withdrawAllFromManager, withdrawFromManager } from "./balanceManager";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getSigner, getSignerFromPK, signAndExecuteWithClientAndSigner, validateAddressThrow } from "./utils";
import { normalizeSuiAddress } from "@mysten/sui.js/utils";
import { Coin, Coins, Pool, Pools } from "./coinConstants";
import { bcs } from "@mysten/sui.js/bcs";

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
        if (!this.#coins[baseCoinAddress]) {
            throw new Error("Base coin address not recognized, add it to the client first");
        }
        if (!this.#coins[quoteCoinAddress]) {
            throw new Error("Quote coin address not recognized, add it to the client first");
        }
        this.#pools[poolName] = {
            address: poolAddress,
            baseCoin: this.#coins[baseCoinAddress],
            quoteCoin: this.#coins[quoteCoinAddress]
        };
    }

    getPools() {
        return this.#pools;
    }

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
        if (!this.#coins[coinAddress]) {
            throw new Error("Coin address not recognized, add it to the client first");
        }
        let txb = new TransactionBlock();
        let coin = this.#coins[coinAddress];
        depositIntoManager(this.#balanceManager, amountToDeposit, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawFromManager(amountToWithdraw: number, coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");
        if (!this.#coins[coinAddress]) {
            throw new Error("Coin address not recognized, add it to the client first");
        }
        let txb = new TransactionBlock();
        let coin = this.#coins[coinAddress];
        withdrawFromManager(this.#balanceManager, amountToWithdraw, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async withdrawAllFromManager(coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");
        if (!this.#coins[coinAddress]) {
            throw new Error("Coin address not recognized, add it to the client first");
        }
        let txb = new TransactionBlock();
        let coin = this.#coins[coinAddress];
        withdrawAllFromManager(this.#balanceManager, coin, txb);
        let res = await signAndExecuteWithClientAndSigner(txb, this.#client, this.#signer);
        console.dir(res, { depth: null });
    }

    async checkManagerBalance(coinAddress: string) {
        validateAddressThrow(coinAddress, "coin address");
        if (!this.#coins[coinAddress]) {
            throw new Error("Coin address not recognized, add it to the client first");
        }
        let txb = new TransactionBlock();
        let coin = this.#coins[coinAddress];
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
}