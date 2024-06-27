import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    COIN_SCALARS, COIN_IDS, ASLAN_TYPE, TONY_TYPE, DEEP_TYPE, SUI_TYPE,
    ENV, DEEPBOOK_PACKAGE_ID, REGISTRY_ID, DEEP_SUI_POOL_ID,
    TONY_SUI_POOL_ID, MANAGER_ID, ADMINCAP_ID, NO_RESTRICTION,
    IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY, SELF_MATCHING_ALLOWED,
    CANCEL_TAKER, CANCEL_MAKER, MY_ADDRESS, POOL_CREATION_FEE,
    LARGE_TIMESTAMP, GAS_BUDGET
} from './coinConstants';

// =================================================================
// Transactions
// =================================================================

const createPoolAdmin = async (
    baseType: string,
    quoteType: string,
    txb: TransactionBlock
) => {
    const [creationFee] = txb.splitCoins(
        txb.object(COIN_IDS.DEEP),
        [txb.pure.u64(POOL_CREATION_FEE)]
    );
    const whiteListedPool = false;
    const stablePool = false;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::create_pool_admin`,
        arguments: [
            txb.object(REGISTRY_ID), // registry_id
            txb.pure.u64(1000), // tick_size
            txb.pure.u64(1000), // lot_size
            txb.pure.u64(10000), // min_size
            creationFee, // 0x2::balance::Balance<0x2::sui::SUI>
            txb.pure.bool(whiteListedPool),
            txb.pure.bool(stablePool),
            txb.object(ADMINCAP_ID), // admin_cap_id
        ],
        typeArguments: [baseType, quoteType]
    });
}

const unregisterPoolAdmin = async (
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unregister_pool_admin`,
        arguments: [
            txb.object(REGISTRY_ID),
            txb.object(ADMINCAP_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const updateDisabledVersions = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::update_disabled_versions`,
        arguments: [
            txb.object(poolId),
            txb.object(REGISTRY_ID),
            txb.object(ADMINCAP_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createPoolAdmin(TONY_TYPE, SUI_TYPE, txb);
    // await unregisterPoolAdmin(DEEP_TYPE, SUI_TYPE, txb);
    // await updateDisabledVersions(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
