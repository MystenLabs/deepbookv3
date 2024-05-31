import { SuiClient, SuiObjectData, getFullnodeUrl } from "@mysten/sui.js/client";
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { SUI_TYPE_ARG, normalizeSuiAddress } from "@mysten/sui.js/utils";
import dotenv from "dotenv";
import { appendFileSync, writeFile, writeFileSync } from "fs";
import { randomInt } from "crypto";
import { SUI_CLOCK_OBJECT_ID } from "@mysten/sui.js/utils";
import { bcs } from "@mysten/sui.js/bcs";
dotenv.config();

let owner = "0x02031593be871e2a24b69895e134d51f98ff78aff49b28e7f498c3abba41305c"
let coin = "0x638de21ba1c5076010eaa3f81198af0166e00682e0c96e04755a5395adc90779"
let poolPackage = "0x60047925bda4bae0592d6310dd8eedaa29083132b482b285feb1305864dc8032"
let poolObj = "0x0b3e1bd77f92224c4640095c7582c2ad94fe2f29af7c9f3528fc8dacaf28da78"
let vecPackage = "0xcb0928a4f21db696ebd88f8449d64b0a756a69af16511cc3997a7ca39660e74e"
let vec = "0xeca6a498d0a8a2aaeed93cd4f78e80f74995663cbfac3fbd3fdf598bcc0dd18f"

let orders: number[] = [];

const client = new SuiClient({ url: getFullnodeUrl('mainnet') });
let keypair = Ed25519Keypair.deriveKeypair(process.env.ADMIN_PHRASE!)
let totalComputationCost = 0;
let totalStorageCost = 0;
let totalStorageRebate = 0;
let totalNonRefundableStorageFee = 0;
let iteration = 0;

/* get X amount of chunks of Coins based on amount per tx. */
const prepareCoinObjects = async (toAddress: string, chunks: number, baseCoinId: string, amountPerChunk: number) => {
    const txb = new TransactionBlock();

    // get the base gas coin from the provider
    const { data } = await client.getObject({
        id: baseCoinId
    });

    if (!data) return false;

    // use the gas coin to pay for the gas.
    txb.setGasPayment([data]);

    const coinsSplitted: TransactionResult[] = [];

    for (let i = 0; i < chunks; i++) {
        const coin = txb.splitCoins(
            txb.gas,
            [txb.pure.u64(amountPerChunk)]
        );
        coinsSplitted.push(coin);
    }

    txb.transferObjects(coinsSplitted, txb.pure.address(toAddress));

    const res = await signAndExecute(txb);

    //@ts-ignore
    return res?.objectChanges?.filter(x => x.type === 'created' && x.objectType === `0x2::coin::Coin<${SUI_TYPE_ARG}>`).map((x: SuiObjectData) =>  (
        {
            objectId: x.objectId,
            version: x.version,
            digest: x.digest
        }
    ));
}

// return array of addresses
const prepCoins = async () => {
    let numCoins = 1;
    let numIters = 1;
    let coinAmount = 200_000_000;
    for (let i = 0; i < numIters; i++) {
        let res = await prepareCoinObjects(owner, numCoins, coin, coinAmount) as any[]
        let futures: any[] = []
        for (let j = 0; j < numCoins; j++) {
            futures.push(cleanupExpired(res[j]))
        }

        console.log('got all futures ' + i)
        for (let j = 0; j < numCoins; j++) {
            await futures[j]
        }
        console.log('done')
    }
}

const cleanupExpired = async (gasCoin: any) => {
    console.log(`Cleaning up`)
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    let orderIdvec = txb.makeMoveVec({objects: ['14709092'], type: 'u64'})
    let orderOwnervec = txb.makeMoveVec({objects: ['0x60455349f0a1999666f8e58efe14c4c6fa50915c10bfbbb73f39b9db58db1255'], type: 'address'})
    txb.moveCall({
        target: `0x000000000000000000000000000000000000000000000000000000000000dee9::clob_v2::clean_up_expired_orders`,
        typeArguments: [ '0x2::sui::SUI', '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN' ],
        arguments: [
            txb.object('0x4405b50d791fd3346754e8171aaab6bc2ed26c2c46efdd033c14b30ae507ac33'),
            txb.object('0x6'),
            orderIdvec,
            orderOwnervec,
        ]
    })
    
    return execute(txb, 'place_order_critbit.csv')
}

const placeOrdersCritbit = async (gasCoin: any) => {
    console.log(`Placing order`)
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    let price = randomInt(1, 1000000000)
    let amount = randomInt(1, 1000000000)
    txb.moveCall({
        target: `${poolPackage}::pool::place_limit_order_critbit`,
        arguments: [
            txb.object(poolObj),
            txb.pure(price),
            txb.pure(amount),
            txb.pure(false)
        ]
    })
    
    return execute(txb, 'place_order_critbit.csv')
}

const placeOrdersBigVec = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    txb.setGasBudget(20_000_000)
    let price = randomInt(1, 1000000000)
    let amount = randomInt(1, 1000000000)
    orders.push(++iteration)
    txb.moveCall({
        target: `${poolPackage}::pool::place_limit_order_bigvec`,
        arguments: [
            txb.object(poolObj),
            txb.pure(price),
            txb.pure(amount),
            txb.pure(false)
        ]
    })

    return execute(txb, 'place_order_bigvec_16x16cancel.csv')
}

