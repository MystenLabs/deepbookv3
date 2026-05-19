import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const ADDRESS = "0x55fee70acf52cfaa295c3d995264bfeec53d7db0be3040e2c1e3eac017251e49";

async function findPredict() {
    console.log(`Analyzing user activity for Predict related transactions...`);
    try {
        const txs = await client.queryTransactionBlocks({
            filter: { FromAddress: ADDRESS },
            limit: 100,
            options: { showInput: true, showEffects: true }
        });
        
        const packages = new Set();
        for (const tx of txs.data) {
            const txData = tx.transaction.data.transaction;
            if (txData.kind === 'ProgrammableTransaction') {
                for (const cmd of txData.transactions) {
                    if (cmd.MoveCall) {
                        packages.add(`${cmd.MoveCall.package}::${cmd.MoveCall.module}`);
                    }
                }
            }
        }
        
        console.log("Recent packages/modules called:");
        packages.forEach(p => console.log(p));
        
    } catch (err) {
        console.error("Error:", err);
    }
}

findPredict().catch(console.error);
