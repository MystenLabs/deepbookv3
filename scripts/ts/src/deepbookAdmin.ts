
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID, normalizeSuiAddress, SUI_TYPE_ARG } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;
const REGISTRY_ID = `0x14614dfc9243fcb2ef7ac51efed5c6284ca701d55216e1f42b3eb22c541feaa6`;
const ADMINCAP_ID = `0x30314edf9cfa6057722746f31b0973225b38437589b067d4ca6ad263cef9186a`;
const DEEP_SUI_POOL_ID = `0x9c29aa70749297fe4fc35403ae743cc8883ad26ba77b9ba214dbff7d5f9a5395`;
const TONY_SUI_POOL_ID = `0x92083a73031ad86c6df401dc4a59b5dfa589db5937a921c2ec72a5629b715154`;

// Update to the base and quote types of the pool
const ASLAN_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
const TONY_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;
const DEEP_TYPE = `0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP`;
const SUI_TYPE = `0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI`;

// Give the id of the coin objects to deposit into balance manager
const DEEP_COIN_ID = `0x363fc7964af3ce74ec92ba37049601ffa88dfa432c488130b340b52d58bdcf50`;
const SUI_COIN_ID = `0x0064c4fd7c1c8f56ee8fb1d564bcd1c32a274156b942fd0ea25d605e3d2c5315`;
const TONY_COIN_ID = `0xd5dd3f2623fd809bf691362b6838efc7b84e12c49741299787439f755e5ee765`;

const DEEP_SCALAR = 1000000;
const SUI_SCALAR = 1000000000;
const TONY_SCALAR = 1000000;
const FLOAT_SCALAR = 1000000000;
const POOL_CREATION_FEE = 10000 * DEEP_SCALAR;
const LARGE_TIMESTAMP = 1844674407370955161;
const MY_ADDRESS = getActiveAddress();
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

const createPoolAdmin = async (
    baseType: string,
    quoteType: string,
    txb: TransactionBlock
) => {
    const [creationFee] = txb.splitCoins(
        txb.object(DEEP_COIN_ID),
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
    txb: TransactionBlock,
    baseType: string,
    quoteType: string
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

const UpdateDisabledVersions = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    quoteType: string
) => {
    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::pool::unregister_pool_admin`,
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
    // await UpdateDisabledVersions(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
