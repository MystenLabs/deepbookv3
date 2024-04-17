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
        let price = Math.floor(Math.random() * 10) + 1;
        let amount = Math.floor(Math.random() * 100) + 1;
        console.log(`Placing order ${i} with price: ${price} and amount: ${amount}`)

        let txb = new TransactionBlock();
        txb.moveCall({
            target: `0x2d405f39a63e1d2dd6a2bf060d7db723353e5393795a48453a01085f77cf4ddf::pool::place_limit_order_bigvec`,
            arguments: [
                txb.object("0x9c131f22041034da9a855b1d9d825ae63a88f277539693592b5ffaf7c9021452"),
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
        })

        await new Promise(r => setTimeout(r, 3000));
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