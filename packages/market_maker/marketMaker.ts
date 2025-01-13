// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { DeepBookClient } from "@mysten/deepbook-v3";
import { BalanceManager } from "@mysten/deepbook-v3";
import { getFullnodeUrl } from "@mysten/sui/client";
import { SuiClient } from "@mysten/sui/client";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import { Keypair } from "@mysten/sui/cryptography";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import dotenv from 'dotenv';
dotenv.config();

export class MarketMaker {
    client: DeepBookClient;
    keypair: Keypair;
    constructor() {
        // Pull from env
        const env = "mainnet";
        const pk = process.env.PRIVATE_KEY!;
        const keypair = this.getSignerFromPK(pk);

        const balanceManagerAddress = process.env.BALANCE_MANAGER!;

        const balanceManager: BalanceManager = {
            address: balanceManagerAddress,
            tradeCap: undefined
        }

        const client = new DeepBookClient({
            address: keypair.toSuiAddress(),
            env: env,
            client: new SuiClient({
            url: getFullnodeUrl(env),
            }),
            balanceManagers: {"MANAGER_1" : balanceManager},
        })

        this.keypair = keypair;
        this.client = client;
    }

    printBook = async (poolKey: string) => {
        const book = await this.client.getLevel2TicksFromMid(poolKey, 10);

        console.log(poolKey);
        for (let i = book.ask_prices.length - 1; i >= 0; i--) {
            console.log(`${book.ask_prices[i]},\t${book.ask_quantities[i]}`);
        }
        console.log("Price\tQuantity");
        for (let i = 0; i < book.bid_prices.length; i++) {
            console.log(`${book.bid_prices[i]},\t${book.bid_quantities[i]}`);
        }
    }

    midPrice = async (poolKey: string): Promise<number> => {
        const mid = await this.client.midPrice(poolKey);
        console.log(mid);

        return mid;
    }

    burnDeep = async (tx: Transaction, poolKey: string) => {
        console.log(`Burning DEEP from pool ${poolKey}`);
        tx.add(
            this.client.deepBook.burnDeep(poolKey)
        );
    }

    placeOrdersAroundMid = async (tx: Transaction, poolKey: string, ticks: number, quantity: number, midPrice: number) => {
        console.log(`Canceling all orders on pool ${poolKey}`);
        tx.add(
            this.client.deepBook.cancelAllOrders(poolKey, "MANAGER_1"),
        );
        
        console.log(`Placing orders for pool ${poolKey} around mid price ${midPrice}`);

        for (let i = 1; i <= ticks; i++) {
            let buyPrice;
            let sellPrice;
            // first orders tight around mid
            if (i == 1) {
                buyPrice = (Math.round(midPrice * 1000000) - (i * 1000))/1000000;
                sellPrice = (Math.round(midPrice * 1000000) + (i * 1000))/1000000;
            } else {
                buyPrice = (Math.round(midPrice * 1000000) - (i * 20000))/1000000;
                sellPrice = (Math.round(midPrice * 1000000) + (i * 20000))/1000000;
            }
            console.log(buyPrice);
            console.log(sellPrice);
            tx.add(
                this.client.deepBook.placeLimitOrder({
                    poolKey: poolKey,
                    balanceManagerKey: "MANAGER_1",
                    clientOrderId: `${i}`,
                    price: buyPrice,
                    quantity: quantity,
                    isBid: true,
                }),
            );
            tx.add(
                this.client.deepBook.placeLimitOrder({
                    poolKey: poolKey,
                    balanceManagerKey: "MANAGER_1",
                    clientOrderId: `${i}`,
                    price: sellPrice,
                    quantity: quantity,
                    isBid: false,
                }),
            );
        }
    }

