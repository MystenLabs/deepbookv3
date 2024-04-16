import { SuiClient } from "@mysten/sui.js/client";
import { TransactionBlock } from "@mysten/sui.js/transactions";
import { Ed25519Keypair } from '@mysten/sui.js/keypairs/ed25519';
import dotenv from "dotenv";
dotenv.config();

const placeOrders = async () => {
    const client = new SuiClient({ url: "https://suins-rpc.testnet.sui.io" });
    let keypair = Ed25519Keypair.deriveKeypair(process.env.ADMIN_PHRASE!)
    
    // let txb = new TransactionBlock();
    // txb.moveCall({
    //     target: `0xdee1b7d8ff93bff51c89e0968d52532be1ecddfa8062ca6b24e60563517f7f23::pool::place_limit_order_critbit`,
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

    let txb = new TransactionBlock();
    txb.moveCall({
        target: `0xdee1b7d8ff93bff51c89e0968d52532be1ecddfa8062ca6b24e60563517f7f23::pool::place_limit_order_bigvec`,
        arguments: [
            txb.object("0xd38bb453666c851a67b53708d85780b03613cd89275956450a94551394a96d0b"),
            txb.pure(1),
            txb.pure(1),
            txb.pure(true)
        ]
    })

    client.signAndExecuteTransactionBlock({
        transactionBlock: txb,
        signer: keypair,
        options: {
            showObjectChanges: true,
            showEffects: true
        }
    }).then((res) => {
        let gas = res.effects?.gasUsed;
        console.log(gas)
    })
}

placeOrders()