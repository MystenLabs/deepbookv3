import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID, normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";
import {
    COIN_SCALARS, COIN_IDS, ASLAN_TYPE, TONY_TYPE, DEEP_TYPE, SUI_TYPE,
    ENV, DEEPBOOK_PACKAGE_ID, REGISTRY_ID, DEEP_TREASURY_ID,
    DEEP_SUI_POOL_ID, TONY_SUI_POOL_ID, MANAGER_ID, MY_ADDRESS,
    NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY,
    SELF_MATCHING_ALLOWED, CANCEL_TAKER, CANCEL_MAKER
} from './coinConstants';

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// =================================================================
// Transactions
// =================================================================

const borrowAndReturnBaseAsset = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    borrowAmount: number,
    txb: TransactionBlock,
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const [baseCoin, flashLoan] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::borrow_flashloan_base`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(borrowAmount * baseScalar),
        ],
        typeArguments: [baseType, quoteType]
    });

    // Execute other transaction as necessary

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::return_flashloan_base`,
        arguments: [
            txb.object(poolId),
            baseCoin,
            flashLoan,
        ],
        typeArguments: [baseType, quoteType]
    });
}

const borrowAndReturnQuoteAsset = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    borrowAmount: number,
    txb: TransactionBlock,
) => {
    const quoteScalar = COIN_SCALARS[quoteType];
    const [quoteCoin, flashLoan] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::borrow_flashloan_quote`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(borrowAmount * quoteScalar),
        ],
        typeArguments: [baseType, quoteType]
    });

    // Execute other transaction as necessary

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::return_flashloan_quote`,
        arguments: [
            txb.object(poolId),
            quoteCoin,
            flashLoan,
        ],
        typeArguments: [baseType, quoteType]
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();
    // borrowAndReturnBaseAsset(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, txb);
    // borrowAndReturnQuoteAsset(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
