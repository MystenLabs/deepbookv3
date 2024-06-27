import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, DEEPBOOK_PACKAGE_ID, COIN_SCALARS, TONY_TYPE, DEEP_TYPE, SUI_TYPE,
    DEEP_SUI_POOL_ID, TONY_SUI_POOL_ID, MANAGER_ID
} from './coinConstants';

// =================================================================
// Transactions
// =================================================================

const stake = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    stakeAmount: number,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::stake`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(stakeAmount * COIN_SCALARS[DEEP_TYPE]),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const unstake = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unstake`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const submitProposal = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    takerFee: number,
    makerFee: number,
    stakeRequired: number,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::submit_proposal`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(takerFee * COIN_SCALARS.FLOAT_SCALAR),
            txb.pure.u64(makerFee * COIN_SCALARS.FLOAT_SCALAR),
            txb.pure.u64(stakeRequired * COIN_SCALARS[DEEP_TYPE]),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const vote = async (
    pool_id: string,
    balance_manager_id: string,
    proposal_id: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::vote`,
        arguments: [
            txb.object(pool_id),
            txb.object(balance_manager_id),
            txb.pure.id(proposal_id),
        ],
    });

}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await stake(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 100, txb);
    // await unstake(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, txb);
    // await submitProposal(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 0.0005, 0.0002, 10, txb);
    // await vote(TONY_SUI_POOL_ID, MANAGER_ID, 'proposal_id', txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