    borrowAndReturnFlashloan = async (tx: Transaction, poolKey: string, borrowAmount: number) => {
        console.log(`Borrowing ${borrowAmount} from pool ${poolKey}`);
        const [deepCoin, flashloan] = tx.add(
            this.client.flashLoans.borrowBaseAsset(poolKey, borrowAmount),
        );

        console.log(`Returning ${borrowAmount} to pool ${poolKey}`);
        const loanRemain = tx.add(
            this.client.flashLoans.returnBaseAsset("DEEP_SUI", borrowAmount, deepCoin, flashloan),
        );
        tx.transferObjects([loanRemain], "0x1b71380623813c8aee2ab9a68d96c19d0e45fc872e8c22dd70dfedfb76cbb192")
    }

    stake = (tx: Transaction, poolKey: string, amount: number) => {
        console.log(`Staking ${amount} into pool ${poolKey}`);
        tx.add(
            this.client.governance.stake(poolKey, "MANAGER_1", amount),
        );
    }

    unstake = (tx: Transaction, poolKey: string) => {
        console.log(`Unstaking from pool ${poolKey}`);
        tx.add(
            this.client.governance.unstake(poolKey, "MANAGER_1"),
        );
    }

    placeOrder = async (tx: Transaction, poolKey: string, price: number, quantity: number, isBid: boolean) => {
        tx.add(
            this.client.deepBook.placeLimitOrder({
                poolKey: poolKey,
                balanceManagerKey: "MANAGER_1",
                clientOrderId: "1",
                price: price,
                quantity: quantity,
                isBid: isBid,
            }),
        );
    }

    checkBalances = async () => {
        const deep = await this.client.checkManagerBalance("MANAGER_1", "DEEP");
        const sui = await this.client.checkManagerBalance("MANAGER_1", "SUI");
        const dbusdc = await this.client.checkManagerBalance("MANAGER_1", "DBUSDC");
        const dbusdt = await this.client.checkManagerBalance("MANAGER_1", "DBUSDT");

        console.log("DEEP: ", deep);
        console.log("SUI: ", sui);
        console.log("DBUSDC: ", dbusdc);
        console.log("DBUSDT: ", dbusdt);
    }

    depositCoins = async (
        sui: number,
        deep: number,
        dbusdc: number,
        dbusdt: number,
    ) => {
        const tx = new Transaction();
        tx.add(
            this.client.balanceManager.depositIntoManager("MANAGER_1", "DEEP", deep),
        );
        tx.add(
            this.client.balanceManager.depositIntoManager("MANAGER_1", "SUI", sui),
        );
        tx.add(
            this.client.balanceManager.depositIntoManager("MANAGER_1", "DBUSDC", dbusdc),
        );
        tx.add(
            this.client.balanceManager.depositIntoManager("MANAGER_1", "DBUSDT", dbusdt),
        );

        return this.signAndExecute(tx);
    }

    withdrawCoins = async () => {
        const tx = new Transaction();
        tx.add(
            this.client.balanceManager.withdrawAllFromManager("MANAGER_1", "DEEP", this.keypair.toSuiAddress()),
        );
        tx.add(
            this.client.balanceManager.withdrawAllFromManager("MANAGER_1", "SUI", this.keypair.toSuiAddress()),
        );
        tx.add(
            this.client.balanceManager.withdrawAllFromManager("MANAGER_1", "DBUSDC", this.keypair.toSuiAddress()),
        );
        tx.add(
            this.client.balanceManager.withdrawAllFromManager("MANAGER_1", "DBUSDT", this.keypair.toSuiAddress()),
        );

        return this.signAndExecute(tx);
    }

    createAndShareBM = async () => {
        const tx = new Transaction();
        tx.add(
            this.client.balanceManager.createAndShareBalanceManager(),
        );
        return this.signAndExecute(tx);
    }

    getSignerFromPK = (privateKey: string) => {
        const { schema, secretKey } = decodeSuiPrivateKey(privateKey);
        if (schema === "ED25519") return Ed25519Keypair.fromSecretKey(secretKey);

        throw new Error(`Unsupported schema: ${schema}`);
    };

    signAndExecute = async (tx: Transaction) => {
        tx.setGasBudget(500000000);
        return this.client.client.signAndExecuteTransaction({
            transaction: tx,
            signer: this.keypair,
            options: {
                showEffects: true,
                showObjectChanges: true,
            },
        });
    };
}
