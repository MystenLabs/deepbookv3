
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
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
const DEEPBOOK_PACKAGE_ID = `0x22ed917fa56afe09677314871a2997a111ebacd1f622b6cfed3a4422aa4d2e06`;
const REGISTRY_ID = `0x14614dfc9243fcb2ef7ac51efed5c6284ca701d55216e1f42b3eb22c541feaa6`;
const DEEP_TREASURY_ID = `0x69fffdae0075f8f71f4fa793549c11079266910e8905169845af1f5d00e09dcb`;
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

/// Places an order in the pool
const placeLimitOrder = async (
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number,
    clientOrderId: number,
    orderType: number,
    selfMatchingOption: number,
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
}

const placeMarketOrder = async (
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    clientOrderId: number,
    selfMatchingOption: number,
    quantity: number,
    isBid: boolean,
    payWithDeep: boolean,
    txb: TransactionBlock
) => {
    txb.setGasBudget(GAS_BUDGET);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::place_market_order`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u64(clientOrderId),
            txb.pure.u8(selfMatchingOption),
            txb.pure.u64(quantity * baseScalar),
            txb.pure.bool(isBid),
            txb.pure.bool(payWithDeep),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
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

const cancelAllOrders = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock
) => {
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

const burnDeep = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    quoteType: string
) => {
    // TODO: Test
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::burn_deep`,
        arguments: [
            txb.object(poolId),
            txb.object(DEEP_TREASURY_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
}

// PUBLIC VIEW FUNCTIONS
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

const whiteListed = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::whitelisted`,
        arguments: [
            txb.object(poolId),
        ],
        typeArguments: [baseType, quoteType]
    });
    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const bytes = res.results![0].returnValues![0][0];
    const whitelisted = bcs.Bool.parse(new Uint8Array(bytes));

    console.log(`Whitelist status for ${poolId} is ${whitelisted}`);
}

const getQuoteQuantityOut = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    baseScalar: number,
    quoteScalar: number,
    baseQuantity: number,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_quote_quantity_out`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(baseQuantity * baseScalar), // base_quantity
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const baseOut = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![0][0])));
    const quoteOut = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![1][0])));
    const deepRequired = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![2][0])));

    console.log(`For ${baseQuantity} base in, you will get ${baseOut / baseScalar} base, ${quoteOut / quoteScalar} quote, and requires ${deepRequired / DEEP_SCALAR} deep`);
}

const getBaseQuantityOut = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    baseScalar: number,
    quoteScalar: number,
    quoteQuantity: number,
    txb: TransactionBlock
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_base_quantity_out`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(quoteQuantity * quoteScalar), // quote_quantity
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const baseOut = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![0][0])));
    const quoteOut = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![1][0])));
    const deepRequired = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![2][0])));

    console.log(`For ${quoteQuantity} quote in, you will get ${baseOut / baseScalar} base, ${quoteOut / quoteScalar} quote, and requires ${deepRequired / DEEP_SCALAR} deep`);
}

const accountOpenOrders = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::account_open_orders`,
        arguments: [
            txb.object(poolId),
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

const getLevel2Range = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number,
    priceHigh: number,
    priceLow: number,
    isBid: boolean,
) => {
    // TODO: Test
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_level2_range`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(0),
			txb.pure.u64(priceHigh * FLOAT_SCALAR * quoteScalar / baseScalar),
			txb.pure.bool(isBid),
        ],
        typeArguments: [baseType, quoteType]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const prices = res.results![0].returnValues![0][0];
    const parsed_prices = bcs.vector(bcs.u64()).parse(new Uint8Array(prices));
    const quantities = res.results![0].returnValues![1][0];
    const parsed_quantities = bcs.vector(bcs.u64()).parse(new Uint8Array(quantities));
    console.log(res.results![0].returnValues![0])
    console.log(parsed_prices);
    console.log(parsed_quantities);
}

const getLevel2TickFromMid = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number,
    tickFromMid: number
) => {
    // TODO: Test
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_level2_tick_from_mid`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(tickFromMid)
        ],
        typeArguments: [baseType, quoteType]
    });
}

