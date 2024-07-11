import { TransactionBlock } from "@mysten/sui.js/transactions";
import { Pool } from "../utils/interfaces";
import { DEEPBOOK_PACKAGE_ID } from "../utils/config";

export const borrowBaseAsset =  (
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
    return [baseCoin, flashLoan];
}

export const returnBaseAsset = (
    pool: Pool,
    baseCoin: any,
    flashLoan: any,
    txb: TransactionBlock,
) => {
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

export const borrowQuoteAsset = (
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
    return [quoteCoin, flashLoan];
}

export const returnQuoteAsset = (
    pool: Pool,
    quoteCoin: any,
    flashLoan: any,
    txb: TransactionBlock,
) => {
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
