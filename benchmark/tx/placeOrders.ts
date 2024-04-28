import { SuiClient } from "@mysten/sui.js/client";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import dotenv from "dotenv";
dotenv.config();

let poolPackage = "0x7998f66d41887b52f3f881f52bb04f9fc3f5fc18596608256ddfd8ad5f2f81ca"
let poolObj = "0xe1dc9237a03205542b02711d8600f4695f99d0d138492f6adf9ae6296684c2b6"
const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });
let keypair = Ed25519Keypair.deriveKeypair(process.env.ADMIN_PHRASE!)
let totalComputationCost = 0;
let totalStorageCost = 0;
let totalStorageRebate = 0;
let totalNonRefundableStorageFee = 0;

const get100Coins = async () => {
    let txb = new TransactionBlock();
    let numCoins = 2;
    let coinSize = 200_000_000;

    const coins = txb.splitCoins(txb.gas, [...Array(numCoins)].map(() => coinSize))

    for (let i = 0; i < numCoins; i++) {
        console.log(coins[i])
        txb.transferObjects([coins[i]], "0xc5f61ed5855f7a4eff602dfe82ce72dbfa8d8c136d6df13d0405d064a6451bb6")
    }
    
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
        console.log(`Computation cost:              ${totalComputationCost}`)
        console.log(`Storage cost:                  ${totalStorageCost}`)
        console.log(`Storage rebate:                ${totalStorageRebate}`)
        console.log(`Non-refundable storage fee:    ${totalNonRefundableStorageFee}`)
    }).catch((err) => {
        console.log(err)
    })
}

const place100OrdersCritbit = async () => {
    let txb = new TransactionBlock();
    for (let j = 0; j < 10; j++) {
        for (let i = 0; i < 100; i++) {
            txb.moveCall({
                target: `${poolPackage}::pool::place_limit_order_critbit`,
                arguments: [
                    txb.object(poolObj),
                    txb.pure(1),
                    txb.pure(1),
                    txb.pure(false)
                ]
            })
            txb.moveCall({
                target: `${poolPackage}::pool::place_limit_order_critbit`,
                arguments: [
                    txb.object(poolObj),
                    txb.pure(1),
                    txb.pure(1),
                    txb.pure(false)
                ]
            })
        }
    
        await execute(txb, j)
    }
    
}

const placeOrders = async () => {
    console.log(`Placing order`)

    for (let i = 0; i < 10; i++) {
        let txb = new TransactionBlock();
        txb.moveCall({
            target: `${poolPackage}::pool::place_limit_order_critbit`,
            arguments: [
                txb.object(poolObj),
                txb.pure(1),
                txb.pure(1),
                txb.pure(false)
            ]
        })

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
            console.log(`${totalComputationCost}`)
            console.log(`${totalStorageCost}`)
            console.log(`${totalStorageRebate}`)
            console.log(`${totalNonRefundableStorageFee}`)
        }).catch((err) => {
            console.log(err)
        })
    }
}

const cancelFirstAskCritbit = async () => {
    let txb = new TransactionBlock();
    for (let i = 0; i < 1000; i++) {
        txb.moveCall({
            target: `${poolPackage}::pool::cancel_first_ask_critbit`,
            arguments: [
                txb.object(poolObj),
            ]
        })
    }

    execute(txb, 1)
}

const execute = async (txb: TransactionBlock, iter: number) => {
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
        console.log(iter)
        console.log(`${totalStorageCost}`)
        console.log(`${totalStorageRebate}`)
        console.log(`${totalNonRefundableStorageFee}`)
    }).catch((err) => {
        console.log(err)
    })
}

// get100Coins()
// placeOrders()
// cancelFirstAskCritbit()
place100OrdersCritbit()