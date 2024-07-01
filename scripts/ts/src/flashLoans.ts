import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, DEEPBOOK_PACKAGE_ID, Pools, Pool, Constants
} from './coinConstants';

// =================================================================
// Transactions
// =================================================================
export const borrowAndReturnBaseAsset = async (
    pool: Pool,
    borrowAmount: number,
    txb: TransactionBlock,
) => {
    const baseScalar = pool.baseCoin.scalar;
    const [baseCoin, flashLoan] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::borrow_flashloan_base`,
        arguments: [
            txb.object(pool.address),
            txb.pure.u64(borrowAmount * baseScalar),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });

    // Execute other move calls as necessary

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::return_flashloan_base`,
        arguments: [
            txb.object(pool.address),
            baseCoin,
            flashLoan,
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const borrowAndReturnQuoteAsset = async (
    pool: Pool,
    borrowAmount: number,
    txb: TransactionBlock,
) => {
    const quoteScalar = pool.quoteCoin.scalar;
    const [quoteCoin, flashLoan] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::borrow_flashloan_quote`,
        arguments: [
            txb.object(pool.address),
            txb.pure.u64(borrowAmount * quoteScalar),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });

    // Execute other move calls as necessary

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::return_flashloan_quote`,
        arguments: [
            txb.object(pool.address),
            quoteCoin,
            flashLoan,
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

/// Main entry points, comment out as needed...
export const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await borrowAndReturnBaseAsset(Pools.TONY_SUI_POOL, 1, txb);
    // await borrowAndReturnQuoteAsset(Pools.TONY_SUI_POOL, 1, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
