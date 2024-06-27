import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, COIN_SCALARS, DEEPBOOK_PACKAGE_ID, TONY_TYPE, SUI_TYPE, TONY_SUI_POOL_ID
} from './coinConstants';

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

    // Execute other move calls as necessary

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

    // Execute other move calls as necessary

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