const vaultBalances = async (
    txb: TransactionBlock,
    poolId: string,
    baseType: string,
    baseScalar: number,
    quoteType: string,
    quoteScalar: number
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::vault_balances`,
        arguments: [
            txb.object(poolId),
        ],
        typeArguments: [baseType, quoteType]
    });

    const res = await client.devInspectTransactionBlock({
        sender: normalizeSuiAddress(MY_ADDRESS),
        transactionBlock: txb,
    });

    const baseInVault = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![0][0])));
    const quoteInVault = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![1][0])));
    const deepInVault = Number(bcs.U64.parse(new Uint8Array(res.results![0].returnValues![2][0])));
    console.log(`Base in vault: ${baseInVault / baseScalar}, Quote in vault: ${quoteInVault / quoteScalar}, Deep in vault: ${deepInVault / DEEP_SCALAR}`);
}

const getPoolIdByAssets = async (
    txb: TransactionBlock,
    baseType: string,
    quoteType: string
) => {
    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_pool_id_by_asset`,
        arguments: [
            txb.object(REGISTRY_ID),
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
    const address = ID.parse(new Uint8Array(res.results![0].returnValues![0][0]))['bytes'];
    console.log(`Pool ID base ${baseType} and quote ${quoteType} is ${address}`);
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await addDeepPricePoint(TONY_SUI_POOL_ID, DEEP_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, DEEP_TYPE, SUI_TYPE, txb);
    // // Limit order for normal pools
    // await placeLimitOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     TONY_SCALAR,
    //     SUI_TYPE,
    //     SUI_SCALAR,
    //     1234, // Client Order ID
    //     NO_RESTRICTION, // orderType
    //     SELF_MATCHING_ALLOWED, // selfMatchingOption
    //     2.5, // Price
    //     1, // Quantity
    //     true, // isBid
    //     true, // payWithDeep
    //     txb
    // );
    // // Limit order for whitelist pools
    // await placeLimitOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     TONY_SCALAR,
    //     SUI_TYPE,
    //     SUI_SCALAR,
    //     1234, // Client Order ID
    //     NO_RESTRICTION, // orderType
    //     SELF_MATCHING_ALLOWED, // selfMatchingOption
    //     2.5, // Price
    //     1, // Quantity
    //     true, // isBid
    //     false, // payWithDeep
    //     txb
    // );
    // Market order for normal pools
    // await placeMarketOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     TONY_SCALAR,
    //     SUI_TYPE,
    //     1234, // Client Order ID
    //     SELF_MATCHING_ALLOWED, // selfMatchingOption
    //     1, // Quantity
    //     false, // isBid
    //     true, // payWithDeep
    //     txb
    // );
    // // Market order for whitelist pools
    // await placeMarketOrder(
    //     DEEP_SUI_POOL_ID,
    //     DEEP_TYPE,
    //     DEEP_SCALAR,
    //     SUI_TYPE,
    //     1234, // Client Order ID
    //     SELF_MATCHING_ALLOWED, // selfMatchingOption
    //     1, // Quantity
    //     true, // isBid
    //     false, // payWithDeep
    //     txb
    // );
    // await cancelOrder(DEEP_SUI_POOL_ID, "46116860184283102412036854775805", txb);
    // await cancelAllOrders(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, txb);
    // await accountOpenOrders(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, txb);
    // await midPrice(DEEP_SUI_POOL_ID, DEEP_TYPE, DEEP_SCALAR, SUI_TYPE, SUI_SCALAR, txb);
    // await whiteListed(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, txb);
    // await getQuoteQuantityOut(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, DEEP_SCALAR, SUI_SCALAR, 1, txb);
    // await getBaseQuantityOut(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, DEEP_SCALAR, SUI_SCALAR, 1, txb);
    // await getLevel2Range(txb, DEEP_SUI_POOL_ID, DEEP_TYPE, DEEP_SCALAR, SUI_TYPE, SUI_SCALAR, 2.5, 7.5, true);
    // await getLevel2TickFromMid(txb, DEEP_SUI_POOL_ID, DEEP_TYPE, DEEP_SCALAR, SUI_TYPE, SUI_SCALAR, 1);
    // await vaultBalances(txb, DEEP_SUI_POOL_ID, DEEP_TYPE, DEEP_SCALAR, SUI_TYPE, SUI_SCALAR);
    // await getPoolIdByAssets(txb, DEEP_TYPE, SUI_TYPE);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
