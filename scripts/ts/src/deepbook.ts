import { TransactionBlock } from "@mysten/sui.js/transactions";
import { signAndExecute } from "./utils";
import { SUI_CLOCK_OBJECT_ID, normalizeSuiAddress } from "@mysten/sui.js/utils";
import { SuiClient, getFullnodeUrl } from "@mysten/sui.js/client";
import { bcs } from "@mysten/sui.js/bcs";
import {
    ENV, COIN_SCALARS, DEEPBOOK_PACKAGE_ID, TONY_TYPE, DEEP_TYPE, SUI_TYPE,
    DEEP_SUI_POOL_ID, TONY_SUI_POOL_ID, MANAGER_ID, REGISTRY_ID, DEEP_TREASURY_ID, COIN_IDS,
    NO_RESTRICTION, SELF_MATCHING_ALLOWED, FLOAT_SCALAR, LARGE_TIMESTAMP, GAS_BUDGET, MY_ADDRESS
} from './coinConstants';

const client = new SuiClient({ url: getFullnodeUrl(ENV) });

// =================================================================
// Transactions
// =================================================================

/// Places an order in the pool
const placeLimitOrder = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    clientOrderId: number,
    orderType: number,
    selfMatchingOption: number,
    price: number,
    quantity: number,
    isBid: boolean,
    payWithDeep: boolean,
    txb: TransactionBlock
) => {
    txb.setGasBudget(GAS_BUDGET);

    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];
    const inputPrice = price * FLOAT_SCALAR * quoteScalar / baseScalar;
    const inputQuantity = quantity * baseScalar;

    txb.moveCall({
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
    quoteType: string,
    clientOrderId: number,
    selfMatchingOption: number,
    quantity: number,
    isBid: boolean,
    payWithDeep: boolean,
    txb: TransactionBlock
) => {
    const baseScalar = COIN_SCALARS[baseType];

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
    txb.setGasBudget(GAS_BUDGET);

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::cancel_order`,
        arguments: [
            txb.object(poolId),
            txb.object(MANAGER_ID),
            txb.pure.u128(orderId),
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [DEEP_TYPE, SUI_TYPE]
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
    quoteType: string,
    txb: TransactionBlock
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];

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
    baseQuantity: number,
    txb: TransactionBlock
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_quote_quantity_out`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(baseQuantity * baseScalar),
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

    console.log(`For ${baseQuantity} base in, you will get ${baseOut / baseScalar} base, ${quoteOut / quoteScalar} quote, and requires ${deepRequired / COIN_SCALARS[DEEP_TYPE]} deep`);
}

const getBaseQuantityOut = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    quoteQuantity: number,
    txb: TransactionBlock
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_base_quantity_out`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(quoteQuantity * quoteScalar),
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

    console.log(`For ${quoteQuantity} quote in, you will get ${baseOut / baseScalar} base, ${quoteOut / quoteScalar} quote, and requires ${deepRequired / COIN_SCALARS[DEEP_TYPE]} deep`);
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
    poolId: string,
    baseType: string,
    quoteType: string,
    priceHigh: number,
    priceLow: number,
    isBid: boolean,
    txb: TransactionBlock,
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];

    txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::get_level2_range`,
        arguments: [
            txb.object(poolId),
            txb.pure.u64(priceLow * FLOAT_SCALAR * quoteScalar / baseScalar),
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
    poolId: string,
    baseType: string,
    quoteType: string,
    tickFromMid: number,
    txb: TransactionBlock,
) => {
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
    poolId: string,
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
) => {
    const baseScalar = COIN_SCALARS[baseType];
    const quoteScalar = COIN_SCALARS[quoteType];

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
    console.log(`Base in vault: ${baseInVault / baseScalar}, Quote in vault: ${quoteInVault / quoteScalar}, Deep in vault: ${deepInVault / COIN_SCALARS[DEEP_TYPE]}`);
}

const getPoolIdByAssets = async (
    baseType: string,
    quoteType: string,
    txb: TransactionBlock,
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

const swapExactBaseForQuote = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    baseAmount: number,
    deepAmount: number,
    txb: TransactionBlock
) => {
    const baseScalar = COIN_SCALARS[baseType];

    let baseCoin;
    if (baseType == SUI_TYPE) {
        [baseCoin] = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(baseAmount * baseScalar)]
        );
    } else {
        [baseCoin] = txb.splitCoins(
            txb.object(COIN_IDS.TONY),
            [txb.pure.u64(baseAmount * baseScalar)]
        );
    }
    const [deepCoin] = txb.splitCoins(
        txb.object(COIN_IDS.DEEP),
        [txb.pure.u64(deepAmount * COIN_SCALARS[DEEP_TYPE])]
    );
    let [baseOut, quoteOut, deepOut] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::swap_exact_base_for_quote`,
        arguments: [
            txb.object(poolId),
            baseCoin,
            deepCoin,
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
    txb.transferObjects([baseOut], MY_ADDRESS);
    txb.transferObjects([quoteOut], MY_ADDRESS);
    txb.transferObjects([deepOut], MY_ADDRESS);
}

const swapExactQuoteForBase = async (
    poolId: string,
    baseType: string,
    quoteType: string,
    quoteAmount: number,
    deepAmount: number,
    txb: TransactionBlock
) => {
    const quoteScalar = COIN_SCALARS[quoteType];

    let quoteCoin;
    if (quoteType == SUI_TYPE) {
        [quoteCoin] = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(quoteAmount * quoteScalar)]
        );
    } else {
        [quoteCoin] = txb.splitCoins(
            txb.object(COIN_IDS.SUI),
            [txb.pure.u64(quoteAmount * quoteScalar)]
        );
    }
    const [deepCoin] = txb.splitCoins(
        txb.object(COIN_IDS.DEEP),
        [txb.pure.u64(deepAmount * COIN_SCALARS[DEEP_TYPE])]
    );
    let [baseOut, quoteOut, deepOut] = txb.moveCall({
        target: `${DEEPBOOK_PACKAGE_ID}::pool::swap_exact_quote_for_base`,
        arguments: [
            txb.object(poolId),
            quoteCoin,
            deepCoin,
            txb.object(SUI_CLOCK_OBJECT_ID),
        ],
        typeArguments: [baseType, quoteType]
    });
    txb.transferObjects([baseOut], MY_ADDRESS);
    txb.transferObjects([quoteOut], MY_ADDRESS);
    txb.transferObjects([deepOut], MY_ADDRESS);
}

/// Main entry points, comment out as needed...
const executeTransaction = async () => {
    const txb = new TransactionBlock();

    // await addDeepPricePoint(TONY_SUI_POOL_ID, DEEP_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, DEEP_TYPE, SUI_TYPE, txb);
    // Limit order for normal pools
    // await placeLimitOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     SUI_TYPE,
    //     1234, // Client Order ID
    //     NO_RESTRICTION, // orderType
    //     SELF_MATCHING_ALLOWED, // selfMatchingOption
    //     1, // Price
    //     10, // Quantity
    //     true, // isBid
    //     true, // payWithDeep
    //     txb
    // );
    // // Limit order for whitelist pools
    // await placeLimitOrder(
    //     TONY_SUI_POOL_ID,
    //     TONY_TYPE,
    //     SUI_TYPE,
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
    // await midPrice(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, txb);
    // await whiteListed(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, txb);
    // await getQuoteQuantityOut(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, txb);
    // await getBaseQuantityOut(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, txb);
    // await getLevel2Range(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, 2.5, 7.5, true, txb);
    // await getLevel2TickFromMid(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, 1, txb);
    // await vaultBalances(DEEP_SUI_POOL_ID, DEEP_TYPE, SUI_TYPE, txb);
    // await getPoolIdByAssets(DEEP_TYPE, SUI_TYPE, txb);
    // await swapExactBaseForQuote(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, 0.0004, txb);
    // await swapExactQuoteForBase(TONY_SUI_POOL_ID, TONY_TYPE, SUI_TYPE, 1, 0.0002, txb);

    // Run transaction against ENV
    const res = await signAndExecute(txb, ENV);

    console.dir(res, { depth: null });
}

executeTransaction();
