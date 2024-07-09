import { TransactionBlock } from "@mysten/sui.js/transactions";
import {
    DEEPBOOK_PACKAGE_ID, REGISTRY_ID
} from '../utils/config';
import { FLOAT_SCALAR, POOL_CREATION_FEE } from "../utils/config";
import { Coin, Pool } from "../utils/interfaces";

export const createPoolAdmin = (
    baseCoin: Coin,
    quoteCoin: Coin,
    deepCoinId: string,
    tickSize: number,
    lotSize: number,
    minSize: number,
    whitelisted: boolean,
    stablePool: boolean,
    txb: TransactionBlock
) => {
    const [creationFee] = txb.splitCoins(
        txb.object(deepCoinId),
        [txb.pure.u64(POOL_CREATION_FEE)]
    );

    const baseScalar = baseCoin.scalar;
    const quoteScalar = quoteCoin.scalar;

    const adjustedTickSize = tickSize * FLOAT_SCALAR * quoteScalar / baseScalar;
    const adjustedLotSize = lotSize * baseScalar;
    const adjustedMinSize = minSize * baseScalar;
    const adminCap = process.env.ADMIN_CAP;
    if (!adminCap) {
        throw new Error("ADMIN_CAP environment variable not set");
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::create_pool_admin`,
        arguments: [
            txb.object(REGISTRY_ID), // registry_id
            txb.pure.u64(adjustedTickSize), // adjusted tick_size
            txb.pure.u64(adjustedLotSize), // adjusted lot_size
            txb.pure.u64(adjustedMinSize), // adjusted min_size
            creationFee, // 0x2::balance::Balance<0x2::sui::SUI>
            txb.pure.bool(whitelisted),
            txb.pure.bool(stablePool),
            txb.object(adminCap), // admin_cap_id
        ],
        typeArguments: [baseCoin.type, quoteCoin.type]
    });
}

export const unregisterPoolAdmin = (
    pool: Pool,
    txb: TransactionBlock,
) => {
    const adminCap = process.env.ADMIN_CAP;
    if (!adminCap) {
        throw new Error("ADMIN_CAP environment variable not set");
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::unregister_pool_admin`,
        arguments: [
            txb.object(REGISTRY_ID),
            txb.object(adminCap),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}

export const updateDisabledVersions = (
    pool: Pool,
    txb: TransactionBlock,
) => {
    const adminCap = process.env.ADMIN_CAP;
    if (!adminCap) {
        throw new Error("ADMIN_CAP environment variable not set");
    }
    
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::update_disabled_versions`,
        arguments: [
            txb.object(pool.address),
            txb.object(REGISTRY_ID),
            txb.object(adminCap),
        ],
        typeArguments: [pool.baseCoin.type, pool.quoteCoin.type]
    });
}
