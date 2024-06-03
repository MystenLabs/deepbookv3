
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui.js/utils";
import { SuiClient, SuiObjectData } from "@mysten/sui.js/client";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x7356e1ad3674d0f231bd48f1652785a3a638649a83c0f6c00253e804d9194794`;
const REGISTRY_ID = `0xd5ea9c35b172aaa632787328f094074f66fac980f494c657814bcfc2a19231b3`;
const ADMINCAP_ID = `0x12a131a64622c7ec083ddf2e09c1169abb13a262534039daa5522202be0ac28f`;
const POOL_ID = `0x2493f3ecd621c0aaba56891074d212c7fb5c9aad258eb677fe1deb0745d744ed`;
const BASE_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
const QUOTE_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;
const BASE_ID = `0x401cd69414ef9ba9a3a0a4d25b2e9198fc890bd56dcf560d6b543c80ff788815`;
const QUOTE_ID = `0x1f33081921a5cd39b52abfefba5e2621342938d83a73db5ffb6c7372fd01f8e6`;
const COIN_OBJECT = `0x06d4517a11724dffa7cada801578db3342cdca57c655688e480b69079ab58089`;
const MANAGER_ID = `0x50452a36acd68d0847b61eff5f92822da516bb6a73bd513f0224f74406eb4873`;

const FLOAT_SCALAR = 1000000000;
const LARGE_TIMESTAMP = 184467440737095516;

// =================================================================
// Transactions
// =================================================================

const createPool = async (
    txb: TransactionBlock
) => {
    // get the base gas coin from the provider
    const { data } = await client.getObject({
        id: COIN_OBJECT
    });
    if (!data) return false;
    // use the gas coin to pay for the gas.
    txb.setGasPayment([data]);

    const [creationFee] = txb.splitCoins(txb.gas, [txb.pure.u64(100 * FLOAT_SCALAR)]);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::create_pool`,
        arguments: [
            txb.object(REGISTRY_ID), // registry_id
            txb.pure.u64(1000), // tick_size
            txb.pure.u64(1000), // lot_size
            txb.pure.u64(10000), // min_size
            creationFee, // 0x2::balance::Balance<0x2::sui::SUI>
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });
}

const createAndShareBalanceManager = async (
    txb: TransactionBlock
) => {
    const manager = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::new`,
    });
    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::share`,
		arguments: [
			manager,
		],
    });
}

// Admin Only
const whiteListPool = async (
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::set_whitelist`,
        arguments: [
            txb.object(POOL_ID),
            txb.object(ADMINCAP_ID),
            txb.pure.bool(true),
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });
}

const depositIntoManager = async (
    amount_to_deposit: number,
    txb: TransactionBlock
) => {
    // TODO: allow optional amount to deposit

    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::deposit`,
		arguments: [
            txb.object(MANAGER_ID), // 0x7356e1ad3674d0f231bd48f1652785a3a638649a83c0f6c00253e804d9194794::balance_manager::BalanceManager
            txb.object(QUOTE_ID), // 0x2::coin::Coin<Type_0>
		],
		typeArguments: [QUOTE_TYPE]
    });
}

/// Places an order in the pool
const placeLimitOrder = (
    txb: TransactionBlock
) => {
    const tradeProof = txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
		arguments: [
            txb.object(MANAGER_ID),
        ],
    });

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::place_limit_order`,
        arguments: [
            txb.object(POOL_ID), // 0x7356e1ad3674d0f231bd48f1652785a3a638649a83c0f6c00253e804d9194794::pool::Pool<Type_0,Type_1>
            txb.object(MANAGER_ID), // 0x7356e1ad3674d0f231bd48f1652785a3a638649a83c0f6c00253e804d9194794::balance_manager::BalanceManager
            tradeProof, // 0x7356e1ad3674d0f231bd48f1652785a3a638649a83c0f6c00253e804d9194794::balance_manager::TradeProof
            txb.pure.u64(88),
            txb.pure.u8(0),
            txb.pure.u64(8 * FLOAT_SCALAR),
            txb.pure.u64(1000 * FLOAT_SCALAR),
            txb.pure.bool(true),
            txb.pure.bool(false), // false to not pay with deep
            txb.pure.u64(LARGE_TIMESTAMP),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createPool(txb);
    // await createAndShareBalanceManager(txb);
    // await whiteListPool(txb);
    // await depositIntoManager(1000, txb);
    // await placeLimitOrder(txb); // Fix whitelist fee free problem first

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
