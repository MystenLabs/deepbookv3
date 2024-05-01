
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui.js/utils";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463`;

// =================================================================
// Transactions
// =================================================================

const placeOrder = (
    poolID: string,
    accountID: string,
    proofID: string,
    clientOrderID: number,
    orderType: number,
    price: number,
    quantity: number,
    isBid: boolean,
    expireTimestamp: number,
) => {
    const txb = new TransactionBlock();
    // Result types: [0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::pool::OrderPlaced<Type_0,Type_1>]
    const result = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::deepbook::place_limit_order`,
        arguments: [
            txb.object(poolID), // 0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::pool::Pool<Type_0,Type_1>
            txb.object(accountID), // 0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::account::Account
            txb.object(proofID), // 0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::account::TradeProof
            txb.pure.u64(clientOrderID),
            txb.pure.u8(orderType),
            txb.pure.u64(price),
            txb.pure.u64(quantity),
            txb.pure.bool(isBid),
            txb.pure.u64(expireTimestamp),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: ["Type_0", "Type_1"]
    });
}

const createAccount = () => {
    const txb = new TransactionBlock();
    // Result types: [0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::account::Account]
    const account = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::account::new`,
    });

    txb.transferObjects([account], txb.pure.address(getActiveAddress()));
}

const shareAccount = (
    accountID: string,
) => {
    const txb = new TransactionBlock();
    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::account::share`,
		arguments: [
			txb.object(accountID), // 0xde8bfc352d9c5e2e1ac20499a43368937a0d64c857d42772a0cb7c2c91db3463::account::Account
		],
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // Run against mainnet
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
