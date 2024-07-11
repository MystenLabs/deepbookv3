import { TransactionBlock } from "@mysten/sui.js/transactions";
import { DeepBookClient } from "../src/client"
import { Environment } from "../src/utils/interfaces";

import dotenv from 'dotenv';
dotenv.config();

// Initialize and return the DeepBookClient. Optionally merges coins and adds a manager to the client.
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

// Example of creating a client, initializing all variables, and placing a buy order of 1 DEEP for price of 2 SUI
export const placeLimitOrderClient = async () => {
    const client = await init();
    const managerKey = "MANAGER_1";

    const txb = new TransactionBlock();
    await client.depositIntoManager(managerKey, 2, "SUI", txb);
    await client.placeLimitOrder({
        poolKey: "DEEP_SUI",
        managerKey: managerKey,
        clientOrderId: 888,
        price: 2,
        quantity: 1,
        isBid: true,
        // orderType is default: no restriction
        // selfMatchingOption is default: allow self matching
        // payWithDeep is default: true
    }, txb);
}

export const placeLimitOrderBorrowDeep = async () => {
    const client = await init();
    const txb = new TransactionBlock();
    const borrowAmount = 1;
    const [deepCoin, flashLoan] = await client.borrowBaseAsset(
        "DEEP_SUI",
        borrowAmount,
        txb
    )

    // Execute trade using borrowed DEEP
    const [baseOut, quoteOut, deepOut] = await client.swapExactQuoteForBase({
        poolKey: "SUI_DBUSDC",
        amount: 0.5,
        deepAmount: 1,
        deepCoin: deepCoin,
    }, txb);

    txb.transferObjects([baseOut, quoteOut, deepOut], client.getActiveAddress());

    // Execute second trade to get back DEEP for repayment
    const [baseOut2, quoteOut2, deepOut2] = await client.swapExactQuoteForBase({
        poolKey: "DEEP_SUI",
        amount: 35,
        deepAmount: 0,
    }, txb);

    txb.transferObjects([quoteOut2, deepOut2], client.getActiveAddress())

    const loanRemain = await client.returnBaseAsset(
        "DEEP_SUI",
        borrowAmount,
        baseOut2,
        flashLoan,
        txb
    );
    txb.transferObjects([loanRemain], client.getActiveAddress());

    await client.signTransaction(txb);
}

placeLimitOrderBorrowDeep();
