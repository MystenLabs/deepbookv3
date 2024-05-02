
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui.js/utils";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = ``;

// =================================================================
// Transactions
// =================================================================

/// Places an order in the pool
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
    // Result types: [DEEPBOOK_PACKAGE_ID::pool::OrderPlaced<Type_0,Type_1>]
    const result = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::deepbook::place_limit_order`,
        arguments: [
            txb.object(poolID),
            txb.object(accountID),
            txb.object(proofID),
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

/// Create an account and transfers it to the active address
const createAccount = () => {
    const txb = new TransactionBlock();
    const account = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::account::new`,
    });

    txb.transferObjects([account], txb.pure.address(getActiveAddress()));
}

/// Makes an Account object shared
const shareAccount = (
    accountID: string,
) => {
    const txb = new TransactionBlock();
    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::account::share`,
		arguments: [
			txb.object(accountID),
		],
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // Uncomment the transactions you want to execute
    // createAccount();
    // shareAccount();
    // placeOrder();

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
