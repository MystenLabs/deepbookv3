
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui.js/utils";
import { SuiClient, SuiObjectData } from "@mysten/sui.js/client";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x693a9c884d8070596c462bb334344b3e4ba40c8d91309e67ddf1c5c9332320cd`;
const REGISTRY_ID = `0xe682d36c515d6f239293e2e27fda83e079355fddf0adf9f680fc801ee5ca2490`;
const ADMINCAP_ID = `0xfe148aab938175502e47fe2c499f178856e6c7ab7ee9e6bb12f14ce36804523f`;
const COIN_OBJECT = `0x06d4517a11724dffa7cada801578db3342cdca57c655688e480b69079ab58089`;
const FLOAT_SCALAR = 1000000000;

// =================================================================
// Transactions
// =================================================================

const createPool = async (
    txb: TransactionBlock
) => {
    // get the base gas coin from the provider
    const { data } = await client.getObject({
        id: COIN_OBJECT
    });
    if (!data) return false;
    // use the gas coin to pay for the gas.
    txb.setGasPayment([data]);

    const [creationFee] = txb.splitCoins(txb.gas, [txb.pure.u64(100 * FLOAT_SCALAR)]);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::create_pool`,
        arguments: [
            txb.object(REGISTRY_ID), // registry_id
            txb.pure.u64(1000), // tick_size
            txb.pure.u64(1000), // lot_size
            txb.pure.u64(10000), // min_size
            creationFee, // 0x2::balance::Balance<0x2::sui::SUI>
        ],
        typeArguments: [
            "0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN",
            "0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN"
        ]
    });
}

/// Places an order in the pool
const placeLimitOrder = (
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

// /// Create an account and transfers it to the active address
// const createAccount = () => {
//     const txb = new TransactionBlock();
//     const account = txb.moveCall({
//         target: `${DEEPBOOK_PACKAGE_ID}::account::new`,
//     });

//     txb.transferObjects([account], txb.pure.address(getActiveAddress()));
// }

// /// Makes an Account object shared
// const shareAccount = (
//     accountID: string,
// ) => {
//     const txb = new TransactionBlock();
//     txb.moveCall({
// 		target: `${DEEPBOOK_PACKAGE_ID}::account::share`,
// 		arguments: [
// 			txb.object(accountID),
// 		],
//     });
// }

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    await createPool(txb);
    // createAccount();
    // shareAccount();
    // placeOrder();

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
