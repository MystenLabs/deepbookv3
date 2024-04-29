import { SuiClient, SuiObjectData } from "@mysten/sui.js/client";
import { TransactionBlock, TransactionResult } from "@mysten/sui.js/transactions";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import { SUI_TYPE_ARG } from "@mysten/sui.js/utils";
import dotenv from "dotenv";
import { appendFileSync, writeFile, writeFileSync } from "fs";
import { randomInt } from "crypto";
dotenv.config();

let owner = "0x02031593be871e2a24b69895e134d51f98ff78aff49b28e7f498c3abba41305c"
let coin = "0x638de21ba1c5076010eaa3f81198af0166e00682e0c96e04755a5395adc90779"
let poolPackage = "0xe31e536d5d8bbfb0f370b4859171d8ae08c8014d83a826fc094a3a391496504d"
let poolObj = "0xdd060b33e3acf223533e7a3a8c6f4f83dccc5c4b2c346494cd7ce0f29e8a36c9"
const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });
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
    let numCoins = 250;
    let coinAmount = 20_000_000;
    for (let j = 0; j < 400; j++) {
        let res = await prepareCoinObjects(owner, numCoins, coin, coinAmount) as any[]
        let futures: any[] = []
        for (let i = 0; i < numCoins; i++) {
            console.log(res[i])
            futures.push(placeOrderCritbit(res[i]))
        }

        console.log('got all futures ' + j)
        for (let i = 0; i < numCoins; i++) {
            await futures[i]
        }
        console.log('done')
    }
}

const placeOrderCritbit = async (gasCoin: any) => {
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
    
    return execute(txb)
}

const placeOrdersBigVec = async () => {
    console.log(`Placing order`)
    let txb = new TransactionBlock();
    txb.moveCall({
        target: `${poolPackage}::pool::place_limit_order_bigvec`,
        arguments: [
            txb.object(poolObj),
            txb.pure(1),
            txb.pure(1),
            txb.pure(false)
        ]
    })
}

const cancelFirstAskCritbit = async (gasCoin: any) => {
    let txb = new TransactionBlock();
    txb.moveCall({
        target: `${poolPackage}::pool::cancel_first_ask_critbit`,
        arguments: [
            txb.object(poolObj),
        ]
    })

    return execute(txb)
}

const cancelFirstAskBigVec = async () => {
    let txb = new TransactionBlock();
    txb.moveCall({
        target: `${poolPackage}::pool::cancel_first_ask_bigvec`,
        arguments: [
            txb.object(poolObj),
        ]
    })

    execute(txb)
}

const execute = async (txb: TransactionBlock) => {
    await client.signAndExecuteTransactionBlock({
        transactionBlock: txb,
        signer: keypair,
        options: {
            showObjectChanges: true,
            showEffects: true
        }
    }).then((res) => {
        let gas = res.effects?.gasUsed;
        if (gas) {
            totalComputationCost += +gas.computationCost
            totalStorageCost += +gas.storageCost
            totalStorageRebate += +gas.storageRebate
            totalNonRefundableStorageFee += +gas.nonRefundableStorageFee
        }
        let data = `${++iteration} ${totalStorageCost} ${totalStorageRebate} ${totalNonRefundableStorageFee} \n`
        appendFileSync('critbit_place.txt', data)
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
prepCoins()