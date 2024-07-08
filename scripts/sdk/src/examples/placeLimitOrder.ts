import { TransactionBlock } from "@mysten/sui.js/transactions";
import { DeepBookClient } from "../client"
import dotenv from 'dotenv';
import { depositIntoManager } from "../balanceManager";
import { placeLimitOrder } from "../deepbook";
import { CoinKey, LARGE_TIMESTAMP, PoolKey } from "../config";

dotenv.config();

// Example of creating a client, initializing all variables, and placing a sell order of 1 DEEP for 1 SUI
// The DEEP/USDC pool has no trading fees. This simple example does not worry about it.
export const placeLimitOrderClient = async () => {
    const pk = process.env.PRIVATE_KEY as string;

    const dbClient = new DeepBookClient("testnet", pk);
    const managerKey = "MANAGER_1";
    const managerId = "0x0c34e41694c5347c7a45978d161b5d6b543bec80702fee6e002118f333dbdfaf";

    // Initialize the client. If true, then it will merge the client's whitelisted
    // coins in your address into one object.
    await dbClient.init(true);
    dbClient.addBalanceManager(
        managerKey,
        managerId,
    );

    // This will split 1 DEEP (1000000) from the deep object ID that was set in init()
    // and deposit it into the balance manager.
    await dbClient.depositIntoManager(managerKey, 1, CoinKey.DEEP);

    await dbClient.placeLimitOrder(
        PoolKey.DEEP_SUI,
        managerKey, // balanceManagerKey
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
    const managerKey = "MANAGER_1";
    const managerId = "0x0c34e41694c5347c7a45978d161b5d6b543bec80702fee6e002118f333dbdfaf";
    const dbClient = new DeepBookClient("testnet", pk);
    await dbClient.init(true);
    dbClient.addBalanceManager(
        managerKey,
        managerId,
    )
    const balanceManager = dbClient.getBalanceManager(managerKey);

    let txb = new TransactionBlock();

    const deepCoin = dbClient.getConfig().getCoin(CoinKey.DEEP);
    const deepSuiPool = dbClient.getConfig().getPool(PoolKey.DEEP_SUI);

    depositIntoManager(balanceManager.address, 1, deepCoin, txb);
    // explicitely set order type, self matching, and payWithDeep
    placeLimitOrder(deepSuiPool, balanceManager, 12345, 1, 1, false, LARGE_TIMESTAMP, 0, 0, true, txb);

    await dbClient.signAndExecute(txb);
}

placeLimitOrderClient()
