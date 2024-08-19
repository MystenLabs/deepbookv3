// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
import { DeepBookClient } from "@mysten/deepbook-v3";
import { BalanceManager } from "@mysten/deepbook-v3";
import { getFullnodeUrl, SuiClient } from "@mysten/sui/client";
import { decodeSuiPrivateKey } from "@mysten/sui/cryptography";
import type { Keypair } from "@mysten/sui/cryptography";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import dotenv from 'dotenv';
dotenv.config();

// import { DeepBookClient } from "@mysten/deepbook-v3"; // Adjust path according to new structure
// import type { BalanceManager } from "../src/types/index.js";

// export class DeepBookMarketMaker extends DeepBookClient {
//   keypair: Keypair;
//   suiClient: SuiClient;

//   constructor(
//     keypair: string | Keypair,
//     env: "testnet" | "mainnet",
//     balanceManagers?: { [key: string]: BalanceManager },
//     adminCap?: string,
//   ) {
//     let resolvedKeypair: Keypair;

//     if (typeof keypair === "string") {
//       resolvedKeypair = DeepBookMarketMaker.#getSignerFromPK(keypair);
//     } else {
//       resolvedKeypair = keypair;
//     }

//     const address = resolvedKeypair.toSuiAddress();

//     super({
//       address: address,
//       env: env,
//       client: new SuiClient({
//         url: getFullnodeUrl(env),
//       }),
//       balanceManagers: balanceManagers,
//       adminCap: adminCap,
//     });

//     this.keypair = resolvedKeypair;
//     this.suiClient = new SuiClient({
//       url: getFullnodeUrl(env),
//     });
//   }

//   static #getSignerFromPK = (privateKey: string) => {
//     const { schema, secretKey } = decodeSuiPrivateKey(privateKey);
//     if (schema === "ED25519") return Ed25519Keypair.fromSecretKey(secretKey);

//     throw new Error(`Unsupported schema: ${schema}`);
//   };

//   signAndExecute = async (tx: Transaction) => {
//     return this.suiClient.signAndExecuteTransaction({
//       transaction: tx,
//       signer: this.keypair,
//       options: {
//         showEffects: true,
//         showObjectChanges: true,
//       },
//     });
//   };

//   getActiveAddress() {
//     return this.keypair.getPublicKey().toSuiAddress();
//   }

//   // Example of a flash loan transaction
//   // Borrow 1 DEEP from DEEP_SUI pool
//   // Swap 0.5 DBUSDC for SUI in SUI_DBUSDC pool, pay with deep borrowed
//   // Swap SUI back to DEEP
//   // Return 1 DEEP to DEEP_SUI pool
//   flashLoanExample = async (tx: Transaction) => {
//     const borrowAmount = 1;
//     const [deepCoin, flashLoan] = tx.add(
//       this.flashLoans.borrowBaseAsset("DEEP_SUI", borrowAmount),
//     );

//     // Execute trade using borrowed DEEP
//     const [baseOut, quoteOut, deepOut] = tx.add(
//       this.deepBook.swapExactQuoteForBase({
//         poolKey: "SUI_DBUSDC",
//         amount: 0.5,
//         deepAmount: 1,
//         minOut: 0,
//         deepCoin: deepCoin,
//       }),
//     );

//     tx.transferObjects([baseOut, quoteOut, deepOut], this.getActiveAddress());

//     // Execute second trade to get back DEEP for repayment
//     const [baseOut2, quoteOut2, deepOut2] = tx.add(
//       this.deepBook.swapExactQuoteForBase({
//         poolKey: "DEEP_SUI",
//         amount: 10,
//         deepAmount: 0,
//         minOut: 0,
//       }),
//     );

//     tx.transferObjects([quoteOut2, deepOut2], this.getActiveAddress());

//     // Return borrowed DEEP
//     const loanRemain = tx.add(
//       this.flashLoans.returnBaseAsset(
//         "DEEP_SUI",
//         borrowAmount,
//         baseOut2,
//         flashLoan,
//       ),
//     );
//     tx.transferObjects([loanRemain], this.getActiveAddress());
//   };

//   placeLimitOrderExample = (tx: Transaction) => {
//     tx.add(
//       this.deepBook.placeLimitOrder({
//         poolKey: "SUI_DBUSDC",
//         balanceManagerKey: "MANAGER_1",
//         clientOrderId: "123456789",
//         price: 1,
//         quantity: 10,
//         isBid: true,
//         // orderType default: no restriction
//         // selfMatchingOption default: allow self matching
//         // payWithDeep default: true
//       }),
//     );
//   };
// }

export class MarketMaker {
    client: DeepBookClient;
    keypair: Keypair;
    constructor() {
        // Pull from env
        const env = "testnet";
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
        let book = await this.client.getLevel2TicksFromMid(poolKey, 10);

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
        let mid = await this.client.midPrice(poolKey);
        console.log(mid);

        return mid;
    }

    placeOrdersAroundMid = async (tx: Transaction, poolKey: string, ticks: number, quantity: number) => {
        let midPrice = await this.client.midPrice(poolKey);
        console.log(`Canceling all orders on pool ${poolKey}`);
        tx.add(
            this.client.deepBook.cancelAllOrders(poolKey, "MANAGER_1"),
        );
        
        console.log(`Placing orders for pool ${poolKey} around mid price ${midPrice}`);

        for (let i = 1; i <= ticks; i++) {
            const buyPrice = (Math.round(midPrice * 1000000) - (i * 15000))/1000000;
            const sellPrice = (Math.round(midPrice * 1000000) + (i * 15000))/1000000;
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


    cancelAndReplaceDEEPSUI = async () => {
        const tx = new Transaction();
        tx.add(
            this.client.deepBook.cancelAllOrders("DEEP_SUI", "MANAGER_1"),
        );
        return this.signAndExecute(tx);
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
        tx.setGasBudget(5000000000);
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
