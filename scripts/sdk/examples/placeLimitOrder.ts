import { TransactionBlock } from "@mysten/sui.js/transactions";
import { DeepBookClient } from "../src/client"
import { depositIntoManager } from "../src/transactions/balanceManager";
import { placeLimitOrder } from "../src/transactions/deepbook";
import { MAX_TIMESTAMP } from "../src/utils/config";
import { CoinKey, PoolKey } from "../src/utils/interfaces";
import { Environment } from "../src/utils/interfaces";

import dotenv from 'dotenv';
dotenv.config();

// Initialize and return the DeepBookClient
const init = async (): Promise<DeepBookClient> => {
    const env = process.env.ENV as Environment;
    if (!env || !["mainnet", "testnet", "devnet", "localnet"].includes(env)) {
        throw new Error(`Invalid environment: ${process.env.ENV}`);
    }

    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        throw new Error("PRIVATE_KEY is not defined in the environment variables");
    }

    const client = new DeepBookClient(env, privateKey);
    const mergeCoins = false;
    await client.init(mergeCoins);
    client.addBalanceManager("MANAGER_1", "0x0c34e41694c5347c7a45978d161b5d6b543bec80702fee6e002118f333dbdfaf");

    return client;
}

// Example of creating a client, initializing all variables, and placing a sell order of 1 DEEP for 1 SUI
export const placeLimitOrderClient = async () => {
    const client = await init();
    const managerKey = "MANAGER_1";

    await client.depositIntoManager(managerKey, 1, CoinKey.DEEP);

    await client.placeLimitOrder({
        poolKey: PoolKey.DBWETH_DBUSDC,
        managerKey: managerKey,
        clientOrderId: 888,
        price: 2,
        quantity: 1,
        isBid: true,
    });
}

// Here, instead of using multiple function calls that the client provides, we will construct a
// custom PTB to do all of the above in one single transaction.
export const placeLimitOrderPTB = async () => {
    const client = await init();
    await client.placeLimitOrder({
        poolKey: PoolKey.DEEP_SUI,
        managerKey: 'MANAGER_1',
        clientOrderId: 888,
        price: 1,
        quantity: 10,
        isBid: true,
    });
}

export const placeLimitOrderBorrowDeep = async () => {
    const client = await init();
    const txb = new TransactionBlock();
    const [deepCoin, flashLoan] = await client.borrowBaseAsset(
        PoolKey.DEEP_SUI,
        10,
        txb
    )

    const [baseOut, quoteOut, deepOut] = await client.swapExactQuoteForBase({
        poolKey: PoolKey.SUI_DBUSDC,
        coinKey: CoinKey.DBUSDC,
        amount: 5,
        deepAmount: 10,
        deepCoin: deepCoin,
    }, txb);

    txb.transferObjects([baseOut], client.getActiveAddress());
    txb.transferObjects([quoteOut], client.getActiveAddress())
    txb.transferObjects([deepOut], client.getActiveAddress());

    const [baseOut2, quoteOut2, deepOut2] = await client.swapExactQuoteForBase({
        poolKey: PoolKey.DEEP_SUI,
        coinKey: CoinKey.DBUSDC,
        amount: 5,
        deepAmount: 0,
    }, txb);

    txb.transferObjects([quoteOut2], client.getActiveAddress())
    txb.transferObjects([deepOut2], client.getActiveAddress());

    await client.returnBaseAsset(
        PoolKey.DEEP_SUI,
        10,
        baseOut2,
        flashLoan,
        txb
    );

    // // Get the correct coin IDs
    // const mergeCoins = false;
    // await client.init(mergeCoins);
    await client.signTransaction(txb);
}

// placeLimitOrderBorrowDeep();
