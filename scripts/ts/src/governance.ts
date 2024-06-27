
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID, normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const MY_ADDRESS = getActiveAddress();
const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;
const REGISTRY_ID = `0x14614dfc9243fcb2ef7ac51efed5c6284ca701d55216e1f42b3eb22c541feaa6`;
const DEEP_SUI_POOL_ID = `0x9c29aa70749297fe4fc35403ae743cc8883ad26ba77b9ba214dbff7d5f9a5395`;
const TONY_SUI_POOL_ID = `0x92083a73031ad86c6df401dc4a59b5dfa589db5937a921c2ec72a5629b715154`;

// Create manager and give ID
const MANAGER_ID = `0x08b49d7067383d17cdd695161b247e2f617e0d9095da65edb85900e7b6f82de4`;

// Update to the base and quote types of the pool
const ASLAN_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
const TONY_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;
const DEEP_TYPE = `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`;
const SUI_TYPE = `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`;

const DEEP_SCALAR = 1000000;
const SUI_SCALAR = 1000000000;
const TONY_SCALAR = 1000000;
const FLOAT_SCALAR = 1000000000;
const GAS_BUDGET = 0.5 * SUI_SCALAR; // Update gas budget as needed for order placement

// Trading constants
// Order types
const NO_RESTRICTION = 0;
const IMMEDIATE_OR_CANCEL = 1;
const FILL_OR_KILL = 2;
const POST_ONLY = 3;

// Self matching options
const SELF_MATCHING_ALLOWED = 0;
const CANCEL_TAKER = 1;
const CANCEL_MAKER = 2;

// =================================================================
// Transactions
// =================================================================

const stake = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    quoteType: string,
    stakeAmount: number,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::stake`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(stakeAmount * DEEP_SCALAR),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const unstake = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    quoteType: string,
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
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    quoteType: string,
    takerFee: number,
    makerFee: number,
    stakeRequired: number,
) => {
    // TODO: Test
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::submit_proposal`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(takerFee * FLOAT_SCALAR),
            txb.pure.u64(makerFee * FLOAT_SCALAR),
            txb.pure.u64(stakeRequired * DEEP_SCALAR),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const vote = async (
    txb: TransactionBlock,
    pool_id: string,
    balance_manager_id: string,
    proposal_id: string,
) => {
    // TODO: Test
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

    // await stake(txb, TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 100);
    // await unstake(txb, DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE);
    // await submitProposal(txb, TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 0.0005, 0.0002, 10);
    // await vote(txb, TONY_SUI_POOL_ID, MANAGER_ID, 'proposal_id');

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
