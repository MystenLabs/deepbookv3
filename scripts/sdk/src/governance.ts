import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, DEEPBOOK_PACKAGE_ID, MANAGER_ADDRESSES
} from './coinConstants';
import { generateProof } from "./balanceManager";
import { DEEP_SCALAR, FLOAT_SCALAR, Pool } from "./config";

// =================================================================
// Transactions
// =================================================================

export const stake = (
    pool: Pool,
    balanceManagerKey: string,
    stakeAmount: number,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManagerKey, txb);
    const managerAddress = MANAGER_ADDRESSES[balanceManagerKey].address;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::stake`,
        arguments: [
            txb.object(pool.address),
            txb.object(managerAddress),
            tradeProof,
            txb.pure.u64(stakeAmount * DEEP_SCALAR),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const unstake = (
    pool: Pool,
    balanceManagerKey: string,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManagerKey, txb);
    const managerAddress = MANAGER_ADDRESSES[balanceManagerKey].address;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unstake`,
        arguments: [
            txb.object(pool.address),
            txb.object(managerAddress),
            tradeProof,
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const submitProposal = (
    pool: Pool,
    balanceManagerKey: string,
    takerFee: number,
    makerFee: number,
    stakeRequired: number,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManagerKey, txb);
    const managerAddress = MANAGER_ADDRESSES[balanceManagerKey].address;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::submit_proposal`,
        arguments: [
            txb.object(pool.address),
            txb.object(managerAddress),
            tradeProof,
            txb.pure.u64(takerFee * FLOAT_SCALAR),
            txb.pure.u64(makerFee * FLOAT_SCALAR),
            txb.pure.u64(stakeRequired * DEEP_SCALAR),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const vote = (
    pool: Pool,
    balanceManagerKey: string,
    proposal_id: string,
    txb: TransactionBlock,
) => {
    const tradeProof = generateProof(balanceManagerKey, txb);
    const managerAddress = MANAGER_ADDRESSES[balanceManagerKey].address;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::vote`,
        arguments: [
            txb.object(pool.address),
            txb.object(managerAddress),
            tradeProof,
            txb.pure.id(proposal_id),
        ],
    });
}
