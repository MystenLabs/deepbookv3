
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

// Create manager and give ID
const MANAGER_ID = `0x08b49d7067383d17cdd695161b247e2f617e0d9095da65edb85900e7b6f82de4`;

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
    txb: TransactionBlock
) => {
    const baseType = DEEP_TYPE;
    const quoteType = SUI_TYPE;
    txb.moveCall({
		target: `${DEEPBOOK_PACKAGE_ID}::pool::unregister_pool_admin`,
		arguments: [
			txb.object(REGISTRY_ID),
			txb.object(ADMINCAP_ID),
		],
		typeArguments: [baseType, quoteType]
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

const depositIntoManager = async (
    amountToDeposit: number,
    scalar: number,
    coinId: string,
    coinType: string,
    txb: TransactionBlock
) => {
    var deposit;
    if (coinType == SUI_TYPE) {
        [deposit] = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(amountToDeposit * scalar)]
        );
    } else {
        [deposit] = txb.splitCoins(
            txb.object(coinId),
            [txb.pure.u64(amountToDeposit * scalar)]
        );
    }

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
    scalar: number,
    coinType: string,
    txb: TransactionBlock
) => {
    const coin = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::balance_manager::withdraw`,
        arguments: [
            txb.object(MANAGER_ID),
            txb.pure.u64(amountToWithdraw * scalar),
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
    scalar: number,
    txb: TransactionBlock
) => {
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
    const balanceNumber = Number(parsed_balance);
    const adjusted_balance = balanceNumber / scalar;

    console.log(`Manager balance for ${coinType} is ${adjusted_balance.toString()}`); // Output the u64 number as a string
}

/// Places an order in the pool
const placeLimitOrder = async (
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number,
    price: number,
    quantity: number,
    isBid: boolean,
    payWithDeep: boolean,
    txb: TransactionBlock
) => {
    // Bidding for 10 deep, will pay price 2, so pay 20 SUI
    // Input quantity should be 10 * 1_000_000
    // Input price should be 2 * FLOAT_SCALAR * quote_scalar / base_scalar  = 2 * 1_000_000_000_000
    // This will make the quote quantity quantity * price = 20 * 1_000_000_000
    // This makes the quote quantity accurate
    txb.setGasBudget(GAS_BUDGET);

    const clientOrderId = 88;
    const orderType = NO_RESTRICTION;
    const selfMatchingOption = SELF_MATCHING_ALLOWED;

    const inputPrice = price * FLOAT_SCALAR * quoteScalar / baseScalar;
    const inputQuantity = quantity * baseScalar;

    const orderInfo = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::place_limit_order`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(clientOrderId),
            txb.pure.u8(orderType),
            txb.pure.u8(selfMatchingOption),
            txb.pure.u64(inputPrice),
            txb.pure.u64(inputQuantity),
            txb.pure.bool(isBid),
            txb.pure.bool(payWithDeep),
            txb.pure.u64(LARGE_TIMESTAMP),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const ID = bcs.struct('ID', {
        bytes: bcs.Address,
    });

    const OrderDeepPrice = bcs.struct('OrderDeepPrice', {
        asset_is_base: bcs.bool(),
        deep_per_asset: bcs.u64(),
    });

    const Fill = bcs.struct('Fill', {
        maker_order_id: bcs.u128(),
        balance_manager_id: ID,
        expired: bcs.bool(),
        completed: bcs.bool(),
        base_quantity: bcs.u64(),
        quote_quantity: bcs.u64(),
        taker_is_bid: bcs.bool(),
        maker_epoch: bcs.u64(),
        maker_deep_price: OrderDeepPrice,
    });

    const OrderInfo = bcs.struct('OrderInfo', {
        pool_id: ID,
        order_id: bcs.u128(),
        balance_manager_id: ID,
        client_order_id: bcs.u64(),
        trader: bcs.Address,
        order_type: bcs.u8(),
        self_matching_option: bcs.u8(),
        price: bcs.u64(),
        is_bid: bcs.bool(),
        original_quantity: bcs.u64(),
        order_deep_price: OrderDeepPrice,
        expire_timestamp: bcs.u64(),
        executed_quantity: bcs.u64(),
        cumulative_quote_quantity: bcs.u64(),
        fills: bcs.vector(Fill),
        fee_is_deep: bcs.bool(),
        paid_fees: bcs.u64(),
        epoch: bcs.u64(),
        status: bcs.u8(),
        market_order: bcs.bool(),
    });

    let orderInformation = res.results![0].returnValues![0][0];
    console.log(OrderInfo.parse(new Uint8Array(orderInformation)));
}

const cancelOrder = async (
    poolId: string,
    orderId: string,
    txb: TransactionBlock
) => {
    const baseType = DEEP_TYPE;
    const quoteType = SUI_TYPE;
    txb.setGasBudget(GAS_BUDGET);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::cancel_order`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u128(orderId),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const getAllOpenOrders = async (
    txb: TransactionBlock
) => {
    const baseType = DEEP_TYPE;
    const quoteType = SUI_TYPE;

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::account_open_orders`,
        arguments: [
            txb.object(DEEP_SUI_POOL_ID),
            txb.pure.id(MANAGER_ID),
        ],
        typeArguments: [baseType, quoteType]
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
    poolId: string,
    txb: TransactionBlock
) => {
    const baseType = DEEP_TYPE;
    const quoteType = SUI_TYPE;
    txb.setGasBudget(GAS_BUDGET);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::cancel_all_orders`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

const midPrice = async (
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::mid_price`,
        arguments: [
            txb.object(poolId),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const bytes = res.results![0].returnValues![0][0];
    const parsed_mid_price = Number(bcs.U64.parse(new Uint8Array(bytes)));
    const adjusted_mid_price = parsed_mid_price * baseScalar / quoteScalar / FLOAT_SCALAR;

    console.log(`The mid price of ${poolId} is ${adjusted_mid_price}`);
}

const addDeepPricePoint = async (
    targetPoolId: string,
    referencePoolId: string,
    targetBaseType: string,
    targetQuoteType: string,
    referenceBaseType: string,
    referenceQuoteType: string,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::add_deep_price_point`,
        arguments: [
            txb.object(targetPoolId),
            txb.object(referencePoolId),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [targetBaseType, targetQuoteType, referenceBaseType, referenceQuoteType]
    });
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await createPoolAdmin(TONY_TYPE, SUI_TYPE, txb);
    // await addDeepPricePoint(TONY_SUI_POOL_ID, DEEP_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, DEEP_TYPE, SUI_TYPE, txb);
    // await unregisterPoolAdmin(txb);
    // await createAndShareBalanceManager(txb);
    // await depositIntoManager(5000, DEEP_SCALAR, DEEP_COIN_ID, DEEP_TYPE, txb);
    // await depositIntoManager(40, SUI_SCALAR, SUI_COIN_ID, SUI_TYPE, txb);
    // await depositIntoManager(5000, TONY_SCALAR, TONY_COIN_ID, TONY_TYPE, txb);
    // await withdrawFromManager(5, SUI_SCALAR, SUI_TYPE, txb);
    // await withdrawAllFromManager(SUI_TYPE, txb);
    // await checkManagerBalance(DEEP_TYPE, DEEP_SCALAR, txb);
    // await checkManagerBalance(SUI_TYPE, SUI_SCALAR, txb);
    // await placeLimitOrder(
    //     DEEP_SUI_POOL_ID,
    //     DEEP_TYPE,
    //     DEEP_SCALAR,
    //     SUI_TYPE,
    //     SUI_SCALAR,
    //     2.5, // Price
    //     1, // Quantity
    //     true, // isBid
    //     false, // payWithDeep
    //     txb
    // );
    // await placeLimitOrder(
    //     DEEP_SUI_POOL_ID,
    //     DEEP_TYPE,
    //     DEEP_SCALAR,
    //     SUI_TYPE,
    //     SUI_SCALAR,
    //     7.5, // Price
    //     1, // Quantity
    //     false, // isBid
    //     false, // payWithDeep
    //     txb
    // );
    // await placeLimitOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     TONY_SCALAR,
    //     SUI_TYPE,
    //     SUI_SCALAR,
    //     5, // Price
    //     1, // Quantity
    //     true, // isBid
    //     true, // payWithDeep
    //     txb
    // );
    // await cancelOrder(DEEP_SUI_POOL_ID, "46116860184283102412036854775805", txb);
    // await cancelAllOrders(DEEP_SUI_POOL_ID, txb);
    // await getAllOpenOrders(txb);
    // await midPrice(DEEP_SUI_POOL_ID, DEEP_TYPE, DEEP_SCALAR, SUI_TYPE, SUI_SCALAR, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
