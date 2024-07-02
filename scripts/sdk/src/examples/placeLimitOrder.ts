import { TransactionBlock } from "@mysten/sui.js/dist/cjs/transactions";
import { DeepBookClient } from "../client"
import dotenv from 'dotenv';
import { depositIntoManager } from "../balanceManager";
import { placeLimitOrder } from "../deepbook";
import { getSignerFromPK } from "../utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/dist/cjs/client";
import { Constants } from "../coinConstants";

dotenv.config();

// Example of creating a client, initializing all variables, and placing a sell order of 1 DEEP for 1 SUI
// The DEEP/USDC pool has no trading fees. This simple example does not worry about it.
export const placeLimitOrderClient = async () => {
    const pk = process.env.PRIVATE_KEY as string;

    const dbClient = new DeepBookClient("testnet", pk);

    // optional: merge coins into one object if needed
    // const deepType = dbClient.getDeepType();
    // const gasId = await dbClient.getFirstSuiCoinId();
    // await dbClient.mergeUntilComplete(deepType, gasId);

    // initialize coins, the client will fetch the whitelisted coins and set their object ID.
    await dbClient.initCoins();

    // client already comes with DEEP/SUI pool, but can use addPool() to add it to the client
    // Deposit DEEP into the balance manager. 
    let deepAddress = dbClient.getDeepAddress();
    // This will split 1 DEEP (1000000) from the deep object ID that was set in initCoins()
    // and deposit it into the balance manager.
    let balanceManagerKey = "MANAGER_1";
    await dbClient.depositIntoManager(balanceManagerKey, 1, deepAddress);

    // This will place a sell order of 1 DEEP at 1 SUI/DEEP price.
    let deepdbusdcPoolAddress = dbClient.getDeepDbUSDCPoolAddress();

    await dbClient.placeLimitOrder(
        deepdbusdcPoolAddress,
        balanceManagerKey, // balanceManagerKey
        12345, // clientOrderId
        1, // quantity
        1, // price
        false, // isBid = false
        // orderType is default: no restriction
        // self matching is default: allow self matching
        // payWithDeep is default: true
    )
}

// Here, instead of using multiple function calls that the client provides, we will construct a 
// custom PTB to do all of the above in one single transaction.
export const placeLimitOrderPTB = async () => {
    const pk = process.env.PRIVATE_KEY as string;
    const balanceManagerKey = "MANAGER_1";
    const dbClient = new DeepBookClient("testnet", pk);
    await dbClient.initCoins();

    let txb = new TransactionBlock();
    let deepAddress = dbClient.getDeepAddress();
    let deepdbusdcPoolAddress = dbClient.getDeepDbUSDCPoolAddress();
    let expirationTime = Constants.LARGE_TIMESTAMP;
    let deepCoin = dbClient.getCoin(deepAddress);
    let deepdbusdcPool = dbClient.getPool(deepdbusdcPoolAddress);

    depositIntoManager(balanceManagerKey, 1, deepCoin, txb);
    // explicitely set order type, self matching, and payWithDeep
    placeLimitOrder(deepdbusdcPool, balanceManagerKey, 12345, 1, 1, false, expirationTime, 0, 0, true, txb);

    // build signer and send transcation via SuiClient
    // let signer = getSignerFromPK(pk);
    // let suiClient = new SuiClient({ url: getFullnodeUrl("testnet") });
    // let res = await suiClient.signAndExecuteTransactionBlock({
    //     transactionBlock: txb,
    //     signer,
    //     options: {
    //         showEffects: true,
    //         showObjectChanges: true
    //     }
    // });
    // console.log(res, { depth: null });

    // OR
    // use the client's signAndExecute method
    await dbClient.signAndExecute(txb);
}

placeLimitOrderClient()