const cancelOrderBigVec = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    txb.setGasBudget(20_000_000)
    let idx = randomInt(0, orders.length - 90)
    let orderId = orders[idx];
    let last = orders.pop()!
    orders[idx] = last

    // let price = randomInt(1, 1000000000)
    // let amount = randomInt(1, 1000000000)
    // orders.push(iteration)
    txb.moveCall({
        target: `${poolPackage}::pool::cancel_order_bigvec`,
        arguments: [
            txb.object(poolObj),
            txb.pure(orderId),
        ]
    })

    return execute(txb, 'place_order_bigvec_16x16cancel.csv')
}

const cancelFirstAskCritbit = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.moveCall({
        target: `${poolPackage}::pool::cancel_first_ask_critbit`,
        arguments: [
            txb.object(poolObj),
        ]
    })

    return execute(txb, 'cancel_first_ask_critbit.csv')
}

const cancelFirstAskBigVec = async () => {
    let txb = new TransactionBlock();
    txb.moveCall({
        target: `${poolPackage}::pool::cancel_first_ask_bigvec`,
        arguments: [
            txb.object(poolObj),
        ]
    })

    execute(txb, 'cancel_first_ask_bigvec.csv')
}

const vectorTest = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    txb.moveCall({
        target: `${vecPackage}::vector::add_to_table`,
        arguments: [
            txb.object(vec),
            txb.pure(iteration)
        ]
    })

    return execute(txb, 'vector.csv')
}

const tableTest = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    txb.moveCall({
        target: `${vecPackage}::vector::remove_from_table`,
        arguments: [
            txb.object(vec),
            txb.pure(iteration)
        ]
    })

    return execute(txb, 'vector.csv')
}

const offsiteTest = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.setGasPayment([gasCoin])
    txb.setGasBudget(20_000_000)
    txb.moveCall({
        target: `${vecPackage}::vector::remove_from_table`,
        arguments: [
            txb.object(vec),
            txb.pure(iteration)
        ]
    })

    return execute(txb, 'offsite.csv')
}

const getOrders = async () => {

    const Order = bcs.struct('Order', {
        order_id: bcs.U64,
        client_order_id: bcs.U64,
        price: bcs.U64,
        original_quantity: bcs.U64,
        quantity: bcs.U64,
        is_bid: bcs.Bool,
        owner: bcs.Address,
        expire_timestamp: bcs.U64,
        self_matching_prevention: bcs.U8
    });

    const OrderPage = bcs.struct('OrderPage', {
        orders: bcs.vector(Order),
        has_next_page: bcs.Bool,
        next_tick_level: bcs.option(bcs.U64),
        next_order_id: bcs.option(bcs.U64)
    });


    const inspect = new TransactionBlock();
    let optionNone = inspect.moveCall({
        target: `0x1::option::none`,
        typeArguments: [ 'u64' ],
    })
    inspect.moveCall({
      target: `0xdee9::order_query::iter_bids`,
      typeArguments: [ '0x2::sui::SUI', '0x5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN' ],
      arguments: [
        inspect.object('0x4405b50d791fd3346754e8171aaab6bc2ed26c2c46efdd033c14b30ae507ac33'),
        optionNone,
        optionNone,
        optionNone,
        optionNone,
        inspect.pure(false),
      ],
    });
    const res = await client.devInspectTransactionBlock({
      sender: normalizeSuiAddress('0x0'),
      transactionBlock: inspect,
    });
    
    // console.log(res.results!)
    console.log(res.results![0].returnValues![0])
    console.log(res.results![1].returnValues![0])
    // @ts-ignore
    let parsedResult = OrderPage.parse(new Uint8Array(res.results![1].returnValues![0][0]));
    console.log(parsedResult.orders.length)
    console.log(parsedResult.orders.map((e) => ({ ...e, is_expired: +e.expire_timestamp < Date.now() })))
    // console.log(parsedResult.orders)
}



const execute = async (txb: TransactionBlock, filename: string) => {
    await client.signAndExecuteTransactionBlock({
        transactionBlock: txb,
        signer: keypair,
        options: {
            showObjectChanges: true,
            showEffects: true
        }
    }).then((res) => {
        let success = res.effects?.status?.status;
        let gas = res.effects?.gasUsed;
        if (success == 'success' && gas) {
            totalComputationCost += +gas.computationCost
            totalStorageCost += +gas.storageCost
            totalStorageRebate += +gas.storageRebate
            totalNonRefundableStorageFee += +gas.nonRefundableStorageFee

            let data = `${iteration} ${+gas.computationCost} ${+gas.storageCost} ${+gas.storageRebate} ${+gas.nonRefundableStorageFee} \n`
            appendFileSync(filename, data)
        }
    }).catch((err) => {
        console.log(err)
    })
}

const signAndExecute = async (txb: TransactionBlock) => {
    return client.signAndExecuteTransactionBlock({
        transactionBlock: txb,
        signer: keypair,
        options: {
            showObjectChanges: true,
            showEffects: true
        }
    })
}

// get100Coins()
// placeOrders()
// cancelFirstAskCritbit()
// prepCoins()
getOrders()