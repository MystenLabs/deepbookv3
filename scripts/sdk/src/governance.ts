import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, DEEPBOOK_PACKAGE_ID, Pools, Pool, Constants, Coins
} from './coinConstants';
import { generateProof } from "./balanceManager";

// =================================================================
// Transactions
// =================================================================

export const stake = async (
    pool: Pool,
    balanceManager: string,
    stakeAmount: number,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManager, txb);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::stake`,
        arguments: [
            txb.object(pool.address),
            txb.object(balanceManager),
            tradeProof,
            txb.pure.u64(stakeAmount * Coins.DEEP.scalar),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const unstake = async (
    pool: Pool,
    balanceManager: string,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManager, txb);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unstake`,
        arguments: [
            txb.object(pool.address),
            txb.object(balanceManager),
            tradeProof,
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const submitProposal = async (
    pool: Pool,
    balanceManager: string,
    takerFee: number,
    makerFee: number,
    stakeRequired: number,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManager, txb);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::submit_proposal`,
        arguments: [
            txb.object(pool.address),
            txb.object(balanceManager),
            tradeProof,
            txb.pure.u64(takerFee * Constants.FLOAT_SCALAR),
            txb.pure.u64(makerFee * Constants.FLOAT_SCALAR),
            txb.pure.u64(stakeRequired * Coins.DEEP.scalar),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const vote = async (
    pool: Pool,
    balanceManager: string,
    proposal_id: string,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManager, txb);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::vote`,
        arguments: [
            txb.object(pool.address),
            txb.object(balanceManager),
            tradeProof,
            txb.pure.id(proposal_id),
        ],
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await stake(Pools.TONY_SUI_POOL, 100, txb);
    // await unstake(Pools.DEEP_SUI_POOL, txb);
    // await submitProposal(Pools.TONY_SUI_POOL, 0.0005, 0.0002, 10, txb);
    // await vote(Pools.TONY_SUI_POOL, 'proposal_id', txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
