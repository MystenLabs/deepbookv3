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
let poolPackage = "0x8a6a018f307b8aa910aee7cd000d4181ef87b2c3177157bae074e0f404128043"
let poolObj = "0xc8a30046328e4dae99772b373df5ecf9670f684e30feccbf668d5595e50737b7"
let vecPackage = "0x32f4cebc7345e7fd44896f44241b7d7501d87cab54b7f30b94254eedf3b6630f"
let vec = "0x3b69d481d0c66d7ea50b039b0edb2d7aa48dc58eecbac9563ce0f5019cd3804b"
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
    let numCoins = 1;
    let numIters = 1;
    let coinAmount = 20_000_000;
    for (let i = 0; i < numIters; i++) {
        let res = await prepareCoinObjects(owner, numCoins, coin, coinAmount) as any[]
        let futures: any[] = []
        for (let j = 0; j < numCoins; j++) {
            console.log(res[j])
            futures.push(tableTest(res[j]))
        }

        console.log('got all futures ' + i)
        for (let j = 0; j < numCoins; j++) {
            await futures[j]
        }
        console.log('done')
    }
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
    let price = randomInt(1, 1000000000)
    let amount = randomInt(1, 1000000000)
    txb.moveCall({
        target: `${poolPackage}::pool::place_limit_order_bigvec`,
        arguments: [
            txb.object(poolObj),
            txb.pure(price),
            txb.pure(amount),
            txb.pure(false)
        ]
    })

    return execute(txb, 'place_order_bigvec_4x250.csv')
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

const execute = async (txb: TransactionBlock, filename: string) => {
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

            let data = `${++iteration} ${+gas.computationCost} ${+gas.storageCost} ${+gas.storageRebate} ${+gas.nonRefundableStorageFee} \n`
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
prepCoins()