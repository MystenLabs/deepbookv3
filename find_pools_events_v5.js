import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';

const client = new SuiJsonRpcClient({ url: "https://fullnode.testnet.sui.io:443" });
const PACKAGE = "0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982";

async function findPools() {
    console.log("Searching for PoolCreated events via MoveModule on Original ID...");
    try {
        const events = await client.queryEvents({
            query: { MoveModule: { package: PACKAGE, module: "pool" } }
        });
        console.log(`Found ${events.data.length} events.`);
        events.data.forEach(e => {
            if (e.type.includes("PoolCreated")) {
                console.log(`Type: ${e.type}`);
                console.log(`Pool: ${e.parsedJson.pool_id}`);
                console.log(`JSON: ${JSON.stringify(e.parsedJson)}`);
            }
        });
    } catch (err) {
        console.error("Error:", err);
    }
}

findPools().catch(console.error);
