
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getActiveAddress, signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID, normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";

// =================================================================
// Constants to update when running the different transactions
// =================================================================

const ENV = 'testnet';
const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// The package id of the `deepbook` package
const DEEPBOOK_PACKAGE_ID = `0x6967386a7a6a20610085e8e56b7ef80000ee9f2bbea9478af30d3efb3b6fab59`;
const REGISTRY_ID = `0xa4789135a2cffcd8b2e155c267d1d2467506fd6ae38f616fb76bb67724805e2a`;
const ADMINCAP_ID = `0x6244b0f5969a3d44358394f47a5dbb8c9cba3c39a75682c183dc7ab5ee087773`;
const POOL_ID = `0x2c96d2f5d1cb4501914bbd5ec93b84cd85efdb2deaef3adc8b69e7dfda433ec1`;
// Create manager and give ID
const MANAGER_ID = `0x4c5796728e1101b4ae614019c5429042cb1482f77eb4329f9e4188ac8d47f873`;
const TRADECAP_ID = ``;

// Update to the base and quote types of the pool
const BASE_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::aslancoin::ASLANCOIN`;
const QUOTE_TYPE = `0xf0087ed5c38123066b2bf4f3d0ce71fa26e26d25d7ff774bab17057b8e90064c::tonycoin::TONYCOIN`;

// Give the id of the coin objects to deposit into balance manager
const BASE_ID = `0x7ac09c0f7b067f5671bea77149e2913eb994221534178088c070e8b3b21f5506`;
const QUOTE_ID = `0xd5dd3f2623fd809bf691362b6838efc7b84e12c49741299787439f755e5ee765`;

const FLOAT_SCALAR = 1000000000;
const LARGE_TIMESTAMP = 1844674407370955161;
const POOL_CREATION_FEE = 100 * FLOAT_SCALAR;
const MY_ADDRESS = getActiveAddress();
const GAS_BUDGET = 500000000; // Update gas budget as needed for order placement

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

const createPool = async (
    txb: TransactionBlock
) => {
    const [creationFee] = txb.splitCoins(txb.gas, [txb.pure.u64(POOL_CREATION_FEE)]);

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
    amountToDeposit: number,
    coinId: string,
    coinType: string,
    txb: TransactionBlock
) => {
    const [deposit] = txb.splitCoins(
        txb.object(coinId),
        [txb.pure.u64(amountToDeposit)]
    );

    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::deposit`,
		arguments: [
            txb.object(MANAGER_ID),
            deposit,
		],
		typeArguments: [coinType]
    });

    console.log(`Deposited ${amountToDeposit} of type ${coinType} into manager ${MANAGER_ID}`);
}

const withdrawFromManager = async (
    amountToWithdraw: number,
    coinType: string,
    txb: TransactionBlock
) => {
    const coin = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(MANAGER_ID),
            txb.pure.u64(amountToWithdraw),
        ],
        typeArguments: [coinType]
    });

    txb.transferObjects([coin], MY_ADDRESS);
    console.log(`Withdrew ${amountToWithdraw} of type ${coinType} from manager ${MANAGER_ID}`);
}

const withdrawAllFromManager = async (
    coinType: string,
    txb: TransactionBlock
) => {
    const coin = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw_all`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coinType]
    });

    txb.transferObjects([coin], MY_ADDRESS);
    console.log(`Withdrew all of type ${coinType} from manager ${MANAGER_ID}`);
};

const checkManagerBalance = async (
    coinType: string,
    txb: TransactionBlock
) => {
    // Result types: [U64]
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::balance`,
        arguments: [
            txb.object(MANAGER_ID),
        ],
        typeArguments: [coinType]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const bytes = res.results![0].returnValues![0][0];
    const parsed_balance = bcs.U64.parse(new Uint8Array(bytes));

    console.log(`Manager balance for ${coinType} is ${parsed_balance.toString()}`); // Output the u64 number as a string
}

