import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import {
    ENV, Coins, Pool, Pools, DEEPBOOK_PACKAGE_ID, REGISTRY_ID, MANAGER_ID, ADMINCAP_ID, Constants
} from './coinConstants';

// =================================================================
// Transactions
// =================================================================

const createPoolAdmin = async (
    pool: Pool,
    txb: TransactionBlock
) => {
    const [creationFee] = txb.splitCoins(
        txb.object(Coins.DEEP.coinId),
        [txb.pure.u64(Constants.POOL_CREATION_FEE)]
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
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

const unregisterPoolAdmin = async (
    pool: Pool,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unregister_pool_admin`,
        arguments: [
            txb.object(REGISTRY_ID),
            txb.object(ADMINCAP_ID),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

const updateDisabledVersions = async (
    pool: Pool,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::update_disabled_versions`,
        arguments: [
            txb.object(pool.poolAddress),
            txb.object(REGISTRY_ID),
            txb.object(ADMINCAP_ID),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createPoolAdmin(Pools.TONY_SUI_POOL, txb);
    // await unregisterPoolAdmin(Pools.DEEP_SUI_POOL, txb);
    // await updateDisabledVersions(Pools.DEEP_SUI_POOL, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
