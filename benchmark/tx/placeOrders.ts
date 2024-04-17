import { SuiClient } from "@mysten/sui.js/client";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import dotenv from "dotenv";
dotenv.config();

const placeOrders = async () => {
    const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });
    let keypair = Ed25519Keypair.deriveKeypair(process.env.ADMIN_PHRASE!)
    let totalComputationCost = 0;
    let totalStorageCost = 0;
    let totalStorageRebate = 0;
    let totalNonRefundableStorageFee = 0;

    for (let i = 0; i < 100; i++) {
        let time = 1000;
        let price = Math.floor(Math.random() * 10) + 1;
        let amount = Math.floor(Math.random() * 100) + 1;
        console.log(`Placing order ${i} with price: ${price} and amount: ${amount}`)

        let poolPackage = "0x6dc4b38b10b2e9f8b393c0235adbf6dfbceb9780e12726a8c7fae6258d22bfd8"
        let poolObj = "0x24ebef42a67e995809dda9ce7186c7adb864f4ac4e895d0c69375aa1f6843489"

        let txb = new TransactionBlock();
        txb.moveCall({
            target: `${poolPackage}::pool::place_limit_order_critbit`,
            arguments: [
                txb.object(poolObj),
                txb.pure(price),
                txb.pure(amount),
                txb.pure(price >= 5)
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
            console.log(`Computation cost:              ${totalComputationCost}`)
            console.log(`Storage cost:                  ${totalStorageCost}`)
            console.log(`Storage rebate:                ${totalStorageRebate}`)
            console.log(`Non-refundable storage fee:    ${totalNonRefundableStorageFee}`)
        }).catch((err) => {
            console.log(err)
            i--
            time = 10000
        })

        await new Promise(r => setTimeout(r, time));
        time = 1000
    }

    // let txb = new TransactionBlock();
    // txb.moveCall({
    //     target: `0xdee1b7d8ff93bff51c89e0968d52532be1ecddfa8062ca6b24e60563517f7f23::pool::place_limit_order_bigvec`,
    //     arguments: [
    //         txb.object("0xd38bb453666c851a67b53708d85780b03613cd89275956450a94551394a96d0b"),
    //         txb.pure(1),
    //         txb.pure(1),
    //         txb.pure(true)
    //     ]
    // })

    // client.signAndExecuteTransactionBlock({
    //     transactionBlock: txb,
    //     signer: keypair,
    //     options: {
    //         showObjectChanges: true,
    //         showEffects: true
    //     }
    // }).then((res) => {
    //     let gas = res.effects?.gasUsed;
    //     console.log(gas)
    // })
}

placeOrders()