/// Places an order in the pool
const placeLimitOrder = async (
    isOwner: boolean,
    txb: TransactionBlock
) => {
    txb.setGasBudget(GAS_BUDGET);
    const clientOrderId = 88;
    const orderType = NO_RESTRICTION;
    const selfMatchingOption = SELF_MATCHING_ALLOWED;
    const price = 2000000;
    const quantity = 1000000;
    const isBid = true;
    const payWithDeep = false;
    var tradeProof;

    if (isOwner) {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
            arguments: [
                txb.object(MANAGER_ID),
            ],
        });
    } else {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_trader`,
            arguments: [
                txb.object(MANAGER_ID),
                txb.object(TRADECAP_ID),
            ],
        });
    }

    const orderInfo = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::place_limit_order`,
        arguments: [
            txb.object(POOL_ID),
            txb.object(MANAGER_ID),
            tradeProof,
            txb.pure.u64(clientOrderId),
            txb.pure.u8(orderType),
            txb.pure.u8(selfMatchingOption),
            txb.pure.u64(price),
            txb.pure.u64(quantity),
            txb.pure.bool(isBid),
            txb.pure.bool(payWithDeep),
            txb.pure.u64(LARGE_TIMESTAMP),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const ID = bcs.struct('ID', {
        bytes: bcs.Address,
    });

    const Fill = bcs.struct('Fill', {
        orderId: bcs.u128(),
        balanceManagerId: ID,
        expired: bcs.bool(),
        completed: bcs.bool(),
        volume: bcs.u64(),
        quoteQuantity: bcs.u64(),
        takerIsBid: bcs.bool()
    });

    const OrderInfo = bcs.struct('OrderInfo', {
        poolId: bcs.Address,
        orderId: bcs.u128(),
        balanceManagerId: ID,
        clientOrderId: bcs.u64(),
        trader: bcs.Address,
        orderType: bcs.u8(),
        selfMatchingOption: bcs.u8(),
        price: bcs.u64(),
        isBid: bcs.bool(),
        originalQuantity: bcs.u64(),
        deepPerBase: bcs.u64(),
        expireTimestamp: bcs.u64(),
        executedQuantity: bcs.u64(),
        cumulativeQuoteQuantity: bcs.u64(),
        fills: bcs.vector(Fill),
        feeIsDeep: bcs.bool(),
        paidFees: bcs.u64(),
        epoch: bcs.u64(),
        status: bcs.u8(),
        marketOrder: bcs.bool()
    });

    let orderInformation = res.results![1].returnValues![0][0];
    console.log(OrderInfo.parse(new Uint8Array(orderInformation)));
}

const cancelOrder = async (
    orderId: string,
    isOwner: boolean,
    txb: TransactionBlock
) => {
    txb.setGasBudget(GAS_BUDGET);

    var tradeProof;
    if (isOwner) {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
            arguments: [
                txb.object(MANAGER_ID),
            ],
        })
    } else {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_trader`,
            arguments: [
                txb.object(MANAGER_ID),
                txb.object(TRADECAP_ID),
            ],
        })
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::cancel_order`,
        arguments: [
            txb.object(POOL_ID),
            txb.object(MANAGER_ID),
            txb.object(tradeProof),
            txb.pure.u128(orderId),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });
}

const getAllOpenOrders = async (
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::account_open_orders`,
        arguments: [
            txb.object(POOL_ID),
            txb.pure.id(MANAGER_ID),
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const order_ids = res.results![0].returnValues![0][0];
    const VecSet = bcs.struct('VecSet', {
        constants: bcs.vector(bcs.U128),
    });

    let parsed_order_ids = VecSet.parse(new Uint8Array(order_ids)).constants;

    console.log(parsed_order_ids);
}

const cancelAllOrders = async (
    isOwner: boolean,
    txb: TransactionBlock
) => {
    txb.setGasBudget(GAS_BUDGET);

    var tradeProof;
    if (isOwner) {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_owner`,
            arguments: [
                txb.object(MANAGER_ID),
            ],
        })
    } else {
        tradeProof = txb.moveCall({
            target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::generate_proof_as_trader`,
            arguments: [
                txb.object(MANAGER_ID),
                txb.object(TRADECAP_ID),
            ],
        })
    }

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::cancel_all_orders`,
        arguments: [
            txb.object(POOL_ID),
            txb.object(MANAGER_ID),
            txb.object(tradeProof),
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
    // await depositIntoManager(10000000000, BASE_ID, BASE_TYPE, txb);
    // await withdrawFromManager(2000, QUOTE_TYPE, txb);
    // await withdrawAllFromManager(BASE_TYPE, txb);
    // await checkManagerBalance(BASE_TYPE, txb);
    // await checkManagerBalance(QUOTE_TYPE, txb);
    // await placeLimitOrder(true, txb);
    // await cancelOrder("36893497370791140086775802", true, txb);
    // await cancelAllOrders(true, txb);
    // await getAllOpenOrders(txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
